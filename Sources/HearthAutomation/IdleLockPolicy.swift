import CoreFoundation
import Foundation
import HearthCore
import HearthPolicyBridge
import OpenDirectory

// Scope evidence:
// - profiles(1), status: client profile/enrollment status. list/show without root
//   are user-scoped and cannot establish that device policies are absent.
// - ODRecord.h accountPolicies excludes node policies; ODNode.h supplies those.
//   Modern OD policy categories do not expose an effective screen-lock timeout.
// - Apple's passcode payload translates maxInactivity into screen-saver settings:
//   https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.mobiledevice.passwordpolicy.yaml
//   There is no documented complete reverse mapping via CFPreferences.
// - User screen saver: com.apple.screensaver.user.yaml in that same directory.
// - Independent automatic logout: GlobalPreferences.yaml in that directory.
// Any installed profile/enrollment or relevant/unknown directory policy fails
// closed. Strictly recognized password-content-only rules remain untouched.

struct IdleLockPolicyAssessment: Equatable, Sendable {
    let availability: ScreenSaverAvailability
    let message: String
}

protocol IdleLockPolicyReading: Sendable {
    func assess() throws -> IdleLockPolicyAssessment
}

struct SystemIdleLockPolicyReader: IdleLockPolicyReading {
    private let profiles: any ProfileStatusRunning
    private let directory: any DirectoryPolicyReading
    private let preferences: any IdleLockPreferencesReading

    init(
        profiles: any ProfileStatusRunning = NativeProfileStatusRunner(),
        directory: any DirectoryPolicyReading = LocalDirectoryPolicyReader(),
        preferences: any IdleLockPreferencesReading = NativeIdleLockPreferencesReader()
    ) {
        self.profiles = profiles
        self.directory = directory
        self.preferences = preferences
    }

    func assess() throws -> IdleLockPolicyAssessment {
        let parser = ProfileStatusParser()
        let configuration = try parser.configuration(profiles.run(.configuration))
        guard configuration.availability == .ready else { return configuration }
        let enrollment = try parser.enrollment(profiles.run(.enrollment))
        guard enrollment.availability == .ready else { return enrollment }
        let directoryPolicy = try directory.assess()
        guard directoryPolicy.availability == .ready else { return directoryPolicy }
        let preferencePolicy = try preferences.assess()
        guard preferencePolicy.availability == .ready else { return preferencePolicy }
        return IdleLockPolicyAssessment(
            availability: .ready, message: "\(directoryPolicy.message) \(preferencePolicy.message)"
        )
    }
}

struct ProfileStatusParser {
    func configuration(_ result: ProfileStatusResult) throws -> IdleLockPolicyAssessment {
        let text = try output(result)
        // The user-scoped "no profiles installed for user" response is NOT enough.
        if text == "There are no configuration profiles installed on this system" {
            return IdleLockPolicyAssessment(availability: .ready, message: "No system configuration profiles.")
        }
        if text.range(
            of: #"^There (is 1 configuration profile|are [1-9][0-9]* configuration profiles) installed on this system$"#,
            options: .regularExpression
        ) != nil {
            return IdleLockPolicyAssessment(
                availability: .managed,
                message: "Configuration profiles are installed. Their effective idle-lock constraints cannot safely be excluded; Hearth will not change the screen saver."
            )
        }
        throw ScreenSaverError.unavailable("Cannot establish system-wide configuration-profile status.")
    }

    func enrollment(_ result: ProfileStatusResult) throws -> IdleLockPolicyAssessment {
        let lines = try output(result).split(separator: "\n").map(String.init)
        if lines.contains(where: { $0.hasPrefix("Enrolled via DEP: Yes") || $0.hasPrefix("MDM enrollment: Yes") }) {
            return IdleLockPolicyAssessment(
                availability: .managed,
                message: "This Mac is enrolled for management. Hearth will not override an effective idle-lock policy."
            )
        }
        guard lines == ["Enrolled via DEP: No", "MDM enrollment: No"] else {
            throw ScreenSaverError.unavailable("Cannot establish device enrollment status.")
        }
        return IdleLockPolicyAssessment(availability: .ready, message: "No device enrollment.")
    }

