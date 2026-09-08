import CryptoKit
import Foundation

public enum ScreenSaverStoredValue: Codable, Equatable, Sendable {
    case absent
    case integer(Int)

    private enum CodingKeys: String, CodingKey { case absent, integer }
    private enum IntegerKeys: String, CodingKey { case value = "_0" }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 1 else {
            throw HearthError.state("Invalid stored screen-saver value.")
        }
        if values.contains(.absent) {
            let absent = try values.nestedContainer(keyedBy: IntegerKeys.self, forKey: .absent)
            guard absent.allKeys.isEmpty else { throw HearthError.state("Absent screen-saver value contains an integer.") }
            self = .absent
        } else {
            let integer = try values.nestedContainer(keyedBy: IntegerKeys.self, forKey: .integer)
            self = .integer(try integer.decode(Int.self, forKey: .value))
        }
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absent:
            _ = values.nestedContainer(keyedBy: IntegerKeys.self, forKey: .absent)
        case .integer(let seconds):
            var integer = values.nestedContainer(keyedBy: IntegerKeys.self, forKey: .integer)
            try integer.encode(seconds, forKey: .value)
        }
    }

    public func validate() throws {
        if case .integer(let seconds) = self,
           !(0...Int(Int32.max)).contains(seconds) {
            throw HearthError.state("Invalid stored screen-saver integer.")
        }
    }
}

public enum ScreenSaverPreferenceScope: String, Codable, Sendable {
    case currentUserCurrentHost
    case currentUserAnyHost
    case anyUserAnyHost
    case registeredDefaults
}

public struct ScreenSaverConfiguration: Codable, Equatable, Sendable {
    public let storedValue: ScreenSaverStoredValue
    public let effectiveSeconds: Int
    public let dictionarySource: ScreenSaverPreferenceScope
    public let valueSource: ScreenSaverPreferenceScope
    public let contextFingerprint: String

    public init(
        storedValue: ScreenSaverStoredValue, effectiveSeconds: Int,
        dictionarySource: ScreenSaverPreferenceScope, valueSource: ScreenSaverPreferenceScope,
        contextFingerprint: String
    ) {
        self.storedValue = storedValue
        self.effectiveSeconds = effectiveSeconds
        self.dictionarySource = dictionarySource
        self.valueSource = valueSource
        self.contextFingerprint = contextFingerprint
    }

    public func validate() throws {
        try storedValue.validate()
        guard (0...Int(Int32.max)).contains(effectiveSeconds),
              contextFingerprint.utf8.count == 64,
              contextFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              valueSource == dictionarySource || valueSource == .registeredDefaults else {
            throw HearthError.state("Invalid screen-saver configuration.")
        }
        switch storedValue {
        case .integer(let seconds):
            guard effectiveSeconds == seconds,
                  dictionarySource == .currentUserCurrentHost,
                  valueSource == .currentUserCurrentHost else {
                throw HearthError.state("Stored screen-saver integer does not match its source.")
            }
        case .absent:
            guard valueSource != .currentUserCurrentHost else {
                throw HearthError.state("Absent screen-saver preference cannot be its value source.")
            }
        }
    }
}

public enum ScreenSaverAvailability: String, Codable, Sendable {
    case ready
    case setupRequired
    case managed
    case unavailable
}

public struct ScreenSaverObservation: Equatable, Sendable {
    public let delaySeconds: Int?
    public let availability: ScreenSaverAvailability
    public let message: String
    public let configuration: ScreenSaverConfiguration?

    public init(
        delaySeconds: Int?, availability: ScreenSaverAvailability, message: String,
        configuration: ScreenSaverConfiguration? = nil
    ) {
        self.delaySeconds = delaySeconds
        self.availability = availability
        self.message = message
        self.configuration = configuration
    }
}

public enum ScreenSaverError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case rejected(String)
    case completionUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .rejected(let message), .completionUnknown(let message): message
        }
    }
}

public protocol ScreenSaverControlling: Sendable {
    func observe() throws -> ScreenSaverObservation
    func apply(value: ScreenSaverStoredValue, expected: ScreenSaverConfiguration) throws
}

public enum IdleLockAction: String, Codable, Sendable {
    case on
    case restore
}

public struct IdleLockRequest: Codable, Equatable, Sendable {
    public let action: IdleLockAction
    public init(action: IdleLockAction) { self.action = action }
}

public enum IdleLockPhase: String, Codable, Sendable {
    case off
    case active
    case needsRestore
    case setupRequired
    case unavailable
    case uncertain
}

public struct IdleLockDependency: Codable, Equatable, Sendable {
    public let setting: PowerSetting
    public let profile: PowerProfile
    public let acquired: Bool
    public let actualMinutes: Int?

