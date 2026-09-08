import Darwin
import Foundation
import Security
import XCTest
@testable import HearthHelper
@testable import HearthIPC

final class BoundaryTests: XCTestCase {
    private let codec = HelperWireCodec()

    func testWireRoundTrips() throws {
        let changes = [
            IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 1),
            IdleSleepChange(profile: "adapter", minutes: Int(Int32.max), expectedMinutes: 0),
        ]
        XCTAssertEqual(try codec.decodeApplyRequest(codec.applyRequest(changes)), changes)
        try codec.decodeAvailabilityRequest(codec.availabilityRequest())
        let status = HelperConnectionStatus(state: .ready, message: "Ready")
        XCTAssertEqual(try codec.decodeStatusReply(codec.statusReply(status)), status)
        let outcomes = changes.map { HelperCommandOutcome(profile: $0.profile, exitCode: 0, message: "ok") }
        XCTAssertEqual(try codec.decodeApplyReply(codec.applyReply(outcomes), changes: changes), outcomes)
    }

    func testWireRejectsMaliciousEnvelopes() {
        let bad = [
            #"{"version":2,"changes":[{"profile":"battery","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":true,"changes":[{"profile":"battery","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1.0,"changes":[{"profile":"battery","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1,"version":1,"changes":[{"profile":"battery","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1,"uid":501,"changes":[{"profile":"battery","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1,"path":"/tmp/code","changes":[]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":0,"expectedMinutes":1,"shell":"id"}]}"#,
            #"{"version":1,"changes":[]}"#,
            #"{"version":1,"changes":[{"profile":"ups","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"-a","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery;id","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":-1,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":2147483648,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":0,"expectedMinutes":-1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":"0","expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":1e0,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":00,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":0,"minutes":1,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":0}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","minutes":0,"expectedMinutes":1},{"profile":"battery","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{},{},{}]}"#,
            #"{"version":1,"changes":[[[[[[[]]]]]]]}"#,
            #"{"version":1,"changes":null}"#,
            #"{"version":1,"changes":[],"changes":[]}garbage"#,
        ]
        for source in bad {
            XCTAssertThrowsError(try codec.decodeApplyRequest(Data(source.utf8)), source)
        }
        XCTAssertThrowsError(try codec.decodeApplyRequest(Data(repeating: 32, count: 4097)))
        XCTAssertThrowsError(try codec.decodeApplyRequest(Data([0xff, 0xfe])))
    }

    func testWireRejectsExtraReplyFieldsAndWrongProfile() throws {
        let changes = [IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 1)]
        let wrong = codec.applyReply([HelperCommandOutcome(profile: "adapter", exitCode: 0)])
        XCTAssertThrowsError(try codec.decodeApplyReply(wrong, changes: changes))
        XCTAssertThrowsError(try codec.decodeStatusReply(Data(#"{"version":1,"state":"ready","message":"","uid":501}"#.utf8)))
        XCTAssertThrowsError(try codec.decodeApplyReply(codec.applyReply([]), changes: changes))
        let skipped = codec.applyReply([HelperCommandOutcome(profile: "battery", exitCode: 75, didExecute: false)])
        XCTAssertEqual(try codec.decodeApplyReply(skipped, changes: changes).first?.didExecute, false)
        let contradictory = codec.applyReply([HelperCommandOutcome(profile: "battery", exitCode: 0, didExecute: false)])
        XCTAssertThrowsError(try codec.decodeApplyReply(contradictory, changes: changes))
        let failed = codec.applyReply([], failure: HelperConnectionStatus(state: .unavailable, message: "Busy"))
        XCTAssertThrowsError(try codec.decodeApplyReply(failed, changes: changes)) { error in
            guard case HelperClientError.rejected("Busy") = error else {
                return XCTFail("Expected a definite rejection, not transport uncertainty: \(error)")
            }
        }
        let large = codec.applyReply([HelperCommandOutcome(profile: "battery", exitCode: 1, message: String(repeating: "💥", count: 6000))])
        XCTAssertLessThanOrEqual(large.count, 4096)
        XCTAssertEqual(try codec.decodeApplyReply(large, changes: changes).first?.exitCode, 1)
        let escaped = codec.applyReply([
            HelperCommandOutcome(profile: "battery", exitCode: 1, message: String(repeating: "\u{01}", count: 6000)),
        ])
        XCTAssertLessThanOrEqual(escaped.count, 4096)
        XCTAssertEqual(try codec.decodeApplyReply(escaped, changes: changes).first?.exitCode, 1)
    }

    func testClientPreflightRejectionIsNotTransportUncertainty() {
        XCTAssertThrowsError(try HelperClient().apply(
            [IdleSleepChange(profile: "ups", minutes: 0, expectedMinutes: 1)], lease: .nullDevice
        )) { error in
            guard case HelperClientError.rejected = error else {
                return XCTFail("Expected a definite preflight rejection: \(error)")
            }
        }
    }

    func testDefiniteRPCRejectionBecomesCompletedSkippedOutcomes() throws {
        let changes = [
            IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 1),
            IdleSleepChange(profile: "adapter", minutes: 0, expectedMinutes: 5),
        ]
        let reply = codec.applyReply([], failure: HelperConnectionStatus(state: .unavailable, message: "Busy"))
        let outcomes = try HelperClient().decodeApplyResponse(reply, changes: changes)
        XCTAssertEqual(outcomes.map(\.profile), ["battery", "adapter"])
        XCTAssertEqual(outcomes.map(\.didExecute), [false, false])
        XCTAssertEqual(outcomes.map(\.exitCode), [1, 1])
        XCTAssertThrowsError(try HelperClient().decodeApplyResponse(Data("invalid reply".utf8), changes: changes)) { error in
            guard case HelperClientError.completionUnknown = error else {
                return XCTFail("Malformed replies must preserve transport uncertainty.")
            }
        }
    }

    func testPolicyOnlyAcceptsExactPinnedIdentifiersAndHashes() throws {
        let policy = try HelperAuthorizationPolicy(data: policyData())
        XCTAssertEqual(policy.appCodeHash, String(repeating: "a", count: 40))
        XCTAssertTrue(policy.clientsRequirement.text.contains(#"identifier "dev.girishkvs.hearth.cli""#))
        XCTAssertTrue(policy.helperRequirement.text.contains(#"identifier "dev.girishkvs.hearth.helper""#))
        XCTAssertFalse(policy.clientsRequirement.text.contains("anchor"))
        for hash in [
            "", String(repeating: "A", count: 40), String(repeating: "a", count: 39),
            String(repeating: "a", count: 41), String(repeating: "g", count: 40),
            #"a" or true or cdhash H"a"#,
        ] {
            XCTAssertThrowsError(try HelperAuthorizationPolicy(data: policyData(overrides: ["AppCodeHash": hash])))
        }
        for version in [0, 2, true, 1.0, "1", [1]] as [Any] {
            XCTAssertThrowsError(try HelperAuthorizationPolicy(data: policyData(overrides: ["FormatVersion": version])))
        }
        XCTAssertThrowsError(try HelperAuthorizationPolicy(data: policyData(overrides: ["UID": 501])))
        XCTAssertThrowsError(try HelperAuthorizationPolicy(data: policyData(overrides: ["BuildIdentifier": ""])))
        XCTAssertThrowsError(try ValidatedCodeRequirement("identifier ("))
    }

    func testProtectedMetadataRejectsWritableLinkedAndACLFiles() throws {
        try ProtectedFileMetadata(owner: 0, group: 0, mode: S_IFREG | 0o644, links: 1, hasACL: false)
            .validate(directory: false, exactMode: 0o644)
        try ProtectedFileMetadata(owner: 0, group: 80, mode: S_IFDIR | 0o755, links: 3, hasACL: false)
            .validate(directory: true)
        for metadata in [
            ProtectedFileMetadata(owner: 501, group: 0, mode: S_IFREG | 0o644, links: 1, hasACL: false),
            ProtectedFileMetadata(owner: 0, group: 0, mode: S_IFREG | 0o664, links: 1, hasACL: false),
            ProtectedFileMetadata(owner: 0, group: 0, mode: S_IFREG | 0o646, links: 1, hasACL: false),
            ProtectedFileMetadata(owner: 0, group: 0, mode: S_IFREG | 0o4644, links: 1, hasACL: false),
            ProtectedFileMetadata(owner: 0, group: 0, mode: S_IFLNK | 0o644, links: 1, hasACL: false),
            ProtectedFileMetadata(owner: 0, group: 0, mode: S_IFREG | 0o644, links: 2, hasACL: false),
            ProtectedFileMetadata(owner: 0, group: 0, mode: S_IFREG | 0o644, links: 1, hasACL: true),
            ProtectedFileMetadata(owner: 0, group: 80, mode: S_IFREG | 0o644, links: 1, hasACL: false),
        ] {
            XCTAssertThrowsError(try metadata.validate(directory: false, exactMode: 0o644))
        }
        // /Applications is not traversed to authenticate peers: native message-time
        // signature checks admit the pinned binary wherever an allowed user executes it.
        XCTAssertThrowsError(
            try ProtectedFileMetadata(owner: 0, group: 80, mode: S_IFDIR | 0o775, links: 3, hasACL: false)
                .validate(directory: true)
        )
    }

    func testProtectedDescriptorTraversalAcceptsSystemPMSetWithoutExecutingIt() throws {
        let descriptor = try ProtectedFiles().open("/usr/bin/pmset", mode: 0o755)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        close(descriptor)
        // /var is a root-owned symlink on macOS; it must not become a traversal bypass.
        XCTAssertThrowsError(try ProtectedFiles().open("/var/run/does-not-matter", mode: 0o644))
    }

    private func policyData(overrides: [String: Any] = [:]) throws -> Data {
        var fields: [String: Any] = [
            "FormatVersion": 1, "ProtocolVersion": 1,
            "AppCodeHash": String(repeating: "a", count: 40),
            "CLICodeHash": String(repeating: "b", count: 40),
            "HelperCodeHash": String(repeating: "c", count: 40),
            "BuildIdentifier": "test-build",
        ]
        fields.merge(overrides) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
    }
}