    private func output(_ result: ProfileStatusResult) throws -> String {
        guard result.exitCode == 0,
              result.output.utf8.count <= 8192 else {
            throw ScreenSaverError.unavailable("The read-only configuration-profile status query failed.")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol DirectoryPolicyReading: Sendable {
    func assess() throws -> IdleLockPolicyAssessment
}

struct LocalDirectoryPolicyReader: DirectoryPolicyReading {
    func assess() throws -> IdleLockPolicyAssessment {
        guard getuid() != 0, getuid() == geteuid() else {
            throw ScreenSaverError.unavailable("Idle-lock policy requires the current non-root user.")
        }
        do {
            let session = ODSession.default()
            let search = try ODNode(session: session, type: UInt32(kODNodeTypeAuthentication))
            let details = try search.nodeDetails(forKeys: [kODAttributeTypeSearchPath])
            guard let paths = details[kODAttributeTypeSearchPath] as? [String],
                  !paths.isEmpty,
                  paths.allSatisfy({ $0 == "/Local/Default" || $0 == "/BSD/local" }) else {
                return unknownDirectoryPolicy()
            }
            let node = try ODNode(session: session, type: UInt32(kODNodeTypeLocalNodes))
            let query = try ODQuery(
                node: node, forRecordTypes: kODRecordTypeUsers, attribute: kODAttributeTypeUniqueID,
                matchType: UInt32(kODMatchEqualTo), queryValues: String(getuid()),
                returnAttributes: [kODAttributeTypeUniqueID], maximumResults: 2
            )
            guard let records = try query.resultsAllowingPartial(false) as? [ODRecord],
                  records.count == 1 else {
                throw ScreenSaverError.unavailable("Cannot uniquely identify the current local account for policy checks.")
            }
            // Record queries explicitly exclude node policies. Both must be checked.
            let parser = DirectoryPolicyParser()
            let nodePolicies = try parser.read(HearthReadNodePolicies(node), layer: "node")
            let userPolicies = try parser.read(HearthReadRecordPolicies(records[0]), layer: "user")
            guard try parser.hasNoIdleRestrictions(nodePolicies.policies),
                  try parser.hasNoIdleRestrictions(userPolicies.policies) else {
                return unknownDirectoryPolicy()
            }
            // Older MCX policy may be attached to users, groups, or computers,
            // independently of modern profile/account-policy storage.
            let managedQuery = try ODQuery(
                node: node,
                forRecordTypes: [
                    kODRecordTypeUsers, kODRecordTypeGroups, kODRecordTypeComputers,
                    kODRecordTypeComputerGroups, kODRecordTypeComputerLists,
                ],
                attribute: kODAttributeTypeRecordName, matchType: UInt32(kODMatchAny), queryValues: nil,
                returnAttributes: [kODAttributeTypeMCXSettings, kODAttributeTypeMCXFlags], maximumResults: 0
            )
            guard let managedRecords = try managedQuery.resultsAllowingPartial(false) as? [ODRecord] else {
                throw ScreenSaverError.unavailable("Cannot check local directory managed settings.")
            }
            for record in managedRecords {
                let attributes = try record.recordDetails(forAttributes: [kODAttributeTypeMCXSettings, kODAttributeTypeMCXFlags])
                if try parser.hasManagedAttributes(attributes) { return unknownDirectoryPolicy() }
            }
            return IdleLockPolicyAssessment(
                availability: .ready,
                message: "No relevant idle restriction found in local user/node policies or MCX. \(userPolicies.provenance) \(nodePolicies.provenance) Validated password-content rules, if present, remain unchanged."
            )
        } catch {
            throw ScreenSaverError.unavailable("Cannot establish effective local directory policy. \(error.localizedDescription) No screen-saver write is allowed.")
        }
    }

    private func unknownDirectoryPolicy() -> IdleLockPolicyAssessment {
        IdleLockPolicyAssessment(
            availability: .managed,
            message: "Relevant or unrecognized directory policy, MCX settings, or a nonlocal policy scope prevents safe idle-timer changes."
        )
    }
}

struct DirectoryPolicyParser {
    struct Layer {
        let policies: [AnyHashable: Any]
        let provenance: String
    }

    func read(_ result: HearthPolicyReadResult, layer: String) throws -> Layer {
        if let error = result.error {
            let details = error as NSError
            throw ScreenSaverError.unavailable("OpenDirectory \(layer) read failed (\(details.domain), code \(details.code)).")
        }
        guard let policies = result.policies else {
            // OD's configured-policy result can be absent with no NSError. The
            // public CF implementation translates a successful CFNull result to
            // NULL. This does not include or waive inherited node/MCX policies.
            return Layer(policies: [:], provenance: "No explicit \(layer) policies returned (absent result, no error).")
        }
        return Layer(policies: policies, provenance: "\(layer.capitalized) policy dictionary read (\(policies.count) categories).")
    }

    func hasNoIdleRestrictions(_ policies: [AnyHashable: Any]) throws -> Bool {
        let categories = Set([
            kODPolicyCategoryAuthentication as String,
            kODPolicyCategoryPasswordChange as String,
            kODPolicyCategoryPasswordContent as String,
        ])
        for (key, value) in policies {
            guard let category = key as? String,
                  categories.contains(category),
                  let entries = value as? [Any] else {
                throw ScreenSaverError.unavailable("OpenDirectory returned an unknown policy format.")
            }
            if entries.isEmpty { continue }
            guard category == kODPolicyCategoryPasswordContent as String,
                  entries.count <= 64 else { return false }
            for entry in entries {
                guard let policy = entry as? [String: Any],
                      try isPasswordOnlyContentRule(policy) else { return false }
            }
        }
        return true
    }

    private func isPasswordOnlyContentRule(_ policy: [String: Any]) throws -> Bool {
        let keys = Set(policy.keys)
        let required = Set([kODPolicyKeyIdentifier as String, kODPolicyKeyContent as String])
        let allowed = required.union([kODPolicyKeyContentDescription as String])
        guard required.isSubset(of: keys), keys.isSubset(of: allowed),
              let identifier = policy[kODPolicyKeyIdentifier as String] as? String,
              !identifier.isEmpty, identifier.utf8.count <= 256,
              let content = policy[kODPolicyKeyContent as String] as? String,
              content.utf8.count <= 4096 else { return false }
        if let descriptions = policy[kODPolicyKeyContentDescription as String] {
            guard let descriptions = descriptions as? [String: String] else {
                throw ScreenSaverError.unavailable("OpenDirectory returned malformed policy description metadata.")
            }
            // Localized text is inert metadata, not a policy constraint.
            var remainingBytes = 65_536
            for (locale, description) in descriptions {
                let bytes = locale.utf8.count + description.utf8.count
                guard bytes <= remainingBytes else {
                    throw ScreenSaverError.unavailable("OpenDirectory policy description metadata exceeds the read limit.")
                }
                remainingBytes -= bytes
            }
        }
        // Recognize only the observed grammar: password MATCHES a quoted
        // literal. No predicate is compiled/evaluated; functions, variables,
        // parameters, other attributes and compound expressions are rejected.
        let grammar = #"^\s*policyAttributePassword\s+(?i:matches)\s+(?:'(?:[^'\\\r\n]|\\[^\r\n])*'|"(?:[^"\\\r\n]|\\[^\r\n])*")\s*$"#
        return content.range(of: grammar, options: .regularExpression) != nil
    }

    func hasManagedAttributes(_ attributes: [AnyHashable: Any]) throws -> Bool {
        for key in [kODAttributeTypeMCXSettings, kODAttributeTypeMCXFlags] {
            guard let value = attributes[key as String] else { continue }
            guard let entries = value as? [Any] else {
                throw ScreenSaverError.unavailable("OpenDirectory returned malformed managed attributes.")
            }
            if !entries.isEmpty { return true }
        }
        return false
    }
}

protocol IdleLockPreferencesReading: Sendable {
    func assess() throws -> IdleLockPolicyAssessment
}

struct NativeIdleLockPreferencesReader: IdleLockPreferencesReading {
    func assess() throws -> IdleLockPolicyAssessment {
        // These are positive, key-specific checks, not proof that translated MDM
        // constraints are absent. The profile and directory gates run separately.
        for key in ["idleTime", "askForPassword", "askForPasswordDelay"] {
            if CFPreferencesAppValueIsForced(key as CFString, "com.apple.screensaver" as CFString) {
                return IdleLockPolicyAssessment(
                    availability: .managed, message: "Screen-saver preferences are managed. Hearth will not change them."
                )
            }
        }
        let key = "com.apple.autologout.AutoLogOutDelay" as CFString
        // App lookups include global defaults; AnyApplication is not valid for
        // the CFPreferences "App" functions.
        if CFPreferencesAppValueIsForced(key, kCFPreferencesCurrentApplication) {
            return IdleLockPolicyAssessment(availability: .managed, message: "Automatic logout is managed and remains unchanged.")
        }
        // Check all documented CFPreferences user/host scopes rather than assuming
        // an absent per-user value excludes a machine-wide auto-logout setting.
        let parser = IdleLockPreferenceParser()
        for user in [kCFPreferencesCurrentUser, kCFPreferencesAnyUser] {
            for host in [kCFPreferencesCurrentHost, kCFPreferencesAnyHost] {
                let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, user, host)
                if try parser.automaticLogoutEnabled(value) {
                    return IdleLockPolicyAssessment(
                        availability: .unavailable,
                        message: "Automatic logout is enabled. Hearth leaves it unchanged and cannot safely provide idle-lock prevention."
                    )
                }
            }
        }
        return IdleLockPolicyAssessment(availability: .ready, message: "No supported idle-lock restriction was found.")
    }
}

struct IdleLockPreferenceParser {
    func automaticLogoutEnabled(_ value: Any?) throws -> Bool {
        guard let value else { return false }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0 else {
            throw ScreenSaverError.unavailable("Automatic logout has an unknown preference value.")
        }
        return number.doubleValue > 0
    }
}
