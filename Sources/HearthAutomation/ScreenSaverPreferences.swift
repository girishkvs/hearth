import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import HearthCore

enum ScreenSaverReadScope: String, CaseIterable {
    case currentUserCurrentHost, currentUserAnyHost, anyUserCurrentHost, anyUserAnyHost

    var user: CFString {
        self == .currentUserCurrentHost || self == .currentUserAnyHost ? kCFPreferencesCurrentUser : kCFPreferencesAnyUser
    }

    var host: CFString {
        self == .currentUserCurrentHost || self == .anyUserCurrentHost ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
    }
}

struct ScreenSaverEngineDefaults {
    let values: [String: Any]
    let resourceData: Data
    let runtimeIdentity: String

    init(values: [String: Any], resourceData: Data, runtimeIdentity: String = "synthetic") {
        self.values = values
        self.resourceData = resourceData
        self.runtimeIdentity = runtimeIdentity
    }
}

protocol ScreenSaverPreferencesAccessing: Sendable {
    func copyValues(in scope: ScreenSaverReadScope) throws -> [String: Any]
    func copyCurrentHostTimer() -> Any?
    func engineDefaults() throws -> ScreenSaverEngineDefaults
    func setCurrentHostTimer(_ value: ScreenSaverStoredValue) throws
    func synchronizeCurrentHost() -> Bool
}

struct NativeScreenSaverPreferences: ScreenSaverPreferencesAccessing {
    private var domain: CFString { "com.apple.screensaver" as CFString }
    private var key: CFString { "idleTime" as CFString }

    func copyValues(in scope: ScreenSaverReadScope) throws -> [String: Any] {
        let values = CFPreferencesCopyMultiple(nil, domain, scope.user, scope.host)
        guard let dictionary = values as? [String: Any] else {
            throw ScreenSaverError.unavailable("The screen-saver preference domain has an unsupported dictionary format.")
        }
        return dictionary
    }

