import Foundation

@objc public protocol HearthHelperXPC {
    func availability(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func apply(_ request: Data, lease: FileHandle, reply: @escaping @Sendable (Data) -> Void)
}

public struct HelperXPCInterface {
    public init() {}

    public func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: HearthHelperXPC.self)
        let availability = #selector(HearthHelperXPC.availability(_:reply:))
        let apply = #selector(HearthHelperXPC.apply(_:lease:reply:))
        let dataClasses = NSSet(object: NSData.self) as! Set<AnyHashable>
        let handleClasses = NSSet(object: FileHandle.self) as! Set<AnyHashable>
        interface.setClasses(dataClasses, for: availability, argumentIndex: 0, ofReply: false)
        interface.setClasses(dataClasses, for: availability, argumentIndex: 0, ofReply: true)
        interface.setClasses(dataClasses, for: apply, argumentIndex: 0, ofReply: false)
        interface.setClasses(handleClasses, for: apply, argumentIndex: 1, ofReply: false)
        interface.setClasses(dataClasses, for: apply, argumentIndex: 0, ofReply: true)
        return interface
    }
}

public struct HelperWireCodec: Sendable {
    public init() {}

    public func validate(_ changes: [IdleSleepChange]) throws {
        guard (1...2).contains(changes.count) else { throw invalid("Expected one or two changes.") }
        var profiles = Set<String>()
        for change in changes {
            guard ["battery", "adapter"].contains(change.profile),
                  profiles.insert(change.profile).inserted,
                  (0...Int(Int32.max)).contains(change.minutes),
                  (0...Int(Int32.max)).contains(change.expectedMinutes) else {
                throw invalid("Invalid profile, duplicate profile, or timeout.")
            }
        }
    }

