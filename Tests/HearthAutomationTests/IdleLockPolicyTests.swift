import Foundation
import HearthCore
import HearthPolicyBridge
import OpenDirectory
import XCTest
@testable import HearthAutomation

final class IdleLockPolicyTests: XCTestCase {
    func testProfilesQueriesAreFixedReadOnlyStatusCommands() {
        XCTAssertEqual(ProfileStatusQuery.configuration.arguments, ["status", "-type", "configuration"])
        XCTAssertEqual(ProfileStatusQuery.enrollment.arguments, ["status", "-type", "enrollment"])
    }

    func testSystemWideNoProfilesIsReadyButUserScopedAbsenceIsNot() throws {
        let parser = ProfileStatusParser()
        XCTAssertEqual(try parser.configuration(result("There are no configuration profiles installed on this system")).availability, .ready)
        for output in [
            "There are no configuration profiles installed for user 'example'",
            "There are no configuration profiles installed in the system domain",
            "There are no configuration profiles installed",
            "", "No", "profiles: this command requires root privileges",
        ] {
            XCTAssertThrowsError(try parser.configuration(result(output)))
        }
    }

    func testAnyInstalledProfileFailsClosedWithoutGuessingPayloadMappings() throws {
        let parser = ProfileStatusParser()
        for output in [
            "There is 1 configuration profile installed on this system",
            "There are 12 configuration profiles installed on this system",
        ] {
            XCTAssertEqual(try parser.configuration(result(output)).availability, .managed)
        }
    }

    func testEnrollmentRequiresBothExplicitNegativeResults() throws {
        let parser = ProfileStatusParser()
        XCTAssertEqual(try parser.enrollment(result("Enrolled via DEP: No\nMDM enrollment: No")).availability, .ready)
        for output in [
            "Enrolled via DEP: Yes\nMDM enrollment: No",
            "Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)\nMDM server: ignored",
        ] {
            XCTAssertEqual(try parser.enrollment(result(output)).availability, .managed)
        }
        for output in ["", "MDM enrollment: No", "Enrolled via DEP: No\nMDM enrollment: Unknown"] {
            XCTAssertThrowsError(try parser.enrollment(result(output)))
        }
    }

    func testExitFailureOversizedOrUnexpectedOutputDoesNotBecomeReady() {
        let parser = ProfileStatusParser()
        XCTAssertThrowsError(try parser.configuration(
            ProfileStatusResult(exitCode: 1, output: "There are no configuration profiles installed on this system")
        ))
        XCTAssertThrowsError(try parser.configuration(result(String(repeating: "a", count: 8193))))
        XCTAssertThrowsError(try parser.configuration(result("There are 0 configuration profiles installed on this system\nwarning")))
        XCTAssertThrowsError(try parser.enrollment(ProfileStatusResult(exitCode: 1, output: "Enrolled via DEP: No\nMDM enrollment: No")))
    }

    func testDirectoryAcceptsEmptyPoliciesButKeepsRelevantCategoriesBlocked() throws {
        let parser = DirectoryPolicyParser()
        XCTAssertTrue(try parser.hasNoIdleRestrictions([:]))
        XCTAssertTrue(try parser.hasNoIdleRestrictions([
            kODPolicyCategoryAuthentication as String: [],
            kODPolicyCategoryPasswordContent as String: [],
            kODPolicyCategoryPasswordChange as String: [],
        ]))
        XCTAssertFalse(try parser.hasNoIdleRestrictions([
            kODPolicyCategoryAuthentication as String: [["policyContent": "arbitrary predicate not evaluated"]],
        ]))
        XCTAssertThrowsError(try parser.hasNoIdleRestrictions(["futurePolicyCategory": []]))
        XCTAssertThrowsError(try parser.hasNoIdleRestrictions([kODPolicyCategoryAuthentication as String: "invalid"]))
    }

    func testNilWithoutErrorIsExplicitAbsenceNotAnIgnoredNSError() throws {
        let parser = DirectoryPolicyParser()
        let absent = try parser.read(HearthPolicyReadResult(policies: nil, error: nil), layer: "user")
        XCTAssertTrue(absent.policies.isEmpty)
        XCTAssertTrue(absent.provenance.contains("absent result, no error"))
        let empty = try parser.read(HearthPolicyReadResult(policies: [:], error: nil), layer: "node")
        XCTAssertTrue(empty.provenance.contains("dictionary read"))
        let failure = NSError(domain: "SyntheticDirectoryError", code: 257,
                              userInfo: [NSLocalizedDescriptionKey: "Do not expose predicate contents."])
        let results: [[AnyHashable: Any]?] = [nil, [:]]
        for policies in results {
            XCTAssertThrowsError(try parser.read(HearthPolicyReadResult(policies: policies, error: failure), layer: "user")) { error in
                XCTAssertTrue(error.localizedDescription.contains("SyntheticDirectoryError"))
                XCTAssertTrue(error.localizedDescription.contains("257"))
                XCTAssertFalse(error.localizedDescription.contains("predicate contents"))
            }
        }
    }

