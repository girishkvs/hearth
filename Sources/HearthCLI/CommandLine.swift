import Foundation
import HearthCore

enum CLICommand: Equatable {
    case help
    case version
    case setup
    case status(json: Bool)
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
        case "on", "restore", "off", "sleep":
            let parsed = try pairs(options, allowed: ["--power", "--minutes"])
            guard let target = PowerTarget(rawValue: parsed["--power"] ?? "both") else {
                throw invalid("--power must be battery, adapter, or both.")
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
            return .power(try PowerRequest(action: action, target: target, minutes: minutes))
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
        let profiles = status.profiles.map { profile in
            let saved = profile.originalMinutes.map { "restore \($0) minute(s), \(profile.phase ?? "unknown phase")" }
                ?? "not managed by Hearth"
            return "\(profile.profile.label): \(profile.actualDescription); \(saved)."
        }
        var helperLines = ["Helper: \(helperState(status.helper.state)). \(status.helper.message)"]
        if !status.helper.isReady {
            helperLines.append("Power changes are disabled. Run 'hearth setup' for explicit setup / repair instructions. Status reads remain available.")
        }
        return (["Current power source: \(status.currentSource)"] + profiles + helperLines + [
            "Display may still turn off. Settings persist after exit and reboot.",
        ]).joined(separator: "\n")
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
