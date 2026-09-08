import Foundation

public struct HearthService: Sendable {
    private let runner: any PowerCommandRunning
    private let store: StateStore
    private let idleLockController: (any IdleLockControlling)?

    public init(
        runner: any PowerCommandRunning = SystemPowerRunner(),
        stateDirectory: URL = StateStore.defaultDirectory,
        idleLockController: (any IdleLockControlling)? = nil
    ) {
        self.runner = runner
        self.store = StateStore(directory: stateDirectory)
        self.idleLockController = idleLockController
    }

    public func status() throws -> HearthStatus {
        let idleLock: IdleLockStatus?
        if let idleLockController {
            do {
                idleLock = try idleLockController.status()
            } catch {
                idleLock = IdleLockStatus(phase: .unavailable, message: error.localizedDescription)
            }
        } else {
            idleLock = nil
        }
        return try store.withLock {
            try statusLocked(idleLock: idleLock)
        }
    }

    func statusLocked(idleLock: IdleLockStatus? = nil) throws -> HearthStatus {
        let settings = try runner.readSettings()
        var state: SavedState
        do {
            state = try store.load()
        } catch {
            return makeStatus(settings, state: SavedState(), warnings: [error.localizedDescription], idleLock: idleLock)
        }
        let before = state
        state.version = 4
        let recovery = reconcile(&state, settings: settings)
        if state != before { try store.save(state) }
        return makeStatus(settings, state: state, warnings: recovery.warnings, idleLock: idleLock)
    }

    public func perform(_ request: PowerRequest) throws -> OperationResult {
        let request = try request.validated()
        let availability = runner.helperAvailability()
        guard availability.isReady else {
            throw HearthError.helperUnavailable(availability.message)
        }
        return try store.withLockDescriptor { lockDescriptor in
            try performLocked(request, lockDescriptor: lockDescriptor)
        }
    }

    public func performIdleLock(_ request: IdleLockRequest) throws -> IdleLockResult {
        guard let idleLockController else {
            throw HearthError.helperUnavailable("Open Hearth and enable Lock controls in native setup first.")
        }
        return try idleLockController.perform(request)
    }

