import Foundation
import HearthCore

public enum IdleLockClientError: Error, LocalizedError, Sendable {
    case setupRequired(String)
    case unavailable(String)
    case incompatible(String)
    case rejected(String)
    case completionUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .setupRequired(let message), .unavailable(let message), .incompatible(let message),
             .rejected(let message), .completionUnknown(let message): message
        }
    }
}

@objc protocol HearthLockXPC {
    func handshake(reply: @escaping @Sendable (Int) -> Void)
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void)
}

struct LockXPCInterface {
    func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: HearthLockXPC.self)
        let selector = #selector(HearthLockXPC.request(_:reply:))
        let classes = NSSet(object: NSData.self) as! Set<AnyHashable>
        interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: false)
        interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: true)
        return interface
    }
}

enum LockWireAction: String, Sendable {
    case status, on, restore

    var request: IdleLockRequest? {
        switch self {
        case .status: nil
        case .on: IdleLockRequest(action: .on)
        case .restore: IdleLockRequest(action: .restore)
        }
    }
}

enum LockWireReply {
    case status(IdleLockStatus)
    case result(IdleLockResult)
}

struct LockWireCodec: Sendable {
    static let version = 2
    static let maximumBytes = 8192
    static let unknownMessage =
        "Lock completion is unknown. Do not retry automatically. Preserve the journal and check status and retained restore information."

    func request(_ action: LockWireAction) -> Data {
        Data("{\"version\":\(Self.version),\"action\":\"\(action.rawValue)\"}".utf8)
    }

    func decodeRequest(_ data: Data) throws -> LockWireAction {
        guard data.count <= 128 else { throw invalid() }
        let fields = try envelope(data)
        guard Set(fields.keys) == ["version", "action"],
              case .string(let action) = fields["action"],
              let parsed = LockWireAction(rawValue: action) else { throw invalid() }
        return parsed
    }

    func statusReply(_ status: IdleLockStatus) -> Data {
        do {
            let data = try encode([
                "version": Self.version, "action": "status", "outcome": "status", "status": statusFields(status),
            ])
            _ = try decodeReply(data, action: .status)
            return data
        } catch { return failure(.status, outcome: "unavailable", message: "Native Lock status could not be encoded.") }
    }

    func resultReply(_ result: IdleLockResult, action: LockWireAction) -> Data {
        do {
            let data = try encode([
                "version": Self.version, "action": action.rawValue, "outcome": "result",
                "result": [
                    "succeeded": result.succeeded, "message": bounded(result.message), "status": statusFields(result.status),
                ],
            ])
            _ = try decodeReply(data, action: action)
            return data
        } catch {
            // Encoding happens AFTER the controller may have written. Never turn
            // this path into a before-write rejection.
            return failure(action, outcome: "unknown", message: Self.unknownMessage)
        }
    }

    func failure(_ action: LockWireAction, outcome: String, message: String) -> Data {
        (try? encode([
            "version": Self.version, "action": action.rawValue, "outcome": outcome, "message": bounded(message),
        ])) ?? Data(#"{"version":2,"action":"status","outcome":"unavailable","message":"Invalid reply."}"#.utf8)
    }

    func decodeReply(_ data: Data, action: LockWireAction) throws -> LockWireReply {
        let fields = try envelope(data)
        guard case .string(action.rawValue) = fields["action"],
              case .string(let outcome) = fields["outcome"] else { throw invalid() }
        switch outcome {
        case "status":
            guard action == .status,
                  Set(fields.keys) == ["version", "action", "outcome", "status"] else { throw invalid() }
            return .status(try status(fields["status"]))
        case "result":
            guard action != .status,
                  Set(fields.keys) == ["version", "action", "outcome", "result"],
                  case .object(let result) = fields["result"],
                  Set(result.keys) == ["succeeded", "message", "status"],
                  case .boolean(let succeeded) = result["succeeded"] else { throw invalid() }
            return .result(IdleLockResult(
                succeeded: succeeded, message: try message(result["message"]), status: try status(result["status"])
            ))
        case "rejected", "unknown", "unavailable":
            guard Set(fields.keys) == ["version", "action", "outcome", "message"] else { throw invalid() }
            let text = try message(fields["message"])
            switch outcome {
            case "rejected": throw IdleLockClientError.rejected(text)
            case "unknown": throw IdleLockClientError.completionUnknown(text)
            default: throw IdleLockClientError.unavailable(text)
            }
        default: throw invalid()
        }
    }

    private func statusFields(_ status: IdleLockStatus) -> [String: Any] {
        [
            "phase": status.phase.rawValue, "message": bounded(status.message),
            "saverDelaySeconds": status.saverDelaySeconds.map { $0 as Any } ?? NSNull(),
            "originalSaverDelaySeconds": status.originalSaverDelaySeconds.map { $0 as Any } ?? NSNull(),
            "journalFingerprint": status.journalFingerprint.map { $0 as Any } ?? NSNull(),
            "canEnable": status.canEnable, "canRestore": status.canRestore, "hasManagedChanges": status.hasManagedChanges,
            "dependencies": status.dependencies.map {
                [
                    "setting": $0.setting.rawValue, "profile": $0.profile.rawValue, "acquired": $0.acquired,
                    "actualMinutes": $0.actualMinutes.map { $0 as Any } ?? NSNull(),
                ] as [String: Any]
            },
        ]
    }

    private func status(_ value: LockJSONValue?) throws -> IdleLockStatus {
        guard case .object(let fields) = value,
              Set(fields.keys) == [
                "phase", "message", "saverDelaySeconds", "originalSaverDelaySeconds",
                "canEnable", "canRestore", "hasManagedChanges", "dependencies", "journalFingerprint",
              ],
              case .string(let name) = fields["phase"], let phase = IdleLockPhase(rawValue: name),
              case .boolean(let canEnable) = fields["canEnable"],
              case .boolean(let canRestore) = fields["canRestore"],
              case .boolean(let managed) = fields["hasManagedChanges"],
              case .array(let items) = fields["dependencies"], items.count <= 4 else { throw invalid() }
        var keys = Set<String>()
        let dependencies = try items.map { item in
            guard case .object(let fields) = item,
                  Set(fields.keys) == ["setting", "profile", "acquired", "actualMinutes"],
                  case .string(let settingName) = fields["setting"], let setting = PowerSetting(rawValue: settingName),
                  case .string(let profileName) = fields["profile"], let profile = PowerProfile(rawValue: profileName),
                  case .boolean(let acquired) = fields["acquired"],
                  keys.insert("\(settingName):\(profileName)").inserted else { throw invalid() }
            return IdleLockDependency(
                setting: setting, profile: profile, acquired: acquired, actualMinutes: try timeout(fields["actualMinutes"])
            )
        }
        return IdleLockStatus(
            phase: phase, message: try message(fields["message"]), saverDelaySeconds: try timeout(fields["saverDelaySeconds"]),
            originalSaverDelaySeconds: try timeout(fields["originalSaverDelaySeconds"], minimum: 1),
            dependencies: dependencies, canEnable: canEnable, canRestore: canRestore, hasManagedChanges: managed,
            journalFingerprint: try fingerprint(fields["journalFingerprint"])
        )
    }

    private func fingerprint(_ value: LockJSONValue?) throws -> String? {
        switch value {
        case .null: return nil
        case .string(let text):
            guard text.utf8.count == 64,
                  text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid() }
            return text
        default: throw invalid()
        }
    }

