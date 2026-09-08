import Foundation
import HearthCore

struct StatusUpdate: Sendable {
    let status: HearthStatus?
    let error: String?
}

struct ActionUpdate: Sendable {
    let result: OperationResult?
    let error: String?
    let refresh: StatusUpdate
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
            return StatusUpdate(status: nil, error: error.localizedDescription)
        }
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
}

struct HearthPresentation {
    func compactStatus(_ status: HearthStatus?, target: PowerTarget, unavailable: Bool) -> String {
        guard !unavailable, let status else { return "Status unavailable" }
        let profiles = status.profiles.filter { target.profiles.contains($0.profile) }
        guard profiles.allSatisfy({ $0.actualMinutes != nil }) else { return "Status unavailable" }
        if status.profiles.contains(where: { $0.phase?.hasPrefix("pending") == true }) { return "Change not yet confirmed" }
        guard status.helper.isReady else { return "Setup or repair needed" }
        guard status.warnings.isEmpty else { return "Settings need attention" }
        return profiles.map {
            let label = $0.profile == .battery ? "Battery" : "Adapter"
            return "\(label): \($0.actualMinutes == 0 ? "never" : "\($0.actualMinutes ?? 0) min")"
        }.joined(separator: " · ")
    }

    func actionSummary(_ result: OperationResult, request: PowerRequest) -> String {
        guard result.succeeded else {
            let failed = result.outcomes.filter { $0.kind == .failed || $0.kind == .preserved }
                .map { $0.profile == .battery ? "Battery" : "Adapter" }.joined(separator: " and ")
            return "\(failed.isEmpty ? "The" : failed) change was not completed. See Advanced."
        }
        switch request.action {
        case .on: return "Keep-awake settings applied."
        case .restore: return "Previous settings restored."
        case .sleep: return "Sleep timeout saved."
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
        switch request.action {
        case .on: return "Preventing idle sleep on \(target)…"
        case .restore: return "Restoring previous settings for \(target)…"
        case .sleep: return "Setting idle sleep to \(request.minutes ?? 0) minutes on \(target)…"
        }
    }

    var setupInstructions: String {
        """
        Setup / repair is a separate, explicit action. This panel only shows instructions; it does not open an installer or request administrator permission.

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

    func timeout(_ minutes: Int?) -> String {
        guard let minutes else { return "Not available" }
        if minutes == 0 {
            return "Never idle sleeps"
        }
        return "Idle sleep after \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    func ownership(_ profile: ProfileStatus?) -> String {
        guard let profile else { return "Restore information unavailable." }
        if let baseline = profile.originalMinutes {
            let applied = timeout(profile.appliedMinutes)
            return "Hearth record: \(profile.phase ?? "unknown phase"). Applied: \(applied). Restore baseline: \(timeout(baseline))."
        }
        if let phase = profile.phase {
            return "Pending record: \(phase). No restore baseline is available."
        }
        return "Not managed by Hearth. No saved restore baseline."
    }

    func outcomes(_ result: OperationResult) -> String {
        result.outcomes.map {
            "\($0.profile.label) — \($0.kind.rawValue): \($0.message)\nActual: \(timeout($0.actualMinutes))" +
                ($0.commandExitCode.map { "\nCommand exit code: \($0)" } ?? "")
        }.joined(separator: "\n\n")
    }

    func minutes(_ input: String) throws -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDigits = !trimmed.isEmpty && trimmed.utf8.allSatisfy { (48...57).contains($0) }
        guard isDigits,
              let value = Int(trimmed),
              (1...Int(Int32.max)).contains(value) else {
            throw HearthError.invalidInput("Enter whole minutes from 1 to \(Int32.max). Use Prevent idle sleep for zero.")
        }
        return value
    }
}
