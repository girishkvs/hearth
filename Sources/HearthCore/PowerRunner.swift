import Foundation
import HearthIPC

public struct PMSetParser: Sendable {
    public init() {}

    public func parse(custom: String, battery: String) throws -> PowerSettings {
        var profile: PowerProfile?
        var seen: Set<PowerProfile> = []
        var values: [PowerProfile: Int] = [:]
        var displayValues: [PowerProfile: Int] = [:]
        for line in custom.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(":") {
                switch text {
                case "Battery Power:": profile = .battery
                case "AC Power:": profile = .adapter
                default: profile = nil
                }
                if let profile, !seen.insert(profile).inserted {
                    throw HearthError.command("pmset returned a duplicate \(profile.label) section.")
                }
                continue
            }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard let profile,
                  let key = fields.first,
                  let setting = PowerSetting.allCases.first(where: { $0.pmsetKey == key }) else { continue }
            let previous = setting == .system ? values[profile] : displayValues[profile]
            guard fields.count >= 2,
                  let value = Int(fields[1]),
                  (0...Int(Int32.max)).contains(value),
                  previous == nil else {
                throw HearthError.command("pmset returned an invalid or duplicate \(setting.pmsetKey) value for \(profile.label).")
            }
            switch setting {
            case .system: values[profile] = value
            case .display: displayValues[profile] = value
            }
        }
        guard !values.isEmpty, seen.allSatisfy({ values[$0] != nil }) else {
            throw HearthError.command("Cannot read exact battery/adapter sleep values from pmset -g custom.")
        }
        let firstLine = battery.split(separator: "\n").first.map(String.init) ?? ""
        let source: String
        if firstLine.contains("'Battery Power'") {
            source = "Battery"
        } else if firstLine.contains("'AC Power'") {
            source = "Power adapter"
        } else if firstLine.contains("'UPS Power'") {
            source = "UPS"
        } else {
            source = "Unknown"
        }
        return PowerSettings(values: values, currentSource: source, displayValues: displayValues)
    }
}

struct ProcessResult {
    let exitCode: Int32
    let output: String
}

struct ProcessExecutor: Sendable {
    func run(
        _ executable: String,
        _ arguments: [String],
        standardInput: FileHandle = .standardInput
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = standardInput
        do {
            try process.run()
        } catch {
            throw HearthError.command("Could not launch \(executable): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public struct SystemPowerRunner: PowerCommandRunning {
    public init() {}

    public func helperAvailability() -> HelperAvailability {
        let status = HelperClient().availability()
        guard let state = HelperState(rawValue: status.state.rawValue) else {
            return HelperAvailability(state: .incompatible, message: "Hearth helper protocol is incompatible. Run explicit setup/repair.")
        }
        return HelperAvailability(state: state, message: status.message)
    }

    public func readSettings() throws -> PowerSettings {
        let executor = ProcessExecutor()
        let custom = try executor.run("/usr/bin/pmset", ["-g", "custom"])
        guard custom.exitCode == 0 else {
            throw HearthError.command("pmset -g custom failed: \(custom.output)")
        }
        let battery = try executor.run("/usr/bin/pmset", ["-g", "batt"])
        guard battery.exitCode == 0 else {
            throw HearthError.command("pmset -g batt failed: \(battery.output)")
        }
        return try PMSetParser().parse(custom: custom.output, battery: battery.output)
    }

    public func apply(_ changes: [PowerChange]) throws -> [CommandOutcome] {
        throw HearthError.invalidInput("Power changes require a journal lock lease. Use HearthService.")
    }

    public func apply(_ changes: [PowerChange], holdingLock descriptor: Int32) throws -> [CommandOutcome] {
        guard !changes.isEmpty else { return [] }
        let requests = try changes.map { change in
            guard let expected = change.expectedMinutes else {
                throw HearthError.invalidInput("A power change must include the observed previous setting.")
            }
            guard let profile = HelperPowerProfile(rawValue: change.profile.rawValue),
                  let setting = HelperPowerSetting(rawValue: change.setting.rawValue) else {
                throw HearthError.invalidInput("Unsupported power setting or profile.")
            }
            return IdleSleepChange(profile: profile, minutes: change.minutes, expectedMinutes: expected, setting: setting)
        }
        let lease = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let outcomes: [HelperCommandOutcome]
        do {
            outcomes = try HelperClient().apply(requests, lease: lease)
        } catch HelperClientError.rejected(let message) {
            outcomes = requests.map {
                HelperCommandOutcome(profile: $0.profile, exitCode: nil, message: message, didExecute: false, setting: $0.setting)
            }
        } catch {
            throw HearthError.indeterminateHelper("Hearth could not confirm the helper's response: \(error.localizedDescription). Pending restore state is retained because the helper may still be working. Run 'hearth status' after it completes; do not retry the change blindly.")
        }
        return try outcomes.map { outcome in
            guard let profile = PowerProfile(rawValue: outcome.profile.rawValue),
                  let setting = PowerSetting(rawValue: outcome.setting.rawValue) else {
                throw HearthError.indeterminateHelper("Hearth helper returned an unknown setting or profile. Pending restore state is retained; explicit update/repair is required.")
            }
            return CommandOutcome(profile: profile, exitCode: outcome.exitCode, message: outcome.message, didExecute: outcome.didExecute, setting: setting)
        }
    }
}
