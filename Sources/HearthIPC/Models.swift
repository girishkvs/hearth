import Foundation

public enum HelperConnectionState: String, Codable, Sendable {
    case ready
    case setupRequired
    case incompatible
    case unavailable
}

public struct HelperConnectionStatus: Codable, Equatable, Sendable {
    public let state: HelperConnectionState
    public let message: String

    public init(state: HelperConnectionState, message: String) {
        self.state = state
        self.message = message
    }
}

public struct IdleSleepChange: Codable, Equatable, Sendable {
    public let profile: String
    public let minutes: Int
    public let expectedMinutes: Int

    public init(profile: String, minutes: Int, expectedMinutes: Int) {
        self.profile = profile
        self.minutes = minutes
        self.expectedMinutes = expectedMinutes
    }
}

public struct HelperCommandOutcome: Codable, Equatable, Sendable {
    public let profile: String
    public let exitCode: Int32?
    public let message: String
    public let didExecute: Bool

    public init(profile: String, exitCode: Int32?, message: String = "", didExecute: Bool = true) {
        self.profile = profile
        self.exitCode = exitCode
        self.message = message
        self.didExecute = didExecute
    }
}

public enum HelperClientError: Error, LocalizedError, Sendable {
    case setupRequired(String)
    case incompatible(String)
    case unavailable(String)
    // A valid helper reply confirms this whole batch was rejected before work.
    case rejected(String)
    // The caller MUST retain its pending journal and skip reconciliation on this error.
    case completionUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .setupRequired(let message), .incompatible(let message), .rejected(let message),
             .unavailable(let message), .completionUnknown(let message):
            message
        }
    }
}

public enum HelperInstallation {
    public static let serviceName = "dev.girishkvs.hearth.helper"
    public static let executablePath = "/Library/PrivilegedHelperTools/dev.girishkvs.hearth.helper"
    public static let policyPath = "/Library/Application Support/Hearth/authorization.plist"
    public static let launchDaemonPath = "/Library/LaunchDaemons/dev.girishkvs.hearth.helper.plist"
    public static let operationLockPath = "/Library/Application Support/Hearth/operation.lock"
}
