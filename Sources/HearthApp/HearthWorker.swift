import Foundation
import HearthCore

struct StatusUpdate: Sendable {
    let status: HearthStatus?
    let error: String?
    var busy = false
}

struct LockActionUpdate: Sendable {
    let result: IdleLockResult?
    let error: String?
    let refresh: StatusUpdate

    var succeeded: Bool {
        guard let result,
              result.succeeded,
              error == nil,
              refresh.error == nil,
              refresh.status?.warnings.isEmpty == true,
              let current = refresh.status?.idleLock else { return false }
        return result.status.hasManagedChanges ? current.phase == .active : !current.hasManagedChanges
    }
}

struct LockRegistrationUpdate: Sendable {
    let error: String?
    let refresh: StatusUpdate
}

struct ActionUpdate: Sendable {
    let result: OperationResult?
    let error: String?
    let refresh: StatusUpdate

    var succeeded: Bool {
        result?.succeeded == true &&
            error == nil &&
            refresh.error == nil
    }
}

struct SettingActionUpdate: Sendable {
    let request: PowerRequest
    let update: ActionUpdate
}

struct RestoreUpdate: Sendable {
    let actions: [SettingActionUpdate]
    let refresh: StatusUpdate
    var lock: LockActionUpdate? = nil

    var succeeded: Bool {
        (!actions.isEmpty || lock != nil) &&
            (lock == nil || lock?.succeeded == true) &&
            actions.allSatisfy { $0.update.succeeded } &&
            refresh.error == nil &&
            refresh.status?.hasManagedChanges == false &&
            refresh.status?.warnings.isEmpty == true
    }
}

