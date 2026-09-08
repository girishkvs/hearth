import Foundation

public struct IdleLockService: IdleLockControlling {
    private let power: any PowerCommandRunning
    private let saver: any ScreenSaverControlling
    private let store: StateStore
    private let service: HearthService
    private let timingDisclosure = "macOS may adopt or restore the idle setting later; live engine confirmation is not available through a production API."
    private let changedContextMessage = "The stored timer remains Hearth's 0, but its preference context changed. Original configuration and ownership are retained. Restore Lock cannot safely write; preserve state.json and collect 'hearth status --json' for explicit recovery review."

    public init(
        runner: any PowerCommandRunning,
        screenSaver: any ScreenSaverControlling,
        stateDirectory: URL = StateStore.defaultDirectory
    ) {
        power = runner
        saver = screenSaver
        store = StateStore(directory: stateDirectory)
        service = HearthService(runner: runner, stateDirectory: stateDirectory)
    }

    public func status() throws -> IdleLockStatus {
        try store.withLock {
            _ = try service.statusLocked()
            return try currentStatus()
        }
    }

    public func perform(_ request: IdleLockRequest) throws -> IdleLockResult {
        try store.withLockDescriptor { descriptor in
            _ = try service.statusLocked()
            do {
                let message: String
                switch request.action {
                case .on: message = try enable(descriptor: descriptor)
                case .restore: message = try restore(descriptor: descriptor)
                }
                let status = try currentStatus()
                return IdleLockResult(
                    succeeded: request.action == .on ? status.phase == .active : !status.hasManagedChanges,
                    message: message, status: status
                )
            } catch {
                // Keep the complete transaction and expose the real failure; no rollback
                // or retry can safely be inferred from a transport exception.
                let status = try currentStatus(failure: error.localizedDescription)
                return IdleLockResult(succeeded: false, message: error.localizedDescription, status: status)
            }
        }
    }

    private func enable(descriptor: Int32) throws -> String {
        var state = try store.load()
        if let saved = state.lockOverride {
            if saved.saverWritePending { throw ScreenSaverError.completionUnknown(saved.pendingMessage) }
            if saved.legacyTimerNeedsReview { throw HearthError.state(saved.legacyRecoveryMessage) }
            let status = try currentStatus()
            guard status.phase == .active else {
                throw HearthError.state(status.message)
            }
            return "Idle-lock settings already configured; original settings retained. \(timingDisclosure)"
        }
        let readiness = try currentStatus()
        guard readiness.canEnable else { throw HearthError.invalidInput(readiness.message) }
        let settings = try power.readSettings()
        let originalConfiguration = try readyConfiguration()
        let delay = originalConfiguration.effectiveSeconds
        let profiles = try availableProfiles(settings)
        let dependencies = PowerSetting.allCases.flatMap { setting in
            profiles.map { profile in
                LockPowerOwnership(
                    setting: setting, profile: profile,
                    original: settings.values(for: setting)[profile].flatMap { $0 == 0 ? nil : $0 }
                )
            }
        }
        state.version = 4
        state.lockOverride = LockOverride(
            phase: .enabling, dependencies: dependencies, saverOriginal: delay == 0 ? nil : delay,
            backend: .preferences, saverOriginalConfiguration: originalConfiguration
        )
        try store.save(state)

        for dependency in dependencies where dependency.original != nil {
            guard let original = dependency.original else { continue }
            let result = try service.performLocked(
                PowerRequest(action: .on, target: target(dependency.profile), setting: dependency.setting),
                lockDescriptor: descriptor, lockOperation: true,
                expectedValues: [dependency.profile: original]
            )
            guard result.succeeded else {
                throw HearthError.command(result.outcomes.map(\.message).joined(separator: " "))
            }
        }
        try requireDependencies()
        if delay != 0 {
            try writeSaver(value: .integer(0), expected: originalConfiguration)
        }
        try requireDependencies()
        state = try store.load()
        let expected = state.lockOverride?.saverAppliedConfiguration ?? originalConfiguration
        guard try readyConfiguration() == expected else {
            throw HearthError.command("The screen-saver configuration changed externally. Use Restore Lock.")
        }
        state.lockOverride?.phase = .active
        try store.save(state)
        return "Idle-lock settings configured and saved. System and Display are required; manual lock and passwords are unchanged. \(timingDisclosure)"
    }

