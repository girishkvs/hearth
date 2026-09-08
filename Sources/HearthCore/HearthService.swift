import Foundation

public struct HearthService: Sendable {
    private let runner: any PowerCommandRunning
    private let store: StateStore

    public init(
        runner: any PowerCommandRunning = SystemPowerRunner(),
        stateDirectory: URL = StateStore.defaultDirectory
    ) {
        self.runner = runner
        self.store = StateStore(directory: stateDirectory)
    }

    public func status() throws -> HearthStatus {
        return try store.withLock {
            let settings = try runner.readSettings()
            var state: SavedState
            do {
                state = try store.load()
            } catch {
                return makeStatus(settings, state: SavedState(), warnings: [error.localizedDescription])
            }
            let before = state
            let recovery = reconcile(&state, settings: settings)
            if state != before { try store.save(state) }
            return makeStatus(settings, state: state, warnings: recovery.warnings)
        }
    }

    public func perform(_ request: PowerRequest) throws -> OperationResult {
        let request = try request.validated()
        let availability = runner.helperAvailability()
        guard availability.isReady else {
            throw HearthError.helperUnavailable(availability.message)
        }
        return try store.withLockDescriptor { lockDescriptor in
            var state = try store.load()
            let initial = try runner.readSettings()
            let before = state
            let recovery = reconcile(&state, settings: initial)
            if state != before { try store.save(state) }
            var outcomes: [ProfileOutcome] = []
            var changes: [PowerChange] = []

            for profile in request.target.profiles {
                guard let actual = initial.values[profile] else {
                    outcomes.append(outcome(profile, .failed, "Power profile is not available on this Mac.", actual: nil))
                    continue
                }
                if recovery.externalChanges.contains(profile),
                   request.action != .sleep {
                    outcomes.append(outcome(profile, .preserved, "Preserved an external change; stale restore state was removed. Review status before retrying.", actual: actual))
                    continue
                }
                var record = state.profiles[profile.rawValue] ?? ProfileState()
                let desired: Int
                switch request.action {
                case .on:
                    guard actual != 0 else {
                        let message = record.override == nil
                            ? "Already never idle sleeps; no baseline invented."
                            : "Hearth override is already active; original timeout retained."
                        outcomes.append(outcome(profile, .unchanged, message, actual: actual))
                        continue
                    }
                    desired = 0
                case .restore:
                    guard let saved = record.override else {
                        outcomes.append(outcome(profile, .unchanged, "No Hearth override to restore; current setting left unchanged.", actual: actual))
                        continue
                    }
                    desired = saved.original
                case .sleep:
                    // validated() guarantees a positive timeout.
                    guard let minutes = request.minutes else {
                        throw HearthError.invalidInput("Sleep minutes are required.")
                    }
                    desired = minutes
                    if desired == actual {
                        state.profiles.removeValue(forKey: profile.rawValue)
                        outcomes.append(outcome(profile, .unchanged, "Timeout already matches the requested permanent setting.", actual: actual))
                        continue
                    }
                }
                record.pending = PendingOperation(action: request.action, original: actual, applied: desired)
                state.profiles[profile.rawValue] = record
                changes.append(try PowerChange(profile: profile, minutes: desired, expectedMinutes: actual))
            }

            // The complete journal is durable before handing its lock lease to the helper.
            if !changes.isEmpty || state != before { try store.save(state) }
            guard !changes.isEmpty else {
                return result(outcomes, settings: initial, state: state, warnings: recovery.warnings)
            }

            let commands: [CommandOutcome]
            do {
                commands = try runner.apply(changes, holdingLock: lockDescriptor)
            } catch HearthError.indeterminateHelper(let message) {
                // A timed-out RPC may still execute. The remote lease blocks other
                // clients; this caller must not discard its own pending journal.
                throw HearthError.indeterminateHelper(message)
            } catch {
                commands = changes.map { CommandOutcome(profile: $0.profile, exitCode: nil, message: error.localizedDescription) }
            }

            let actual: PowerSettings
            do {
                actual = try runner.readSettings()
            } catch {
                throw HearthError.command("Could not read settings after the helper request: \(error.localizedDescription). Pending restore information is retained. Run 'hearth status' to recover; do not assume the operation failed to change settings.")
            }
            for change in changes {
                let matching = commands.filter { $0.profile == change.profile }
                if matching.count == 1,
                   !matching[0].didExecute,
                   var record = state.profiles[change.profile.rawValue] {
                    // The helper definitively skipped this write. A matching
                    // external value must not become a new Hearth baseline.
                    record.pending = nil
                    state.profiles[change.profile.rawValue] = record.isEmpty ? nil : record
                }
            }
            let afterRecovery = reconcile(&state, settings: actual)
            try store.save(state)
            for change in changes {
                let matching = commands.filter { $0.profile == change.profile }
                let command = matching.count == 1 ? matching[0] : nil
                let observed = actual.values[change.profile]
                let reached = observed == change.minutes
                let confirmed = command?.exitCode == 0 && command?.didExecute == true
                let message: String
                if command?.didExecute == false {
                    message = "No write was executed; current setting preserved. \(command?.message ?? "")"
                } else if reached && confirmed {
                    message = request.action == .restore
                        ? "Previous timeout restored."
                        : (request.action == .on ? "Idle sleep prevented; original timeout saved." : "Explicit timeout saved as your new setting.")
                } else if reached {
                    message = "Requested value was read back, but command success was not confirmed. \(command?.message ?? "Missing command result.")"
                } else {
                    message = "Requested \(change.minutes) minute(s), read back \(observed.map(String.init) ?? "unavailable"). \(command?.message ?? "Missing command result.")"
                }
                outcomes.append(outcome(
                    change.profile,
                    command?.didExecute == false ? .preserved : (reached && confirmed ? .changed : .failed),
                    message,
                    actual: observed,
                    commandExitCode: command?.exitCode
                ))
            }
            return result(outcomes, settings: actual, state: state, warnings: recovery.warnings + afterRecovery.warnings)
        }
    }