    func testObservedPasswordOnlyGrammarIsUnrelatedButStillReportedPresent() throws {
        let parser = DirectoryPolicyParser()
        let policies = [kODPolicyCategoryPasswordContent as String: [passwordRule()]]
        let layer = try parser.read(HearthPolicyReadResult(policies: policies, error: nil), layer: "node")
        XCTAssertEqual(layer.policies.count, 1)
        XCTAssertTrue(layer.provenance.contains("1 categories"))
        XCTAssertTrue(try parser.hasNoIdleRestrictions(layer.policies))
        XCTAssertFalse(try parser.hasNoIdleRestrictions([
            kODPolicyCategoryPasswordContent as String: [passwordRule()],
            kODPolicyCategoryAuthentication as String: [["policyContent": "synthetic relevant policy"]],
        ]))
        XCTAssertFalse(try parser.hasNoIdleRestrictions([
            kODPolicyCategoryPasswordChange as String: [passwordRule()],
        ]))
    }

    func testUnknownAttributesCompoundExpressionsAndFunctionsStayBlocked() throws {
        let parser = DirectoryPolicyParser()
        for content in [
            "policyAttributeCurrentTime matches '.*'",
            "policyAttributePassword matches '.*' AND policyAttributeCurrentTime > 0",
            "policyAttributePassword matches '.*' OR TRUEPREDICATE",
            "FUNCTION(policyAttributePassword, 'length') > 0",
            "policyAttributePassword.length > 0",
            "policyAttributePassword MATCHES[c] '.*'",
            "policyAttributePassword matches $pattern",
            "TRUEPREDICATE",
            "policyAttributePassword matches 'unterminated",
        ] {
            XCTAssertFalse(try parser.hasNoIdleRestrictions([
                kODPolicyCategoryPasswordContent as String: [passwordRule(content: content)],
            ]))
        }
    }

    func testLocalizedDescriptionsDoNotMisclassifyPasswordOnlyPolicy() throws {
        let parser = DirectoryPolicyParser()
        var policy = passwordRule()
        let descriptions = Dictionary(uniqueKeysWithValues: (0..<256).map { ("locale-\($0)", "Synthetic description") })
        policy[kODPolicyKeyContentDescription as String] = descriptions
        XCTAssertTrue(try parser.hasNoIdleRestrictions([kODPolicyCategoryPasswordContent as String: [policy]]))
        policy[kODPolicyKeyContentDescription as String] = ["en": String(repeating: "x", count: 65_537)]
        XCTAssertThrowsError(try parser.hasNoIdleRestrictions([kODPolicyCategoryPasswordContent as String: [policy]]))
        policy[kODPolicyKeyContentDescription as String] = ["en": ["unexpected": "structure"]]
        XCTAssertThrowsError(try parser.hasNoIdleRestrictions([kODPolicyCategoryPasswordContent as String: [policy]]))
        policy[kODPolicyKeyContentDescription as String] = "wrong shape"
        XCTAssertThrowsError(try parser.hasNoIdleRestrictions([kODPolicyCategoryPasswordContent as String: [policy]]))
    }

    func testMalformedOrUnexpectedPasswordPolicyKeysStayBlocked() throws {
        let parser = DirectoryPolicyParser()
        var variants: [[String: Any]] = []
        var parameters = passwordRule()
        parameters[kODPolicyKeyParameters as String] = ["synthetic": 1]
        variants.append(parameters)
        var extra = passwordRule()
        extra["unknownConstraint"] = true
        variants.append(extra)
        var identifier = passwordRule()
        identifier[kODPolicyKeyIdentifier as String] = ""
        variants.append(identifier)
        var wrongType = passwordRule()
        wrongType[kODPolicyKeyContent as String] = 0
        variants.append(wrongType)
        for policy in variants {
            XCTAssertFalse(try parser.hasNoIdleRestrictions([kODPolicyCategoryPasswordContent as String: [policy]]))
        }
    }

    private func passwordRule(content: String = "policyAttributePassword matches '.{6,}'") -> [String: Any] {
        [
            kODPolicyKeyIdentifier as String: "synthetic.password.content",
            kODPolicyKeyContent as String: content,
            kODPolicyKeyContentDescription as String: ["en": "Synthetic password rule"],
        ]
    }

    func testMCXFlagsOrSettingsBlockEvenWhenOtherPolicyStorageIsEmpty() throws {
        let parser = DirectoryPolicyParser()
        XCTAssertFalse(try parser.hasManagedAttributes([:]))
        XCTAssertFalse(try parser.hasManagedAttributes([kODAttributeTypeMCXFlags as String: []]))
        XCTAssertTrue(try parser.hasManagedAttributes([kODAttributeTypeMCXFlags as String: ["1"]]))
        XCTAssertTrue(try parser.hasManagedAttributes([kODAttributeTypeMCXSettings as String: [Data()]]))
        XCTAssertThrowsError(try parser.hasManagedAttributes([kODAttributeTypeMCXSettings as String: "unknown"]))
    }