    public init(setting: PowerSetting, profile: PowerProfile, acquired: Bool, actualMinutes: Int?) {
        self.setting = setting
        self.profile = profile
        self.acquired = acquired
        self.actualMinutes = actualMinutes
    }
}

public struct IdleLockStatus: Codable, Equatable, Sendable {
    public let phase: IdleLockPhase
    public let message: String
    public let saverDelaySeconds: Int?
    public let originalSaverDelaySeconds: Int?
    public let dependencies: [IdleLockDependency]
    public let canEnable: Bool
    public let canRestore: Bool
    public let hasManagedChanges: Bool
    public let journalFingerprint: String?

    public init(
        phase: IdleLockPhase, message: String, saverDelaySeconds: Int? = nil,
        originalSaverDelaySeconds: Int? = nil, dependencies: [IdleLockDependency] = [],
        canEnable: Bool = false, canRestore: Bool = false, hasManagedChanges: Bool = false,
        journalFingerprint: String? = nil
    ) {
        self.phase = phase
        self.message = message
        self.saverDelaySeconds = saverDelaySeconds
        self.originalSaverDelaySeconds = originalSaverDelaySeconds
        self.dependencies = dependencies
        self.canEnable = canEnable
        self.canRestore = canRestore
        self.hasManagedChanges = hasManagedChanges
        self.journalFingerprint = journalFingerprint
    }

    public func requires(_ setting: PowerSetting, profile: PowerProfile) -> Bool {
        hasManagedChanges && dependencies.contains { $0.setting == setting && $0.profile == profile }
    }

    public var recoveryGuidance: String? {
        guard phase == .uncertain else { return nil }
        return """
        Unconfirmed does not mean cancelled or unchanged. Lock, Restore Lock and required System/Display changes are blocked; original values are retained.
        First preserve ~/Library/Application Support/Hearth/state.json. Then collect 'hearth status --json' and the last error for a recovery review with girish.sai1@gmail.com. Status does not retry the write; redact private paths before sharing.
        Do not clear state or treat restart, logout, reboot or matching readings as proof of completion.
        """
    }
}

public struct IdleLockResult: Codable, Sendable {
    public let succeeded: Bool
    public let message: String
    public let status: IdleLockStatus

    public init(succeeded: Bool, message: String, status: IdleLockStatus) {
        self.succeeded = succeeded
        self.message = message
        self.status = status
    }
}

public protocol IdleLockControlling: Sendable {
    func status() throws -> IdleLockStatus
    func perform(_ request: IdleLockRequest) throws -> IdleLockResult
}

struct LockPowerOwnership: Codable, Equatable, Sendable {
    let setting: PowerSetting
    let profile: PowerProfile
    let original: Int?
    var released = false
}

struct LockOverride: Codable, Equatable, Sendable {
    enum Backend: String, Codable, Sendable {
        case preferences
        case legacyAppleEvents
    }

    enum Phase: String, Codable, Sendable {
        case enabling
        case active
        case restoring
    }

    var phase: Phase
    var dependencies: [LockPowerOwnership]
    let saverOriginal: Int?
    var saverApplied = false
    // A crash or uncertain completion never becomes confirmation through later reads.
    var saverWritePending = false
    var saverReleased = false
    // Earlier records omit this; release alone does not identify its cause.
    var saverExternalChangePreserved: Bool?
    let backend: Backend
    let recordVersion: Int
    let saverOriginalConfiguration: ScreenSaverConfiguration?
    var saverAppliedConfiguration: ScreenSaverConfiguration?

    init(
        phase: Phase, dependencies: [LockPowerOwnership], saverOriginal: Int?,
        saverApplied: Bool = false, saverWritePending: Bool = false, saverReleased: Bool = false,
        saverExternalChangePreserved: Bool? = nil,
        backend: Backend = .legacyAppleEvents, recordVersion: Int = 1,
        saverOriginalConfiguration: ScreenSaverConfiguration? = nil,
        saverAppliedConfiguration: ScreenSaverConfiguration? = nil
    ) {
        self.phase = phase
        self.dependencies = dependencies
        self.saverOriginal = saverOriginal
        self.saverApplied = saverApplied
        self.saverWritePending = saverWritePending
        self.saverReleased = saverReleased
        self.saverExternalChangePreserved = saverExternalChangePreserved
        self.backend = backend
        self.recordVersion = recordVersion
        self.saverOriginalConfiguration = saverOriginalConfiguration
        self.saverAppliedConfiguration = saverAppliedConfiguration
    }

