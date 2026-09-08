import Foundation
import HearthCore

enum CLICommand: Equatable {
    case help
    case version
    case setup
    case status(json: Bool)
    case lockStatus
    case lock(IdleLockRequest)
    case power(PowerRequest)
    case web(port: Int, openBrowser: Bool)
}

struct CommandLineParser {
    func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else { return .status(json: false) }
        let options = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            guard options.isEmpty else { throw invalid("Help takes no arguments.") }
            return .help
        case "--version":
            guard options.isEmpty else { throw invalid("Version takes no arguments.") }
            return .version
        case "setup":
            guard options.isEmpty else { throw invalid("Usage: hearth setup (instructions only; takes no arguments)") }
            return .setup
        case "status":
            guard options.isEmpty || options == ["--json"] else {
                throw invalid("Usage: hearth status [--json]")
            }
            return .status(json: options == ["--json"])
        case "lock":
            guard options.count == 1 else {
                throw invalid("Usage: hearth lock on|restore|status (current user; no power target)")
            }
            if options[0] == "status" { return .lockStatus }
            guard let action = IdleLockAction(rawValue: options[0]) else {
                throw invalid("Usage: hearth lock on|restore|status")
            }
            return .lock(IdleLockRequest(action: action))
        case "on", "restore", "off", "sleep":
            let parsed = try pairs(options, allowed: ["--power", "--minutes", "--setting"])
            guard let target = PowerTarget(rawValue: parsed["--power"] ?? "both") else {
                throw invalid("--power must be battery, adapter, or both.")
            }
            guard let setting = PowerSetting(rawValue: parsed["--setting"] ?? "system") else {
                throw invalid("--setting must be system or display.")
            }
            let action = command == "off" ? PowerAction.restore : PowerAction(rawValue: command)!
            var minutes: Int?
            if let text = parsed["--minutes"] {
                guard text.allSatisfy(\.isASCII),
                      !text.isEmpty,
                      text.allSatisfy(\.isNumber),
                      let number = Int(text) else {
                    throw invalid("--minutes must be a positive whole number.")
                }
                minutes = number
            }
            return .power(try PowerRequest(action: action, target: target, minutes: minutes, setting: setting))
        case "web":
            let noOpenCount = options.filter { $0 == "--no-open" }.count
            guard noOpenCount <= 1 else { throw invalid("Duplicate --no-open option.") }
            let parsed = try pairs(options.filter { $0 != "--no-open" }, allowed: ["--port"])
            let text = parsed["--port"] ?? "0"
            guard !text.isEmpty,
                  text.allSatisfy(\.isASCII),
                  text.allSatisfy(\.isNumber),
                  let port = Int(text),
                  (0...65535).contains(port) else {
                throw invalid("--port must be an integer from 0 to 65535 (0 chooses an available port).")
            }
            return .web(port: port, openBrowser: noOpenCount == 0)
        default:
            throw invalid("Unknown command '\(command)'. Run 'hearth --help'.")
        }
    }

    private func pairs(_ arguments: [String], allowed: Set<String>) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw invalid("Each option needs a value.")
        }
        var result: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard allowed.contains(key), result[key] == nil else {
                throw invalid("Unknown or duplicate option '\(key)'.")
            }
            result[key] = arguments[index + 1]
        }
        return result
    }

    private func invalid(_ message: String) -> HearthError { .invalidInput(message) }
}

