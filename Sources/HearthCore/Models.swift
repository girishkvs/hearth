import Foundation

public enum PowerProfile: String, Codable, CaseIterable, Sendable {
    case battery
    case adapter

    public var label: String { self == .battery ? "Battery" : "Power adapter" }
    public var pmsetFlag: String { self == .battery ? "-b" : "-c" }
}

public enum PowerTarget: String, Codable, CaseIterable, Sendable {
    case both
    case battery
    case adapter

    public var profiles: [PowerProfile] {
        switch self {
        case .both: PowerProfile.allCases
        case .battery: [.battery]
        case .adapter: [.adapter]
        }
    }
}

public enum PowerAction: String, Codable, Sendable {
    case on
    case restore
    case sleep
}

public struct PowerRequest: Codable, Equatable, Sendable {
    public let action: PowerAction
    public let target: PowerTarget
    public let minutes: Int?

    public init(action: PowerAction, target: PowerTarget = .both, minutes: Int? = nil) throws {
        if action == .sleep {
            guard let minutes, (1...Int(Int32.max)).contains(minutes) else {
                throw HearthError.invalidInput("Sleep minutes must be an integer from 1 to \(Int32.max). Use 'on' for zero.")
            }
        } else if minutes != nil {
            throw HearthError.invalidInput("Only the sleep action accepts minutes.")
        }
        self.action = action
        self.target = target
        self.minutes = minutes
    }

    public func validated() throws -> PowerRequest {
        try PowerRequest(action: action, target: target, minutes: minutes)
    }
}

public struct PowerSettings: Equatable, Sendable {
    public let values: [PowerProfile: Int]
    public let currentSource: String

    public init(values: [PowerProfile: Int], currentSource: String = "Unknown") {
        self.values = values
        self.currentSource = currentSource
    }
}

public struct PowerChange: Equatable, Sendable {
    public let profile: PowerProfile
    public let minutes: Int
    public let expectedMinutes: Int?

    public init(profile: PowerProfile, minutes: Int, expectedMinutes: Int? = nil) throws {
        guard (0...Int(Int32.max)).contains(minutes) else {
            throw HearthError.invalidInput("Power timeout is outside pmset's supported integer range.")
        }
        if let expectedMinutes, !(0...Int(Int32.max)).contains(expectedMinutes) {
            throw HearthError.invalidInput("Expected power timeout is outside the supported integer range.")
        }
        self.profile = profile
        self.minutes = minutes
        self.expectedMinutes = expectedMinutes
    }
}

public struct CommandOutcome: Equatable, Sendable {
    public let profile: PowerProfile
    public let exitCode: Int32?
    public let message: String
    public let didExecute: Bool

    public init(profile: PowerProfile, exitCode: Int32?, message: String = "", didExecute: Bool = true) {
        self.profile = profile
        self.exitCode = exitCode
        self.message = message
        self.didExecute = didExecute
    }
}

public protocol PowerCommandRunning: Sendable {
    func helperAvailability() -> HelperAvailability
    func readSettings() throws -> PowerSettings
    func apply(_ changes: [PowerChange]) throws -> [CommandOutcome]
    func apply(_ changes: [PowerChange], holdingLock descriptor: Int32) throws -> [CommandOutcome]
}

extension PowerCommandRunning {
    public func helperAvailability() -> HelperAvailability { .ready }

    public func apply(_ changes: [PowerChange], holdingLock descriptor: Int32) throws -> [CommandOutcome] {
        try apply(changes)
    }
}

public enum HelperState: String, Codable, Sendable {
    case ready
    case setupRequired
    case incompatible
    case unavailable
}

public struct HelperAvailability: Codable, Equatable, Sendable {
    public let state: HelperState
    public let message: String
    public var isReady: Bool { state == .ready }
    public static let ready = HelperAvailability(state: .ready, message: "Hearth helper is ready. Power changes do not require another administrator prompt.")

    public init(state: HelperState, message: String) {
        self.state = state
        self.message = message
    }
}

public struct ProfileStatus: Codable, Equatable, Sendable {
    public let profile: PowerProfile
    public let actualMinutes: Int?
    public let originalMinutes: Int?
    public let appliedMinutes: Int?
    public let phase: String?

    public var isManaged: Bool { originalMinutes != nil }
    public var actualDescription: String {
        guard let actualMinutes else { return "Not available" }
        return actualMinutes == 0 ? "Never idle sleeps" : "Idle sleep after \(actualMinutes) minute(s)"
    }
}

public struct HearthStatus: Codable, Sendable {
    public let schemaVersion: Int
    public let currentSource: String
    public let profiles: [ProfileStatus]
    public let warnings: [String]
    public let helper: HelperAvailability

    public var hasManagedChanges: Bool {
        profiles.contains { $0.isManaged || $0.phase != nil }
    }
}

public enum OutcomeKind: String, Codable, Sendable {
    case changed
    case unchanged
    case preserved
    case failed
}

public struct ProfileOutcome: Codable, Sendable {
    public let profile: PowerProfile
    public let kind: OutcomeKind
    public let message: String
    public let actualMinutes: Int?
    public let commandExitCode: Int32?
}

public struct OperationResult: Codable, Sendable {
    public let succeeded: Bool
    public let outcomes: [ProfileOutcome]
    public let status: HearthStatus
}

public enum HearthError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    case command(String)
    case state(String)
    case helperUnavailable(String)
    case indeterminateHelper(String)
    case busy

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .command(let message), .state(let message),
             .helperUnavailable(let message), .indeterminateHelper(let message): message
        case .busy: "Another Hearth operation is running. Wait for it to complete, then retry."
        }
    }
}
