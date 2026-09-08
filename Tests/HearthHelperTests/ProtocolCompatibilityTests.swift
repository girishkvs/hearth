import Foundation
import XCTest
@testable import HearthIPC

final class ProtocolCompatibilityTests: XCTestCase {
    private let codec = HelperWireCodec()

    func testNewRequestsNeverMatchLegacySystemWriteSchema() throws {
        XCTAssertEqual(codec.availabilityRequest(), Data(#"{"version":2}"#.utf8))
        for setting in HelperPowerSetting.allCases {
            let request = try codec.applyRequest([
                IdleSleepChange(profile: .battery, minutes: 0, expectedMinutes: 2, setting: setting),
            ])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let changes = try XCTUnwrap(object["changes"] as? [[String: Any]])
            XCTAssertEqual(object["version"] as? Int, 2)
            XCTAssertEqual(changes[0]["setting"] as? String, setting.rawValue)
            XCTAssertEqual(Set(changes[0].keys), ["profile", "setting", "minutes", "expectedMinutes"])
            // The published v1 helper requires BOTH version 1 and this exact legacy field set.
            XCTAssertNotEqual(object["version"] as? Int, 1)
            XCTAssertNotEqual(Set(changes[0].keys), ["profile", "minutes", "expectedMinutes"])
        }
    }

    func testNewHelperCodecNeverDecodesLegacySystemOrDisplayWrite() {
        for source in [
            #"{"version":1,"changes":[{"profile":"battery","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","setting":"system","minutes":0,"expectedMinutes":1}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","setting":"display","minutes":0,"expectedMinutes":2}]}"#,
            #"{"version":1,"changes":[{"profile":"battery","key":"displaysleep","minutes":0,"expectedMinutes":2}]}"#,
        ] {
            XCTAssertThrowsError(try codec.decodeApplyRequest(Data(source.utf8))) { error in
                guard case HelperClientError.incompatible(let message) = error else {
                    return XCTFail("Legacy writes must require an update: \(error)")
                }
                XCTAssertTrue(message.contains("Hearth update required"))
            }
        }
    }

    func testV1AvailabilityIsIncompatibleEvenWhenOldHelperReportsReady() {
        for state in ["ready", "incompatible", "unavailable"] {
            let reply = Data(#"{"version":1,"state":"\#(state)","message":"Old helper response"}"#.utf8)
            XCTAssertThrowsError(try codec.decodeStatusReply(reply)) { error in
                guard case HelperClientError.incompatible(let message) = error else {
                    return XCTFail("V1 availability must not enable writes: \(error)")
                }
                XCTAssertEqual(message, HelperWireCodec.updateRequiredMessage)
            }
        }
    }

    func testAvailabilityRequiresExactVersionFieldAndType() {
        for source in [
            #"{"version":1}"#, #"{"version":3}"#, #"{"version":2.0}"#, #"{"version":true}"#,
            #"{"version":"2"}"#, #"{"version":2,"version":2}"#, #"{"version":2,"setting":"display"}"#,
        ] {
            XCTAssertThrowsError(try codec.decodeAvailabilityRequest(Data(source.utf8)))
        }
    }

    func testOnlyBoundedUnambiguousV1EnvelopeGetsLegacyRefusal() throws {
        for applying in [false, true] {
            let data = try XCTUnwrap(codec.legacyIncompatibilityReply(
                to: Data(#"{"version":1}"#.utf8), applying: applying
            ))
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(fields["version"] as? Int, 1)
            XCTAssertEqual(fields["state"] as? String, "incompatible")
            XCTAssertEqual(fields["message"] as? String, HelperWireCodec.updateRequiredMessage)
            XCTAssertLessThanOrEqual(data.count, 4096)
            if applying {
                XCTAssertEqual(Set(fields.keys), ["version", "state", "message", "outcomes"])
                XCTAssertEqual((fields["outcomes"] as? [Any])?.count, 0)
            } else {
                XCTAssertEqual(Set(fields.keys), ["version", "state", "message"])
            }
        }
        for source in [
            #"{"version":2}"#, #"{"version":3}"#, #"{"version":"1"}"#, #"{"version":true}"#,
            #"{"version":1.0}"#, #"{"version":1,"version":2}"#, #"{"version":1}trailing"#,
            #"{"version":1,"changes":[{},{},{}]}"#,
        ] {
            XCTAssertNil(codec.legacyIncompatibilityReply(to: Data(source.utf8), applying: true))
        }
        XCTAssertNil(codec.legacyIncompatibilityReply(to: Data(repeating: 32, count: 4097), applying: true))
    }

    func testV1OrFuturePostWriteRepliesAlwaysKeepCompletionUnknown() {
        // These v1 fixtures have the published old helper's exact reply shape. Even its
        // explicit refusal is not a v2 completion acknowledgment and cannot clear a journal.
        let replies = [
            #"{"version":1,"state":"unavailable","message":"Unsupported helper protocol or fields. Run explicit setup/repair.","outcomes":[]}"#,
            #"{"version":1,"state":"ready","message":"","outcomes":[{"profile":"battery","exitCode":0,"message":"","didExecute":true}]}"#,
            #"{"version":1,"state":"incompatible","message":"Hearth update required.","outcomes":[]}"#,
            #"{"version":3,"state":"incompatible","message":"Hearth update required.","outcomes":[]}"#,
        ]
        for setting in HelperPowerSetting.allCases {
            let changes = [IdleSleepChange(profile: .battery, minutes: 0, expectedMinutes: 2, setting: setting)]
            for source in replies {
                assertCompletionUnknown(Data(source.utf8), changes: changes)
            }
        }
    }

    func testMalformedV2PostWriteRepliesCannotBeRejectionOrSuccess() {
        let changes = [IdleSleepChange(profile: .battery, minutes: 0, expectedMinutes: 2, setting: .display)]
        let sources = [
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"battery","exitCode":0,"message":"","didExecute":true}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"battery","setting":"system","exitCode":0,"message":"","didExecute":true}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"battery","setting":"displaysleep","exitCode":0,"message":"","didExecute":true}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"battery","setting":true,"exitCode":0,"message":"","didExecute":true}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"ups","setting":"display","exitCode":0,"message":"","didExecute":true}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"adapter","setting":"display","exitCode":0,"message":"","didExecute":true}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"battery","setting":"display","exitCode":0,"message":"","didExecute":true,"key":"displaysleep"}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"battery","setting":"display","exitCode":0,"message":"","didExecute":1}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"battery","setting":"display","exitCode":0.0,"message":"","didExecute":true}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"battery","setting":"display","exitCode":2147483648,"message":"","didExecute":true}]}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[{"profile":"battery","setting":"display","exitCode":0,"message":"","didExecute":false}]}"#,
            #"{"version":2,"state":"unavailable","message":"Busy","outcomes":[{"profile":"battery","setting":"display","exitCode":1,"message":"","didExecute":false}]}"#,
            #"{"version":2,"state":"incompatible","message":"Update","outcomes":[],"unexpected":true}"#,
            #"{"version":2,"state":"ready","message":"","outcomes":[]}"#,
            #"{"version":2,"state":"unknown","message":"","outcomes":[]}"#,
            #"{"version":2,"state":"incompatible","message":"","outcomes":null}"#,
            #"{"version":2,"version":1,"state":"incompatible","message":"","outcomes":[]}"#,
        ]
        for source in sources {
            assertCompletionUnknown(Data(source.utf8), changes: changes)
        }
        assertCompletionUnknown(Data(repeating: 32, count: 4097), changes: changes)
    }

    func testValidV2RejectionAndPartialReplyKeepDisplayIdentity() throws {
        let changes = [
            IdleSleepChange(profile: .battery, minutes: 0, expectedMinutes: 2, setting: .display),
            IdleSleepChange(profile: .adapter, minutes: 0, expectedMinutes: 10, setting: .display),
        ]
        let refusal = codec.applyReply([], failure: HelperConnectionStatus(
            state: .incompatible, message: HelperWireCodec.updateRequiredMessage
        ))
        let rejected = try HelperClient().decodeApplyResponse(refusal, changes: changes)
        XCTAssertEqual(rejected.map(\.profile), [.battery, .adapter])
        XCTAssertEqual(rejected.map(\.setting), [.display, .display])
        XCTAssertEqual(rejected.map(\.didExecute), [false, false])
        let partial = [
            HelperCommandOutcome(profile: .battery, exitCode: 0, setting: .display),
            HelperCommandOutcome(profile: .adapter, exitCode: 75, message: "External change", didExecute: false, setting: .display),
        ]
        XCTAssertEqual(try HelperClient().decodeApplyResponse(codec.applyReply(partial), changes: changes), partial)
    }

    private func assertCompletionUnknown(
        _ reply: Data, changes: [IdleSleepChange], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try HelperClient().decodeApplyResponse(reply, changes: changes), file: file, line: line) { error in
            guard case HelperClientError.completionUnknown = error else {
                return XCTFail("Invalid post-write reply must retain the pending journal: \(error)", file: file, line: line)
            }
        }
    }
}