    private func restore(descriptor: Int32) throws -> String {
        var state = try store.load()
        guard var saved = state.lockOverride else { return "No Lock-owned settings to restore." }
        guard !saved.saverWritePending else {
            throw ScreenSaverError.completionUnknown(
                "\(saved.pendingMessage) Restore Lock is blocked; retain the journal for explicit recovery."
            )
        }
        guard !saved.legacyTimerNeedsReview else { throw HearthError.state(saved.legacyRecoveryMessage) }
        saved.phase = .restoring
        state.lockOverride = saved
        try store.save(state)
        var preservedExternal = saved.saverExternalChangePreserved == true
        if let original = saved.saverOriginalConfiguration,
           let applied = saved.saverAppliedConfiguration,
           saved.saverApplied,
           !saved.saverReleased {
            let observation = try saver.observe()
            let actual = try validConfiguration(observation)
            if actual.storedValue == applied.storedValue {
                guard actual == applied else {
                    throw ScreenSaverError.rejected(changedContextMessage)
                }
                guard observation.availability == .ready else {
                    throw ScreenSaverError.rejected(observation.message)
                }
                try writeSaver(value: original.storedValue, expected: actual)
            } else {
                preservedExternal = true
            }
            state = try store.load()
            state.lockOverride?.saverReleased = true
            if preservedExternal { state.lockOverride?.saverExternalChangePreserved = true }
            try store.save(state)
        }
        for (index, dependency) in saved.dependencies.enumerated() where !dependency.released {
            var staleOverride: OverrideState?
            if let original = dependency.original {
                state = try store.load()
                let record = state[dependency.setting, dependency.profile]
                let actual = try power.readSettings().values(for: dependency.setting)[dependency.profile]
                guard actual != nil else {
                    throw HearthError.command("\(dependency.setting.label), \(dependency.profile.label) is unavailable; Lock restore state retained.")
                }
                if record?.override == OverrideState(original: original, applied: 0), actual == 0 {
                    let result = try service.performLocked(
                        PowerRequest(action: .restore, target: target(dependency.profile), setting: dependency.setting),
                        lockDescriptor: descriptor, lockOperation: true,
                        expectedValues: [dependency.profile: 0]
                    )
                    guard result.succeeded else {
                        throw HearthError.command(result.outcomes.map(\.message).joined(separator: " "))
                    }
                } else {
                    if actual != original { preservedExternal = true }
                    if actual != 0, record?.override == OverrideState(original: original, applied: 0) {
                        staleOverride = record?.override
                    }
                }
            }
            state = try store.load()
            if let staleOverride, state[dependency.setting, dependency.profile]?.override == staleOverride {
                // Persist observed lost ownership with the dependency release. An
                // external return to zero must not revive this stale baseline.
                state[dependency.setting, dependency.profile] = nil
            }
            state.lockOverride?.dependencies[index].released = true
            try store.save(state)
        }
        state = try store.load()
        state.lockOverride = nil
        try store.save(state)
        return preservedExternal
            ? "Lock released. Detected external changes and pre-existing settings were preserved. \(timingDisclosure)"
            : "Lock-owned original settings saved. Pre-existing settings were retained. \(timingDisclosure)"
    }