    private func reconcile(
        _ state: inout SavedState,
        settings: PowerSettings
    ) -> (warnings: [String], externalChanges: Set<PowerProfile>) {
        var warnings: [String] = []
        var externalChanges: Set<PowerProfile> = []
        for profile in PowerProfile.allCases {
            guard var record = state.profiles[profile.rawValue] else { continue }
            guard let actual = settings.values[profile] else {
                warnings.append("\(profile.label): profile unavailable; saved state retained.")
                continue
            }
            if let pending = record.pending {
                if actual == pending.applied {
                    switch pending.action {
                    case .on: record.override = OverrideState(original: pending.original, applied: pending.applied)
                    case .restore, .sleep: record.override = nil
                    }
                } else if actual == pending.original {
                    warnings.append("\(profile.label): pending \(pending.action.rawValue) did not change the setting; previous restore information retained.")
                } else {
                    warnings.append("\(profile.label): external change detected during a pending operation; current value preserved and stale restore state removed.")
                    record.override = nil
                    externalChanges.insert(profile)
                }
                record.pending = nil
            }
            if let saved = record.override, actual != saved.applied {
                warnings.append("\(profile.label): external timeout \(actual) differs from Hearth's \(saved.applied); current value preserved and stale restore state removed.")
                record.override = nil
                externalChanges.insert(profile)
            }
            state.profiles[profile.rawValue] = record.isEmpty ? nil : record
        }
        return (warnings, externalChanges)
    }

    private func makeStatus(_ settings: PowerSettings, state: SavedState, warnings: [String]) -> HearthStatus {
        HearthStatus(
            schemaVersion: 1,
            currentSource: settings.currentSource,
            profiles: PowerProfile.allCases.map { profile in
                let record = state.profiles[profile.rawValue]
                let pending = record?.pending
                let saved = record?.override
                return ProfileStatus(
                    profile: profile,
                    actualMinutes: settings.values[profile],
                    originalMinutes: saved?.original ?? (pending?.action == .on ? pending?.original : nil),
                    appliedMinutes: saved?.applied ?? (pending?.action == .on ? pending?.applied : nil),
                    phase: pending.map { "pending-\($0.action.rawValue)" } ?? (saved == nil ? nil : "active")
                )
            },
            warnings: warnings,
            helper: runner.helperAvailability()
        )
    }

    private func outcome(
        _ profile: PowerProfile,
        _ kind: OutcomeKind,
        _ message: String,
        actual: Int?,
        commandExitCode: Int32? = nil
    ) -> ProfileOutcome {
        ProfileOutcome(profile: profile, kind: kind, message: message, actualMinutes: actual, commandExitCode: commandExitCode)
    }

    private func result(
        _ outcomes: [ProfileOutcome],
        settings: PowerSettings,
        state: SavedState,
        warnings: [String]
    ) -> OperationResult {
        OperationResult(
            succeeded: outcomes.allSatisfy { $0.kind != .failed && $0.kind != .preserved },
            outcomes: outcomes.sorted { $0.profile.rawValue < $1.profile.rawValue },
            status: makeStatus(settings, state: state, warnings: warnings)
        )
    }
}