    public func availabilityRequest() -> Data { Data(#"{"version":1}"#.utf8) }

    public func decodeAvailabilityRequest(_ data: Data) throws {
        _ = try envelope(data, keys: ["version"])
    }

    public func applyRequest(_ changes: [IdleSleepChange]) throws -> Data {
        try validate(changes)
        return try encode([
            "version": 1,
            "changes": changes.map {
                ["profile": $0.profile, "minutes": $0.minutes, "expectedMinutes": $0.expectedMinutes] as [String: Any]
            },
        ])
    }

    public func decodeApplyRequest(_ data: Data) throws -> [IdleSleepChange] {
        let object = try envelope(data, keys: ["version", "changes"])
        guard case .array(let items) = object["changes"] else { throw invalid("Missing changes.") }
        let changes = try items.map { item -> IdleSleepChange in
            guard case .object(let fields) = item,
                  Set(fields.keys) == ["profile", "minutes", "expectedMinutes"],
                  case .string(let profile) = fields["profile"],
                  case .integer(let minutes) = fields["minutes"],
                  case .integer(let expected) = fields["expectedMinutes"] else {
                throw invalid("Invalid change fields.")
            }
            return IdleSleepChange(profile: profile, minutes: minutes, expectedMinutes: expected)
        }
        try validate(changes)
        return changes
    }

    public func statusReply(_ status: HelperConnectionStatus) -> Data {
        // All fields are bounded before encoding; the fallback is itself a valid failure envelope.
        (try? encode(["version": 1, "state": status.state.rawValue, "message": bounded(status.message)])) ??
            Data(#"{"version":1,"state":"unavailable","message":"Reply encoding failed."}"#.utf8)
    }

    public func decodeStatusReply(_ data: Data) throws -> HelperConnectionStatus {
        try status(envelope(data, keys: ["version", "state", "message"]))
    }

    public func applyReply(_ outcomes: [HelperCommandOutcome], failure: HelperConnectionStatus? = nil) -> Data {
        let status = failure ?? HelperConnectionStatus(state: .ready, message: "")
        let entries: [[String: Any]] = outcomes.prefix(2).map {
            [
                "profile": $0.profile, "exitCode": $0.exitCode.map { $0 as Any } ?? NSNull(),
                "message": bounded($0.message), "didExecute": $0.didExecute,
            ]
        }
        // If encoding ever fails after work, an incomplete outcome list must become
        // completionUnknown at the client, never a false "rejected before work".
        return (try? encode([
            "version": 1, "state": status.state.rawValue, "message": bounded(status.message), "outcomes": entries,
        ])) ?? Data(#"{"version":1,"state":"ready","message":"Reply encoding failed.","outcomes":[]}"#.utf8)
    }

    public func decodeApplyReply(_ data: Data, changes: [IdleSleepChange]) throws -> [HelperCommandOutcome] {
        let object = try envelope(data, keys: ["version", "state", "message", "outcomes"])
        let result = try status(object)
        guard case .array(let entries) = object["outcomes"] else { throw invalid("Missing outcomes.") }
        if result.state != .ready {
            guard entries.isEmpty else { throw invalid("Failure reply contains outcomes.") }
            throw HelperClientError.rejected(result.message)
        }
        guard entries.count == changes.count else { throw invalid("Incomplete helper reply.") }
        return try zip(entries, changes).map { entry, change in
            guard case .object(let fields) = entry,
                  Set(fields.keys) == ["profile", "exitCode", "message", "didExecute"],
                  case .string(let profile) = fields["profile"],
                  profile == change.profile,
                  case .string(let message) = fields["message"],
                  case .boolean(let didExecute) = fields["didExecute"] else {
                throw invalid("Invalid outcome fields.")
            }
            let exitCode: Int32?
            switch fields["exitCode"] {
            case .null: exitCode = nil
            case .integer(let value) where Int32(exactly: value) != nil: exitCode = Int32(value)
            default: throw invalid("Invalid exit status.")
            }
            guard didExecute || exitCode != 0 else { throw invalid("A skipped write cannot report success.") }
            return HelperCommandOutcome(profile: profile, exitCode: exitCode, message: message, didExecute: didExecute)
        }
    }

    private func envelope(_ data: Data, keys: Set<String>) throws -> [String: WireValue] {
        var parser = StrictWireJSON(data: data)
        guard case .object(let object) = try parser.parse(),
              Set(object.keys) == keys,
              case .integer(1) = object["version"] else {
            throw invalid("Unsupported helper protocol or fields. Run explicit setup/repair.")
        }
        return object
    }

    private func status(_ object: [String: WireValue]) throws -> HelperConnectionStatus {
        guard case .string(let state) = object["state"],
              let parsed = HelperConnectionState(rawValue: state),
              case .string(let message) = object["message"] else { throw invalid("Invalid helper status.") }
        return HelperConnectionStatus(state: parsed, message: message)
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 4096 else { throw invalid("Helper envelope is too large.") }
        return data
    }

    private func bounded(_ message: String) -> String {
        var result = ""
        var utf8Bytes = 0
        var escapedBytes = 0
        for scalar in message.unicodeScalars {
            let text = String(scalar)
            let bytes = text.utf8.count
            let escaped = scalar.value < 32 ? 6 : ([34, 47, 92].contains(scalar.value) ? 2 : bytes)
            guard utf8Bytes + bytes <= 512, escapedBytes + escaped <= 768 else { break }
            result += text
            utf8Bytes += bytes
            escapedBytes += escaped
        }
        return result
    }

    private func invalid(_ message: String) -> HelperClientError { .incompatible(message) }
}

private indirect enum WireValue {
    case object([String: WireValue])
    case array([WireValue])
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case null
}

// A deliberately small JSON grammar: duplicate keys, floats, deep trees,
// and extra fields must not be normalized away by a permissive decoder.
private struct StrictWireJSON {
    let bytes: [UInt8]
    var index = 0

    init(data: Data) { bytes = Array(data.prefix(4097)) }

    mutating func parse() throws -> WireValue {
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw invalid() }
        let result = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw invalid() }
        return result
    }

    private mutating func value(depth: Int) throws -> WireValue {
        whitespace()
        guard depth <= 5, index < bytes.count else { throw invalid() }
        switch bytes[index] {
        case 123:
            index += 1
            var fields: [String: WireValue] = [:]
            if consume(125) { return .object(fields) }
            repeat {
                whitespace()
                let key = try string()
                guard fields[key] == nil, fields.count < 8, consume(58) else { throw invalid() }
                fields[key] = try value(depth: depth + 1)
                if consume(125) { return .object(fields) }
                guard consume(44) else { throw invalid() }
            } while true
        case 91:
            index += 1
            var values: [WireValue] = []
            if consume(93) { return .array(values) }
            repeat {
                guard values.count < 2 else { throw invalid() }
                values.append(try value(depth: depth + 1))
                if consume(93) { return .array(values) }
                guard consume(44) else { throw invalid() }
            } while true
        case 34: return .string(try string())
        case 110:
            guard bytes[index...].starts(with: Array("null".utf8)) else { throw invalid() }
            index += 4
            return .null
        case 116:
            guard bytes[index...].starts(with: Array("true".utf8)) else { throw invalid() }
            index += 4
            return .boolean(true)
        case 102:
            guard bytes[index...].starts(with: Array("false".utf8)) else { throw invalid() }
            index += 5
            return .boolean(false)
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
                guard data.count <= 1024,
                      let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
                    throw invalid()
                }
                return value
            }
            if byte == 92, !escaped { escaped = true } else { escaped = false }
        }
        throw invalid()
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

    private func invalid() -> HelperClientError { .incompatible("Malformed or oversized helper envelope.") }
}