    func testAutoLogoutAbsentOrZeroOffPositiveOnAndMalformedUnknown() throws {
        let parser = IdleLockPreferenceParser()
        XCTAssertFalse(try parser.automaticLogoutEnabled(nil))
        XCTAssertFalse(try parser.automaticLogoutEnabled(NSNumber(value: 0)))
        XCTAssertFalse(try parser.automaticLogoutEnabled(NSNumber(value: 0.0)))
        XCTAssertTrue(try parser.automaticLogoutEnabled(NSNumber(value: 300.5)))
        let invalidValues: [Any] = [
            "0", NSNumber(value: -1), NSNumber(value: true),
            NSNumber(value: Double.nan), NSNumber(value: Double.infinity), [:],
        ]
        for value in invalidValues {
            XCTAssertThrowsError(try parser.automaticLogoutEnabled(value))
        }
    }

    func testOrdinaryUnconfiguredLocalAccountHasConcreteReadyPath() throws {
        let profiles = FakeProfileStatusRunner()
        let directory = FakeDirectoryPolicy(.ready)
        let preferences = FakePreferencePolicy(.ready)
        let reader = SystemIdleLockPolicyReader(profiles: profiles, directory: directory, preferences: preferences)
        let assessment = try reader.assess()
        XCTAssertEqual(assessment.availability, .ready)
        XCTAssertTrue(assessment.message.contains("Fake directory policy"))
        XCTAssertTrue(assessment.message.contains("Fake preference policy"))
        XCTAssertEqual(profiles.queries, [.configuration, .enrollment])
        XCTAssertEqual(directory.checks, 1)
        XCTAssertEqual(preferences.checks, 1)
        _ = try reader.assess()
        XCTAssertEqual(profiles.queries, [.configuration, .enrollment, .configuration, .enrollment])
        XCTAssertEqual(directory.checks, 2)
    }

    func testProfileOrEnrollmentManagementStopsBeforePreferences() throws {
        for managedQuery in [ProfileStatusQuery.configuration, .enrollment] {
            let profiles = FakeProfileStatusRunner(managed: managedQuery)
            let directory = FakeDirectoryPolicy(.ready)
            let preferences = FakePreferencePolicy(.ready)
            let reader = SystemIdleLockPolicyReader(profiles: profiles, directory: directory, preferences: preferences)
            XCTAssertEqual(try reader.assess().availability, .managed)
            XCTAssertEqual(directory.checks, 0)
            XCTAssertEqual(preferences.checks, 0)
        }
    }

    func testDirectoryOrPreferencesUnknownStopsReadiness() throws {
        let directory = FakeDirectoryPolicy(.managed)
        let preferences = FakePreferencePolicy(.ready)
        let reader = SystemIdleLockPolicyReader(profiles: FakeProfileStatusRunner(), directory: directory, preferences: preferences)
        XCTAssertEqual(try reader.assess().availability, .managed)
        XCTAssertEqual(preferences.checks, 0)
        let autoLogout = SystemIdleLockPolicyReader(
            profiles: FakeProfileStatusRunner(), directory: FakeDirectoryPolicy(.ready), preferences: FakePreferencePolicy(.unavailable)
        )
        XCTAssertEqual(try autoLogout.assess().availability, .unavailable)
    }

    private func result(_ output: String) -> ProfileStatusResult { ProfileStatusResult(exitCode: 0, output: output) }
}

private final class FakeProfileStatusRunner: ProfileStatusRunning, @unchecked Sendable {
    private(set) var queries: [ProfileStatusQuery] = []
    private let managed: ProfileStatusQuery?

    init(managed: ProfileStatusQuery? = nil) { self.managed = managed }

    func run(_ query: ProfileStatusQuery) throws -> ProfileStatusResult {
        queries.append(query)
        let output: String
        switch query {
        case .configuration:
            output = managed == query
                ? "There is 1 configuration profile installed on this system"
                : "There are no configuration profiles installed on this system"
        case .enrollment:
            output = managed == query
                ? "Enrolled via DEP: No\nMDM enrollment: Yes (User Approved)"
                : "Enrolled via DEP: No\nMDM enrollment: No"
        }
        return ProfileStatusResult(exitCode: 0, output: output)
    }
}

private final class FakeDirectoryPolicy: DirectoryPolicyReading, @unchecked Sendable {
    private(set) var checks = 0
    private let availability: ScreenSaverAvailability
    init(_ availability: ScreenSaverAvailability) { self.availability = availability }
    func assess() throws -> IdleLockPolicyAssessment {
        checks += 1
        return IdleLockPolicyAssessment(availability: availability, message: "Fake directory policy")
    }
}

private final class FakePreferencePolicy: IdleLockPreferencesReading, @unchecked Sendable {
    private(set) var checks = 0
    private let availability: ScreenSaverAvailability
    init(_ availability: ScreenSaverAvailability) { self.availability = availability }
    func assess() throws -> IdleLockPolicyAssessment {
        checks += 1
        return IdleLockPolicyAssessment(availability: availability, message: "Fake preference policy")
    }
}