    func performLocked(
        _ request: PowerRequest, lockDescriptor: Int32, lockOperation: Bool = false,
        expectedValues: [PowerProfile: Int]? = nil
    ) throws -> OperationResult {
        var state = try store.load()
        if !lockOperation,
           let saved = state.lockOverride,
           saved.dependencies.contains(where: { $0.setting == request.setting && request.target.profiles.contains($0.profile) }) {
            if saved.saverWritePending {
                throw HearthError.invalidInput("\(saved.pendingMessage) Lock, Restore Lock and required System/Display changes are blocked. Preserve state.json, then collect 'hearth status --json' and the last error for recovery review; status does not retry the write.")
            }
            if saved.legacyTimerNeedsReview { throw HearthError.invalidInput(saved.legacyRecoveryMessage) }
            throw HearthError.invalidInput("Required by Lock. Use Restore Lock to release its settings before changing \(request.setting.label).")
        }
        let initial = try runner.readSettings()
        if let expectedValues {
            guard Set(expectedValues.keys) == Set(request.target.profiles),
                  expectedValues.allSatisfy({ initial.values(for: request.setting)[$0.key] == $0.value }) else {
                throw HearthError.command("External \(request.setting.label) change preserved; it no longer matches the Lock transaction.")
            }
        }
        let before = state
        state.version = 4
        let recovery = reconcile(&state, settings: initial)
        if state != before { try store.save(state) }
        var outcomes: [ProfileOutcome] = []
        var changes: [PowerChange] = []

        for profile in request.target.profiles {
            guard let actual = initial.values(for: request.setting)[profile] else {
                outcomes.append(outcome(request.setting, profile, .failed, "Requested setting is not available for this power profile.", actual: nil))
                continue
            }
            if recovery.externalChanges.contains(SettingProfile(setting: request.setting, profile: profile)),
               request.action != .sleep {
                outcomes.append(outcome(request.setting, profile, .preserved, "Preserved an external change; stale restore state was removed. Review status before retrying.", actual: actual))
                continue
            }
            var record = state[request.setting, profile] ?? ProfileState()
            let desired: Int
            switch request.action {
            case .on:
                guard actual != 0 else {
                    let message = record.override == nil
                        ? "Idle timeout already disabled; no baseline invented."
                        : "Hearth override is already active; original timeout retained."
                    outcomes.append(outcome(request.setting, profile, .unchanged, message, actual: actual))
                    continue
                }
                desired = 0
            case .restore:
                guard let saved = record.override else {
                    outcomes.append(outcome(request.setting, profile, .unchanged, "No Hearth override to restore; current setting left unchanged.", actual: actual))
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
                    state[request.setting, profile] = nil
                    outcomes.append(outcome(request.setting, profile, .unchanged, "Timeout already matches the requested permanent setting.", actual: actual))
                    continue
                }
            }
            record.pending = PendingOperation(action: request.action, original: actual, applied: desired)
            state[request.setting, profile] = record
            changes.append(try PowerChange(profile: profile, minutes: desired, expectedMinutes: actual, setting: request.setting))
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
            commands = changes.map {
                CommandOutcome(profile: $0.profile, exitCode: nil, message: error.localizedDescription, setting: $0.setting)
            }
        }

        let actual: PowerSettings
        do {
            actual = try runner.readSettings()
        } catch {
            throw HearthError.command("Could not read settings after the helper request: \(error.localizedDescription). Pending restore information is retained. Run 'hearth status' to recover; do not assume the operation failed to change settings.")
        }
        for change in changes {
            let matching = commands.filter { $0.profile == change.profile && $0.setting == change.setting }
            if matching.count == 1,
               !matching[0].didExecute,
               var record = state[change.setting, change.profile] {
                // The helper definitively skipped this write. A matching
                // external value must not become a new Hearth baseline.
                record.pending = nil
                state[change.setting, change.profile] = record.isEmpty ? nil : record
            }
        }
        let afterRecovery = reconcile(&state, settings: actual)
        try store.save(state)
        for change in changes {
            let matching = commands.filter { $0.profile == change.profile && $0.setting == change.setting }
            let command = matching.count == 1 ? matching[0] : nil
            let observed = actual.values(for: change.setting)[change.profile]
            let reached = observed == change.minutes
            let confirmed = command?.exitCode == 0 && command?.didExecute == true
            let message: String
            if command?.didExecute == false {
                message = "No write was executed; current setting preserved. \(command?.message ?? "")"
            } else if reached && confirmed {
                message = request.action == .restore
                    ? "Previous timeout restored."
                    : (request.action == .on ? "\(change.setting.label) idle timeout disabled; original timeout saved." : "Explicit timeout saved as your new setting.")
            } else if reached {
                message = "Requested value was read back, but command success was not confirmed. \(command?.message ?? "Missing command result.")"
            } else {
                message = "Requested \(change.minutes) minute(s), read back \(observed.map(String.init) ?? "unavailable"). \(command?.message ?? "Missing command result.")"
            }
            outcomes.append(outcome(
                change.setting,
                change.profile,
                command?.didExecute == false ? .preserved : (reached && confirmed ? .changed : .failed),
                message,
                actual: observed,
                commandExitCode: command?.exitCode
            ))
        }
        return result(outcomes, settings: actual, state: state, warnings: recovery.warnings + afterRecovery.warnings)
    }

    private struct SettingProfile: Hashable {
        let setting: PowerSetting
        let profile: PowerProfile
    }

    private func reconcile(
        _ state: inout SavedState,
        settings: PowerSettings
    ) -> (warnings: [String], externalChanges: Set<SettingProfile>) {
        var warnings: [String] = []
        var externalChanges: Set<SettingProfile> = []
        for setting in PowerSetting.allCases {
            for profile in PowerProfile.allCases {
                guard var record = state[setting, profile] else { continue }
                if let saved = state.lockOverride,
                   saved.saverWritePending,
                   saved.dependencies.contains(where: { $0.setting == setting && $0.profile == profile }) {
                    // Preserve originals throughout timer uncertainty, even when
                    // a later power reading differs. Recovery needs the whole plan.
                    continue
                }
                let key = SettingProfile(setting: setting, profile: profile)
                let label = "\(setting.label), \(profile.label)"
                guard let actual = settings.values(for: setting)[profile] else {
                    warnings.append("\(label): setting unavailable; saved state retained.")
                    continue
                }
                if let pending = record.pending {
                    if actual == pending.applied {
                        switch pending.action {
                        case .on: record.override = OverrideState(original: pending.original, applied: pending.applied)
                        case .restore, .sleep: record.override = nil
                        }
                    } else if actual == pending.original {
                        warnings.append("\(label): pending \(pending.action.rawValue) did not change the setting; previous restore information retained.")
                    } else {
                        warnings.append("\(label): external change detected during a pending operation; current value preserved and stale restore state removed.")
                        record.override = nil
                        externalChanges.insert(key)
                    }
                    record.pending = nil
                }
                if let saved = record.override, actual != saved.applied {
                    warnings.append("\(label): external timeout \(actual) differs from Hearth's \(saved.applied); current value preserved and stale restore state removed.")
                    record.override = nil
                    externalChanges.insert(key)
                }
                state[setting, profile] = record.isEmpty ? nil : record
            }
        }
        return (warnings, externalChanges)
    }