    private func timeout(_ value: LockJSONValue?, minimum: Int = 0) throws -> Int? {
        switch value {
        case .null: nil
        case .integer(let number) where (minimum...Int(Int32.max)).contains(number): number
        default: throw invalid()
        }
    }

    private func message(_ value: LockJSONValue?) throws -> String {
        guard case .string(let text) = value, text.utf8.count <= 768 else { throw invalid() }
        return text
    }

    private func envelope(_ data: Data) throws -> [String: LockJSONValue] {
        var parser = LockJSONParser(data: data)
        guard case .object(let fields) = try parser.parse(),
              case .integer(Self.version) = fields["version"] else { throw invalid() }
        return fields
    }

    private func encode(_ fields: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard data.count <= Self.maximumBytes else { throw invalid() }
        return data
    }

    private func bounded(_ text: String) -> String {
        var output = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let next = String(scalar)
            guard bytes + next.utf8.count <= 768 else { break }
            output += next
            bytes += next.utf8.count
        }
        return output
    }

    private func invalid() -> IdleLockClientError {
        .incompatible("Malformed or incompatible Lock protocol. Use matching Hearth app, CLI, and helper; run explicit setup/repair.")
    }
}

private indirect enum LockJSONValue {
    case object([String: LockJSONValue]), array([LockJSONValue]), string(String), integer(Int), boolean(Bool), null
}

// JSONDecoder discards duplicate/unknown keys and normalizes number types.
// This bounded grammar rejects those before interpreting any operation.
private struct LockJSONParser {
    let bytes: [UInt8]
    var index = 0

    init(data: Data) { bytes = Array(data.prefix(LockWireCodec.maximumBytes + 1)) }

    mutating func parse() throws -> LockJSONValue {
        guard !bytes.isEmpty, bytes.count <= LockWireCodec.maximumBytes else { throw invalid() }
        let result = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw invalid() }
        return result
    }

    private mutating func value(depth: Int) throws -> LockJSONValue {
        whitespace()
        guard depth <= 5, index < bytes.count else { throw invalid() }
        switch bytes[index] {
        case 123:
            index += 1
            var fields: [String: LockJSONValue] = [:]
            if consume(125) { return .object(fields) }
            repeat {
                whitespace()
                let key = try string()
                guard fields[key] == nil, fields.count < 9, consume(58) else { throw invalid() }
                fields[key] = try value(depth: depth + 1)
                if consume(125) { return .object(fields) }
                guard consume(44) else { throw invalid() }
            } while true
        case 91:
            index += 1
            var values: [LockJSONValue] = []
            if consume(93) { return .array(values) }
            repeat {
                guard values.count < 4 else { throw invalid() }
                values.append(try value(depth: depth + 1))
                if consume(93) { return .array(values) }
                guard consume(44) else { throw invalid() }
            } while true
        case 34: return .string(try string())
        case 110: try literal("null"); return .null
        case 116: try literal("true"); return .boolean(true)
        case 102: try literal("false"); return .boolean(false)
        default:
            let start = index
            if bytes[index] == 45 { index += 1 }
            let digits = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            guard index > digits,
                  index - digits == 1 || bytes[digits] != 48,
                  let number = Int(String(decoding: bytes[start..<index], as: UTF8.self)) else { throw invalid() }
            return .integer(number)
        }
    }

    private mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 else { throw invalid() }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34, !escaped {
                let data = Data(bytes[start..<index])
                guard data.count <= 4610,
                      let text = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String,
                      text.utf8.count <= 768 else { throw invalid() }
                return text
            }
            if byte == 92, !escaped { escaped = true } else { escaped = false }
        }
        throw invalid()
    }

    private mutating func literal(_ text: String) throws {
        guard bytes[index...].starts(with: text.utf8) else { throw invalid() }
        index += text.utf8.count
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private func invalid() -> IdleLockClientError { .incompatible("Malformed or oversized Lock envelope.") }
}