    private func writeSaver(value: ScreenSaverStoredValue, expected: ScreenSaverConfiguration) throws {
        var state = try store.load()
        guard let saved = state.lockOverride,
              saved.backend == .preferences,
              !saved.saverWritePending,
              let original = saved.saverOriginalConfiguration else {
            throw HearthError.state("Missing or unconfirmed Lock preference transaction.")
        }
        state.lockOverride?.saverWritePending = true
        try store.save(state)
        do {
            try saver.apply(value: value, expected: expected)
        } catch ScreenSaverError.rejected(let message) {
            state = try store.load()
            state.lockOverride?.saverWritePending = false
            try store.save(state)
            throw ScreenSaverError.rejected(message)
        } catch {
            throw ScreenSaverError.completionUnknown(
                "CFPreferences timer completion is unconfirmed: \(error.localizedDescription). Pending state is retained; no automatic retry or restore."
            )
        }
        let confirmed: ScreenSaverConfiguration
        do {
            confirmed = try readyConfiguration()
            let matches = saved.phase == .enabling
                ? confirmed.storedValue == .integer(0) &&
                    confirmed.effectiveSeconds == 0 &&
                    confirmed.contextFingerprint == original.contextFingerprint
                : confirmed == original
            guard matches else {
                throw ScreenSaverError.unavailable("Fresh preferences did not match the requested configuration.")
            }
        } catch {
            throw ScreenSaverError.completionUnknown(
                "CFPreferences timer confirmation is incomplete: \(error.localizedDescription). Pending state is retained; no automatic retry or restore."
            )
        }
        state = try store.load()
        state.lockOverride?.saverWritePending = false
        if saved.phase == .enabling {
            state.lockOverride?.saverApplied = true
            state.lockOverride?.saverAppliedConfiguration = confirmed
        } else {
            state.lockOverride?.saverReleased = true
        }
        try store.save(state)
    }

    private func readyConfiguration() throws -> ScreenSaverConfiguration {
        let observation = try saver.observe()
        guard observation.availability == .ready else {
            throw ScreenSaverError.rejected(observation.message)
        }
        return try validConfiguration(observation)
    }

    private func validConfiguration(_ observation: ScreenSaverObservation) throws -> ScreenSaverConfiguration {
        guard let configuration = observation.configuration,
              observation.delaySeconds == configuration.effectiveSeconds else {
            throw ScreenSaverError.unavailable("The typed screen-saver preference configuration is unavailable or invalid.")
        }
        do {
            try configuration.validate()
        } catch {
            throw ScreenSaverError.unavailable("The typed screen-saver preference configuration is invalid: \(error.localizedDescription)")
        }
        return configuration
    }

    private func availableProfiles(_ settings: PowerSettings) throws -> [PowerProfile] {
        let system = Set(settings.values.keys)
        let display = Set(settings.displayValues.keys)
        guard !system.isEmpty, system == display else {
            throw HearthError.command("System and Display must both be readable on every available power profile.")
        }
        return PowerProfile.allCases.filter { system.contains($0) }
    }

    private func requireDependencies() throws {
        let state = try store.load()
        guard let saved = state.lockOverride else { throw HearthError.state("Missing Lock dependencies.") }
        let settings = try power.readSettings()
        let profiles = try availableProfiles(settings)
        guard Set(profiles) == Set(saved.dependencies.map(\.profile)),
              saved.dependencies.allSatisfy({ settings.values(for: $0.setting)[$0.profile] == 0 }) else {
            throw HearthError.command("Required System/Display settings changed or are unavailable. Lock configuration is incomplete; use Restore Lock.")
        }
    }