// Blocking core calls stay on this actor, never on AppKit's main actor.
actor HearthWorker {
    private let service: HearthService

    init(service: HearthService) {
        self.service = service
    }

    func read() -> StatusUpdate {
        do {
            return StatusUpdate(status: try service.status(), error: nil)
        } catch {
            let busy: Bool
            if case HearthError.busy = error { busy = true } else { busy = false }
            return StatusUpdate(status: nil, error: error.localizedDescription, busy: busy)
        }
    }

    func refreshLockRegistration(_ register: @Sendable () throws -> Void) -> LockRegistrationUpdate {
        let failure: String?
        do {
            try register()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        return LockRegistrationUpdate(error: failure, refresh: read())
    }

    func performLock(_ request: IdleLockRequest) -> LockActionUpdate {
        let result: IdleLockResult?
        let failure: String?
        do {
            result = try service.performIdleLock(request)
            failure = nil
        } catch {
            result = nil
            failure = error.localizedDescription
        }
        return LockActionUpdate(result: result, error: failure, refresh: read())
    }

    func perform(_ request: PowerRequest) -> ActionUpdate {
        let result: OperationResult?
        let failure: String?
        do {
            result = try service.perform(request)
            failure = nil
        } catch {
            result = nil
            failure = error.localizedDescription
        }
        return ActionUpdate(result: result, error: failure, refresh: read())
    }

    func restoreManagedSettings(_ status: HearthStatus) -> RestoreUpdate {
        var actions: [SettingActionUpdate] = []
        var current = status
        var lockUpdate: LockActionUpdate?
        if status.idleLock?.hasManagedChanges == true {
            let update = performLock(IdleLockRequest(action: .restore))
            lockUpdate = update
            guard update.succeeded,
                  let refreshed = update.refresh.status,
                  refreshed.idleLock?.hasManagedChanges == false else {
                return RestoreUpdate(actions: [], refresh: update.refresh, lock: update)
            }
            current = refreshed
        }
        for setting in PowerSetting.allCases {
            let profiles = current.profiles(for: setting).filter { $0.isManaged || $0.phase != nil }
            guard let target = restoreTarget(for: profiles) else { continue }
            // These are separate core operations, not an atomic cross-setting write.
            // Keep every result, including a failure before a later setting succeeds.
            do {
                let request = try PowerRequest(action: .restore, target: target, setting: setting)
                actions.append(SettingActionUpdate(request: request, update: perform(request)))
            } catch {
                return RestoreUpdate(actions: actions, refresh: StatusUpdate(status: nil, error: error.localizedDescription), lock: lockUpdate)
            }
        }
        return RestoreUpdate(actions: actions, refresh: read(), lock: lockUpdate)
    }

    private func restoreTarget(for profiles: [ProfileStatus]) -> PowerTarget? {
        let battery = profiles.contains { $0.profile == .battery }
        let adapter = profiles.contains { $0.profile == .adapter }
        switch (battery, adapter) {
        case (true, true): return .both
        case (true, false): return .battery
        case (false, true): return .adapter
        case (false, false): return nil
        }
    }
}

struct HearthPresentation {
    var lockTimingDisclosure: String {
        "Configured settings and readback do not prove immediate macOS timer adoption. macOS may adopt or restore the timer later."
    }

    func lockSummary(_ status: IdleLockStatus?, unavailable: Bool) -> String {
        guard !unavailable, let status else { return "Lock · Status unavailable" }
        switch status.phase {
        case .off: return "Lock · Not enabled"
        case .active: return "Lock · Configured"
        case .needsRestore: return "Lock · Restore needed"
        case .setupRequired: return "Lock · Setup / repair needed"
        case .unavailable: return "Lock · Unavailable"
        case .uncertain: return "Lock · Configuration unconfirmed"
        }
    }

    func compactStatus(_ status: HearthStatus?, setting: PowerSetting, target: PowerTarget, unavailable: Bool) -> String {
        guard !unavailable, let status else { return "\(setting.label) · Status unavailable" }
        let profiles = status.profiles(for: setting)
        let values = target.profiles.map { profile in
            let label = profile == .battery ? "Battery" : "Adapter"
            let value = profiles.first { $0.profile == profile }
            let timeout = value?.actualMinutes.map { $0 == 0 ? "never" : "\($0) min" } ?? "unavailable"
            let pending = value?.phase?.hasPrefix("pending") == true ? " (unconfirmed)" : ""
            return "\(label): \(timeout)\(pending)"
        }.joined(separator: " · ")
        return "\(setting.label) · \(values)"
    }

    func actionSummary(_ result: OperationResult, request: PowerRequest) -> String {
        guard result.succeeded else {
            let failed = result.outcomes.filter { $0.kind == .failed || $0.kind == .preserved }
                .map { $0.profile == .battery ? "Battery" : "Adapter" }.joined(separator: " and ")
            return "\(request.setting.label): \(failed.isEmpty ? "change" : failed) not completed. See Advanced."
        }
        switch request.action {
        case .on: return "\(request.setting.label) keep-awake settings applied."
        case .restore: return "\(request.setting.label) settings restored."
        case .sleep: return "\(request.setting.label) timeout saved."
        }
    }

    func helperSummary(_ helper: HelperAvailability?) -> String {
        guard let helper else { return "Helper: Not yet checked" }
        switch helper.state {
        case .ready: return "Helper: Ready"
        case .setupRequired: return "Helper: Setup required — power changes disabled"
        case .incompatible: return "Helper: Incompatible — repair required"
        case .unavailable: return "Helper: Unavailable — check setup / repair"
        }
    }

    func targetName(_ target: PowerTarget) -> String {
        switch target {
        case .both: "battery and power adapter"
        case .battery: "battery"
        case .adapter: "power adapter"
        }
    }

    func progress(_ request: PowerRequest) -> String {
        let target = targetName(request.target)
        let setting = request.setting.rawValue
        switch request.action {
        case .on: return "Keeping \(setting) awake on \(target)…"
        case .restore: return "Restoring \(setting) settings for \(target)…"
        case .sleep: return "Setting \(setting) timeout to \(request.minutes ?? 0) minutes on \(target)…"
        }
    }

    var setupInstructions: String {
        """
        Setup / repair is a separate, explicit action. Opening this panel does not open an installer or request permission.

        Lock uses public current-user preferences. No Automation setup or permission is needed. CLI and web use the verified Hearth app as one serialized current-user writer. Helper installation below is separate and is needed for System/Display power changes.

        1. From the Hearth source directory, build:
        scripts/package-installer.sh

        2. Review the generated package:
        The versioned local setup package under dist/.

        3. Use scripts/install.sh --gui or --cli explicitly to authorize installation.

        4. Return to Hearth and click Refresh. Power controls become available when the helper is Ready.

        Normal power actions never open an installer or ask for administrator permission. If the installed configuration is revoked, missing, or incompatible, repeat this explicit setup / repair workflow.

        Helper readiness is checked at runtime. Hearth does not guarantee that macOS updates or reinstalls can bypass renewed consent.

        Removal is also explicit. Restore managed settings first if desired, while the helper is ready. Then use scripts/uninstall.sh --restored --gui (or --cli). Choose --keep-settings instead to retain settings.
        """
    }

    func timeout(_ minutes: Int?, setting: PowerSetting = .system) -> String {
        guard let minutes else { return "Not available" }
        if setting == .display {
            return minutes == 0 ? "No idle display timeout" : "Display off after \(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        if minutes == 0 {
            return "Never idle sleeps"
        }
        return "Idle sleep after \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    func ownership(_ profile: ProfileStatus?) -> String {
        guard let profile else { return "Restore information unavailable." }
        if profile.phase?.hasPrefix("pending") == true {
            return "Change unconfirmed. Saved settings retained until status is known."
        }
        if let baseline = profile.originalMinutes {
            return "Saved by Hearth. Restore: \(timeout(baseline, setting: profile.setting))."
        }
        return "No saved setting to restore."
    }

    func outcomes(_ result: OperationResult) -> String {
        result.outcomes.map {
            "\($0.setting.label) · \($0.profile.label) — \($0.kind.rawValue): \($0.message)\nActual: \(timeout($0.actualMinutes, setting: $0.setting))" +
                ($0.commandExitCode.map { "\nCommand exit code: \($0)" } ?? "")
        }.joined(separator: "\n\n")
    }

    func minutes(_ input: String) throws -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDigits = !trimmed.isEmpty && trimmed.utf8.allSatisfy { (48...57).contains($0) }
        guard isDigits,
              let value = Int(trimmed),
              (1...Int(Int32.max)).contains(value) else {
            throw HearthError.invalidInput("Enter whole minutes from 1 to \(Int32.max). Use Keep awake for zero.")
        }
        return value
    }
}