    func copyCurrentHostTimer() -> Any? {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    func engineDefaults() throws -> ScreenSaverEngineDefaults {
        let url = URL(fileURLWithPath: "/System/Library/Frameworks/ScreenSaver.framework/Versions/A/Resources/EngineDefaults.plist")
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576,
              let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ScreenSaverError.unavailable("The installed ScreenSaver engine default resource is unavailable or unsupported; no timer baseline is guessed.")
        }
        return ScreenSaverEngineDefaults(
            values: values, resourceData: data, runtimeIdentity: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    func setCurrentHostTimer(_ value: ScreenSaverStoredValue) throws {
        guard getuid() != 0, geteuid() == getuid() else {
            throw ScreenSaverError.rejected("Timer preferences require the current non-root user; no preference was written.")
        }
        let stored: CFPropertyList?
        switch value {
        case .absent:
            stored = nil
        case .integer(let seconds):
            guard let seconds = Int32(exactly: seconds), seconds >= 0 else {
                throw ScreenSaverError.rejected("The timer preference must be an integer from zero through Int32.max.")
            }
            stored = NSNumber(value: seconds)
        }
        CFPreferencesSetValue(key, stored, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    func synchronizeCurrentHost() -> Bool {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
}

struct ScreenSaverPreferenceImage {
    let configuration: ScreenSaverConfiguration
    private let domains: [ScreenSaverReadScope: [String: Any]]
    private let resource: ScreenSaverEngineDefaults
    private let otherEffectiveValues: [String: Any]

    init(domains: [ScreenSaverReadScope: [String: Any]], exactTimer: ScreenSaverStoredValue, resource: ScreenSaverEngineDefaults) throws {
        guard Set(domains.keys) == Set(ScreenSaverReadScope.allCases) else {
            throw ScreenSaverError.unavailable("The complete screen-saver preference context is unavailable.")
        }
        let resolver = ScreenSaverPreferenceResolver()
        try resolver.validate(exactTimer)
        let primary = domains[.currentUserCurrentHost] ?? [:]
        guard try resolver.storedValue(primary["idleTime"]) == exactTimer else {
            throw ScreenSaverError.unavailable("The timer changed between scoped reads. No preference write is allowed from this observation.")
        }
        let registered = try resolver.requiredInteger(resource.values["idleTime"])
        let order: [(ScreenSaverReadScope, ScreenSaverPreferenceScope)] = [
            (.currentUserCurrentHost, .currentUserCurrentHost),
            (.currentUserAnyHost, .currentUserAnyHost),
            (.anyUserAnyHost, .anyUserAnyHost),
        ]
        // The engine selects the first nonempty dictionary, not the first domain
        // containing idleTime. Missing keys then use its registered defaults.
        let selected = order.first { !(domains[$0.0] ?? [:]).isEmpty }
        let dictionary = selected.flatMap { domains[$0.0] } ?? [:]
        let effective: Int
        let source: ScreenSaverPreferenceScope
        if let value = dictionary["idleTime"] {
            effective = try resolver.requiredInteger(value)
            source = selected?.1 ?? .registeredDefaults
        } else {
            effective = registered
            source = .registeredDefaults
        }
        var protectedDomains: [String: Any] = [:]
        for scope in ScreenSaverReadScope.allCases {
            var values = domains[scope] ?? [:]
            if scope == .currentUserCurrentHost { values.removeValue(forKey: "idleTime") }
            protectedDomains[scope.rawValue] = values
        }
        let fingerprint = try resolver.fingerprint([
            "domains": protectedDomains,
            "engineDefaultResource": resource.resourceData,
            "engineRuntime": resource.runtimeIdentity,
        ])
        configuration = ScreenSaverConfiguration(
            storedValue: exactTimer, effectiveSeconds: effective,
            dictionarySource: selected?.1 ?? .registeredDefaults,
            valueSource: source, contextFingerprint: fingerprint
        )
        var others = resource.values.merging(dictionary) { _, explicit in explicit }
        others.removeValue(forKey: "idleTime")
        otherEffectiveValues = others
        self.domains = domains
        self.resource = resource
    }

    func replacingCurrentHostTimer(_ value: ScreenSaverStoredValue) throws -> ScreenSaverPreferenceImage {
        var changed = domains
        switch value {
        case .absent: changed[.currentUserCurrentHost]?.removeValue(forKey: "idleTime")
        case .integer(let seconds): changed[.currentUserCurrentHost]?["idleTime"] = NSNumber(value: seconds)
        }
        return try ScreenSaverPreferenceImage(domains: changed, exactTimer: value, resource: resource)
    }

    func preservesOtherEffectiveValues(whenWriting value: ScreenSaverStoredValue) throws -> Bool {
        let next = try replacingCurrentHostTimer(value)
        let resolver = ScreenSaverPreferenceResolver()
        return try resolver.fingerprint(otherEffectiveValues) == resolver.fingerprint(next.otherEffectiveValues)
    }
}

struct ScreenSaverPreferenceResolver {
    func validate(_ value: ScreenSaverStoredValue) throws {
        if case .integer(let seconds) = value, !(0...Int(Int32.max)).contains(seconds) {
            throw ScreenSaverError.rejected("The timer preference must be an integer from zero through Int32.max.")
        }
    }

    func storedValue(_ value: Any?) throws -> ScreenSaverStoredValue {
        guard let value else { return .absent }
        return .integer(try requiredInteger(value))
    }

    func requiredInteger(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              (0...Int64(Int32.max)).contains(number.int64Value) else {
            throw ScreenSaverError.unavailable("The timer or installed engine default is not a supported integer; no value or missing baseline is guessed.")
        }
        return Int(number.int64Value)
    }

    func fingerprint(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: canonical(value), options: [.sortedKeys])
        guard data.count <= 1_048_576 else {
            throw ScreenSaverError.unavailable("The scoped screen-saver preference context exceeds the read limit.")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func canonical(_ value: Any) throws -> Any {
        if let number = value as? NSNumber {
            let kind = CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : (CFNumberIsFloatType(number) ? "real" : "integer")
            return ["type": kind, "value": number.stringValue]
        }
        if let text = value as? String { return ["type": "string", "value": text] }
        if let data = value as? Data { return ["type": "data", "value": data.base64EncodedString()] }
        if let date = value as? Date { return ["type": "date", "value": date.timeIntervalSinceReferenceDate] }
        if let values = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in values { result[key] = try canonical(value) }
            return ["type": "dictionary", "value": result]
        }
        if let values = value as? [Any] {
            return ["type": "array", "value": try values.map { try canonical($0) }]
        }
        throw ScreenSaverError.unavailable("The scoped screen-saver preference context contains an unsupported value type.")
    }
}