    private func currentStatus(failure: String? = nil) throws -> IdleLockStatus {
        var state = try store.load()
        let settings = try power.readSettings()
        let observation: ScreenSaverObservation
        do {
            observation = try saver.observe()
        } catch {
            observation = ScreenSaverObservation(delaySeconds: nil, availability: .unavailable, message: error.localizedDescription)
        }
        let configuration = try? validConfiguration(observation)
        if var saved = state.lockOverride,
           saved.backend == .preferences,
           !saved.saverWritePending,
           !saved.saverReleased,
           let applied = saved.saverAppliedConfiguration,
           let configuration,
           applied.storedValue != configuration.storedValue {
            // Once observed, lost ownership must not revive on a later matching zero.
            saved.saverReleased = true
            saved.saverExternalChangePreserved = true
            saved.phase = .restoring
            state.lockOverride = saved
            try store.save(state)
        }
        let saved = state.lockOverride
        let dependencies = saved?.dependencies.map {
            IdleLockDependency(
                setting: $0.setting, profile: $0.profile, acquired: $0.original != nil,
                actualMinutes: settings.values(for: $0.setting)[$0.profile]
            )
        } ?? []
        let availability = power.helperAvailability()
        let available = observation.availability == .ready && availability.isReady
        let profilesMatch = Set(settings.values.keys) == Set(settings.displayValues.keys) && !settings.values.isEmpty
        let validSaver = configuration != nil
        let allDependencies = saved.map { record in
            Set(settings.values.keys) == Set(record.dependencies.map(\.profile)) &&
                record.dependencies.allSatisfy { settings.values(for: $0.setting)[$0.profile] == 0 && !$0.released }
        } ?? false
        let matchesConfiguration = configuration != nil &&
            configuration == (saved?.saverAppliedConfiguration ?? saved?.saverOriginalConfiguration)
        let ownedTimerContextChanged = saved?.saverAppliedConfiguration != nil &&
            saved?.saverReleased == false &&
            configuration?.storedValue == .integer(0) &&
            configuration != saved?.saverAppliedConfiguration
        let active = saved?.backend == .preferences &&
            saved?.phase == .active &&
            saved?.saverWritePending == false &&
            saved?.saverReleased == false &&
            available && profilesMatch && allDependencies && matchesConfiguration && observation.delaySeconds == 0
        let phase: IdleLockPhase
        let message: String
        if saved?.saverWritePending == true {
            phase = .uncertain
            message = "\(saved?.pendingMessage ?? "") Pending state retained; do not retry or restore blindly."
        } else if saved?.legacyTimerNeedsReview == true {
            phase = .needsRestore
            message = saved?.legacyRecoveryMessage ?? ""
        } else if ownedTimerContextChanged {
            phase = .needsRestore
            message = changedContextMessage
        } else if saved != nil {
            phase = active ? .active : .needsRestore
            message = active ? "Idle-lock settings configured and saved. System and Display are required by Lock. \(timingDisclosure)"
                : "Lock configuration is incomplete. Use Restore Lock to release its saved settings. \(observation.message) \(timingDisclosure)"
        } else if available && profilesMatch && validSaver {
            phase = .off
            message = "Lock configures idle settings for this user on all available power sources. \(timingDisclosure)"
        } else {
            phase = observation.availability == .setupRequired ? .setupRequired : .unavailable
            message = !availability.isReady ? availability.message
                : (!profilesMatch ? "System and Display must be readable on each available power source."
                   : (validSaver ? observation.message : "Typed screen-saver preference configuration is unavailable. \(observation.message)"))
        }
        let canRestoreSaver = saved?.saverApplied != true ||
            saved?.saverReleased == true ||
            (validSaver && observation.availability == .ready && !ownedTimerContextChanged)
        return IdleLockStatus(
            phase: phase, message: failure ?? message, saverDelaySeconds: observation.delaySeconds,
            originalSaverDelaySeconds: saved?.saverOriginal, dependencies: dependencies,
            canEnable: saved == nil && available && profilesMatch && validSaver,
            canRestore: saved != nil && saved?.saverWritePending == false &&
                saved?.legacyTimerNeedsReview == false && availability.isReady && canRestoreSaver,
            hasManagedChanges: saved != nil,
            journalFingerprint: try saved?.fingerprint()
        )
    }

    private func target(_ profile: PowerProfile) -> PowerTarget {
        profile == .battery ? .battery : .adapter
    }
}