    private func makeStatus(_ settings: PowerSettings, state: SavedState, warnings: [String], idleLock: IdleLockStatus? = nil) -> HearthStatus {
        let helper = runner.helperAvailability()
        return HearthStatus(
            schemaVersion: 4,
            currentSource: settings.currentSource,
            profiles: profiles(.system, settings: settings, state: state),
            warnings: warnings,
            helper: helper,
            displayProfiles: profiles(.display, settings: settings, state: state),
            idleLock: lockSummary(state: state, settings: settings, helper: helper, stateReliable: warnings.isEmpty, observed: idleLock)
        )
    }

    private func lockSummary(state: SavedState, settings: PowerSettings, helper: HelperAvailability, stateReliable: Bool, observed: IdleLockStatus?) -> IdleLockStatus? {
        guard let saved = state.lockOverride else {
            let unbackedProtection = observed?.hasManagedChanges == true || observed?.phase == .active
            let unverifiedReadiness = (!helper.isReady || !stateReliable) &&
                (observed?.canEnable == true || observed?.canRestore == true)
            if unbackedProtection || unverifiedReadiness {
                return IdleLockStatus(
                    phase: .unavailable,
                    message: "Lock state changed during refresh. Configuration is unconfirmed; refresh before making a Lock change.",
                    saverDelaySeconds: observed?.saverDelaySeconds
                )
            }
            return observed
        }
        let dependencies = saved.dependencies.map {
            IdleLockDependency(setting: $0.setting, profile: $0.profile, acquired: $0.original != nil,
                               actualMinutes: settings.values(for: $0.setting)[$0.profile])
        }
        let agrees = observed.map {
            $0.hasManagedChanges &&
                $0.dependencies == dependencies &&
                $0.originalSaverDelaySeconds == saved.saverOriginal &&
                $0.journalFingerprint != nil &&
                $0.journalFingerprint == (try? saved.fingerprint())
        } ?? false
        let availableProfiles = Set(saved.dependencies.map(\.profile))
        let activeIsCurrent = saved.backend == .preferences &&
            saved.phase == .active &&
            !saved.saverReleased &&
            observed?.saverDelaySeconds == 0 &&
            saved.dependencies.allSatisfy({ !$0.released }) &&
            dependencies.allSatisfy({ $0.actualMinutes == 0 }) &&
            Set(settings.values.keys) == availableProfiles &&
            Set(settings.displayValues.keys) == availableProfiles
        if !saved.saverWritePending,
           !saved.legacyTimerNeedsReview,
           stateReliable,
           helper.isReady,
           let observed,
           agrees,
           observed.phase != .active || activeIsCurrent {
            return observed
        }
        return IdleLockStatus(
            phase: saved.saverWritePending ? .uncertain : .needsRestore,
            message: saved.saverWritePending
                ? "\(saved.pendingMessage) Lock and required settings are blocked; original values are retained."
                : (saved.legacyTimerNeedsReview ? saved.legacyRecoveryMessage
                   : (observed?.hasManagedChanges == true
                      ? "Lock observations changed during refresh. Configuration is unconfirmed; refresh before making a Lock change."
                      : (observed?.message ?? "Lock has saved settings. Open Hearth for current Lock status or Restore Lock."))),
            saverDelaySeconds: observed?.saverDelaySeconds,
            originalSaverDelaySeconds: saved.saverOriginal,
            dependencies: dependencies,
            hasManagedChanges: true,
            journalFingerprint: try? saved.fingerprint()
        )
    }
    private func profiles(_ setting: PowerSetting, settings: PowerSettings, state: SavedState) -> [ProfileStatus] {
        PowerProfile.allCases.map { profile in
            let record = state[setting, profile]
            let pending = record?.pending
            let saved = record?.override
            return ProfileStatus(
                profile: profile,
                actualMinutes: settings.values(for: setting)[profile],
                originalMinutes: saved?.original ?? (pending?.action == .on ? pending?.original : nil),
                appliedMinutes: saved?.applied ?? (pending?.action == .on ? pending?.applied : nil),
                phase: pending.map { "pending-\($0.action.rawValue)" } ?? (saved == nil ? nil : "active"),
                setting: setting
            )
        }
    }

    private func outcome(
        _ setting: PowerSetting,
        _ profile: PowerProfile,
        _ kind: OutcomeKind,
        _ message: String,
        actual: Int?,
        commandExitCode: Int32? = nil
    ) -> ProfileOutcome {
        ProfileOutcome(profile: profile, kind: kind, message: message, actualMinutes: actual, commandExitCode: commandExitCode, setting: setting)
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