struct StatusPrinter {
    func text(_ status: HearthStatus) -> String {
        let profiles = PowerSetting.allCases.flatMap { setting in
            status.profiles(for: setting).map { profile in
                let saved = profile.originalMinutes.map { "restore \($0) minute(s), \(profile.phase ?? "unknown phase")" }
                    ?? "not managed by Hearth"
                let required: String
                if status.idleLock?.requires(setting, profile: profile.profile) == true {
                    required = status.idleLock?.phase == .uncertain
                        ? " Blocked while Lock completion is unconfirmed; see recovery guidance below."
                        : " Required by Lock; use 'hearth lock restore' first."
                } else {
                    required = ""
                }
                return "\(setting.label) — \(profile.profile.label): \(profile.actualDescription); \(saved).\(required)"
            }
        }
        var helperLines = ["Helper: \(helperState(status.helper.state)). \(status.helper.message)"]
        if !status.helper.isReady {
            helperLines.append("Power changes are disabled. Run 'hearth setup' for explicit setup / repair instructions. Status reads remain available.")
        }
        return (["Current power source: \(status.currentSource)"] + profiles + [lockText(status.idleLock)] + helperLines + [
            "Manual lock, passwords, lid closure, and system safety behavior are unchanged.",
            "Settings persist after exit and reboot.",
        ]).joined(separator: "\n")
    }

    func lockText(_ lock: IdleLockStatus?) -> String {
        guard let lock else {
            return "Lock: Unavailable. Open the installed Hearth app and inspect its Lock status. No Automation setup is needed."
        }
        let phase: String
        switch lock.phase {
        case .active: phase = "Configured"
        case .off: phase = "Not enabled"
        case .uncertain: phase = "Configuration unconfirmed"
        case .needsRestore: phase = "Restore needed"
        case .setupRequired: phase = "Setup / repair needed"
        case .unavailable: phase = "Unavailable"
        }
        var lines = [
            "Lock: \(phase). Current user · keeps System and Display awake.", lock.message,
            "Configured settings and readback do not prove immediate macOS timer adoption. macOS may adopt or restore the timer later.",
        ]
        if let delay = lock.saverDelaySeconds {
            lines.append("Effective screen-saver idle delay: \(delay) seconds.")
        }
        if let original = lock.originalSaverDelaySeconds {
            lines.append("Saved effective screen-saver idle delay: \(original) seconds.")
        }
        for dependency in lock.dependencies {
            let ownership = dependency.acquired ? "acquired by Lock" : "borrowed; prior setting retained"
            lines.append("\(dependency.setting.label) — \(dependency.profile.label): Required by Lock; \(ownership).")
        }
        if lock.canRestore { lines.append("Use 'hearth lock restore' to release only Lock-owned changes.") }
        if let guidance = lock.recoveryGuidance { lines.append(guidance) }
        return lines.joined(separator: "\n")
    }

    private func helperState(_ state: HelperState) -> String {
        switch state {
        case .ready: "Ready"
        case .setupRequired: "Setup required"
        case .incompatible: "Incompatible — repair required"
        case .unavailable: "Unavailable — check setup / repair"
        }
    }

    func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

struct SetupInstructions {
    var text: String {
        """
        Hearth setup / repair instructions

        This command only prints guidance. It does not install, open an installer,
        register a service, or request administrator authorization.

        1. From the Hearth source directory, build: scripts/package-installer.sh
        2. Review the versioned local setup package under dist/.
        3. Use scripts/install.sh --gui or --cli explicitly to authorize installation.
        4. Run hearth status (or Refresh in the app or web page) and check Helper: Ready.

        Lock uses public current-user preferences; no Automation setup is needed.
        CLI and web use the verified Hearth app as one serialized current-user
        writer. Helper installation is separate and supports System/Display power
        changes. Manual lock and passwords are unchanged.

        Normal on, restore, and sleep actions use the installed helper without
        administrator prompts. They never start setup or fall back to elevation.
        If the installed configuration is revoked, missing, or incompatible,
        repeat this explicit setup / repair workflow.

        Helper readiness is checked at runtime. Hearth does not guarantee that
        macOS updates or reinstalls can bypass renewed consent.

        Removal is also explicit. Restore managed settings first if desired,
        while the helper is ready. Then use scripts/uninstall.sh --restored --gui
        (or --cli). Choose --keep-settings instead if you do not want restoration.
        """
    }
}