    private enum CodingKeys: String, CodingKey {
        case phase, dependencies, saverOriginal, saverApplied, saverWritePending, saverReleased
        case saverExternalChangePreserved
        case backend, recordVersion, saverOriginalConfiguration, saverAppliedConfiguration
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        phase = try values.decode(Phase.self, forKey: .phase)
        dependencies = try values.decode([LockPowerOwnership].self, forKey: .dependencies)
        saverOriginal = try values.decodeIfPresent(Int.self, forKey: .saverOriginal)
        saverApplied = try values.decode(Bool.self, forKey: .saverApplied)
        saverWritePending = try values.decode(Bool.self, forKey: .saverWritePending)
        saverReleased = try values.decode(Bool.self, forKey: .saverReleased)
        saverExternalChangePreserved = try values.decodeIfPresent(Bool.self, forKey: .saverExternalChangePreserved)
        backend = values.contains(.backend)
            ? try values.decode(Backend.self, forKey: .backend)
            : .legacyAppleEvents
        recordVersion = backend == .preferences
            ? try values.decode(Int.self, forKey: .recordVersion)
            : try values.decodeIfPresent(Int.self, forKey: .recordVersion) ?? 1
        saverOriginalConfiguration = try values.decodeIfPresent(ScreenSaverConfiguration.self, forKey: .saverOriginalConfiguration)
        saverAppliedConfiguration = try values.decodeIfPresent(ScreenSaverConfiguration.self, forKey: .saverAppliedConfiguration)
    }

    var legacyTimerNeedsReview: Bool {
        backend == .legacyAppleEvents && (saverWritePending || (saverApplied && !saverReleased))
    }

    var pendingMessage: String {
        backend == .legacyAppleEvents
            ? "Legacy AppleEvents timer completion is unconfirmed. Matching preferences or process death cannot clear this intent; explicit recovery review is required."
            : "CFPreferences timer completion is unconfirmed. Stored matches cannot confirm the interrupted write; explicit recovery review is required."
    }

    var legacyRecoveryMessage: String {
        "Legacy AppleEvents timer ownership has no typed preference-presence baseline. CFPreferences cannot safely restore it. Keep state.json for explicit recovery review; Lock and required settings remain blocked."
    }

    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard recordVersion == 1,
              (2...4).contains(dependencies.count),
              saverOriginal.map({ (1...Int(Int32.max)).contains($0) }) ?? true else {
            throw HearthError.state("Invalid Lock restore state.")
        }
        var keys = Set<String>()
        for dependency in dependencies {
            guard keys.insert("\(dependency.setting.rawValue):\(dependency.profile.rawValue)").inserted,
                  dependency.original.map({ (1...Int(Int32.max)).contains($0) }) ?? true else {
                throw HearthError.state("Invalid Lock power dependency.")
            }
        }
        let system = Set(dependencies.filter { $0.setting == .system }.map(\.profile))
        let display = Set(dependencies.filter { $0.setting == .display }.map(\.profile))
        guard system == display,
              !system.isEmpty,
              !saverApplied || saverOriginal != nil,
              !saverWritePending || saverOriginal != nil,
              !saverReleased || (saverApplied && saverOriginal != nil) else {
            throw HearthError.state("Inconsistent Lock restore state.")
        }
        if phase == .active {
            guard dependencies.allSatisfy({ !$0.released }),
                  !saverReleased,
                  !saverWritePending,
                  saverOriginal == nil || saverApplied else {
                throw HearthError.state("Unconfirmed Lock state cannot be active.")
            }
        }
        guard saverExternalChangePreserved != true ||
                (backend == .preferences && saverReleased && saverApplied) else {
            throw HearthError.state("Invalid preserved screen-saver change provenance.")
        }
        switch backend {
        case .legacyAppleEvents:
            guard saverOriginalConfiguration == nil, saverAppliedConfiguration == nil else {
                throw HearthError.state("Legacy Lock state cannot contain a preference-presence baseline.")
            }
        case .preferences:
            guard let original = saverOriginalConfiguration else {
                throw HearthError.state("Lock preference baseline is missing.")
            }
            try original.validate()
            guard saverOriginal == (original.effectiveSeconds == 0 ? nil : original.effectiveSeconds),
                  saverApplied == (saverAppliedConfiguration != nil) else {
                throw HearthError.state("Inconsistent Lock preference ownership.")
            }
            if let applied = saverAppliedConfiguration {
                try applied.validate()
                guard applied.storedValue == .integer(0),
                      applied.effectiveSeconds == 0,
                      applied.contextFingerprint == original.contextFingerprint else {
                    throw HearthError.state("Invalid confirmed Lock preference configuration.")
                }
            }
        }
    }
}
