import Foundation
import HearthCore
import XCTest
@testable import HearthLockIPC

final class LockWireTests: XCTestCase {
    private let codec = LockWireCodec()

    func testOnlyExactVersionTwoStatusOnRestoreRequests() throws {
        for action in [LockWireAction.status, .on, .restore] {
            XCTAssertEqual(try codec.decodeRequest(codec.request(action)), action)
        }
        let malformed = [
            #"{}"#, #"{"version":0,"action":"on"}"#, #"{"version":1,"action":"on"}"#,
            #"{"version":3,"action":"on"}"#,
            #"{"version":true,"action":"on"}"#, #"{"version":2.0,"action":"on"}"#,
            #"{"version":2e0,"action":"on"}"#, #"{"version":02,"action":"on"}"#,
            #"{"version":2,"version":2,"action":"on"}"#,
            #"{"version":2,"action":"on","act\u0069on":"restore"}"#,
            #"{"version":2,"action":"authorize"}"#, #"{"version":2,"action":"off"}"#,
            #"{"version":2,"action":1}"#, #"{"version":2,"action":null}"#,
            #"{"version":2,"action":"on","uid":501}"#,
            #"{"version":2,"action":"on","path":"/Applications/Hearth.app"}"#,
            #"{"version":2,"action":"on","script":"anything"}"#,
            #"{"version":2,"action":"on","environment":{}}"#,
            #"{"version":2,"action":"on"}{}"#, #"{"version":2,"action":"on",}"#,
        ]
        for source in malformed {
            XCTAssertThrowsError(try codec.decodeRequest(Data(source.utf8)), source)
        }
        XCTAssertThrowsError(try codec.decodeRequest(Data(repeating: 32, count: 129)))
        XCTAssertThrowsError(try codec.decodeRequest(Data([0xff, 0xfe])))
    }

    func testStatusAndResultRoundTripWithEveryDependency() throws {
        let dependencies = [PowerSetting.system, .display].flatMap { setting in
            [PowerProfile.battery, .adapter].map {
                IdleLockDependency(setting: setting, profile: $0, acquired: true, actualMinutes: 0)
            }
        }
        let status = IdleLockStatus(
            phase: .active, message: "native", saverDelaySeconds: 0, originalSaverDelaySeconds: 600,
            dependencies: dependencies, canRestore: true, hasManagedChanges: true,
            journalFingerprint: String(repeating: "a", count: 64)
        )
        guard case .status(let observed) = try codec.decodeReply(codec.statusReply(status), action: .status) else {
            return XCTFail("Expected status")
        }
        XCTAssertEqual(observed, status)
        let result = IdleLockResult(succeeded: true, message: "done", status: status)
        for action in [LockWireAction.on, .restore] {
            guard case .result(let decoded) = try codec.decodeReply(codec.resultReply(result, action: action), action: action) else {
                return XCTFail("Expected result")
            }
            XCTAssertEqual(decoded.status, status)
            XCTAssertTrue(decoded.succeeded)
        }
    }

    func testPostwriteMalformedRepliesAlwaysCompletionUnknown() throws {
        let client = testClient()
        let result = IdleLockResult(succeeded: true, message: "done", status: IdleLockStatus(phase: .off, message: "off"))
        let good = codec.resultReply(result, action: .restore)
        let text = String(decoding: good, as: UTF8.self)
        let invalid = [
            Data(), Data(repeating: 32, count: LockWireCodec.maximumBytes + 1),
            Data(text.replacingOccurrences(of: "\"version\":2", with: "\"version\":1").utf8),
            Data(text.replacingOccurrences(of: "\"version\":2", with: "\"version\":true").utf8),
            Data(text.replacingOccurrences(of: "\"succeeded\":true", with: "\"succeeded\":1").utf8),
            Data(text.replacingOccurrences(of: "\"phase\":\"off\"", with: "\"phase\":\"invented\"").utf8),
            Data(text.replacingOccurrences(of: "\"canEnable\":false", with: "\"canEnable\":false,\"canEnable\":false").utf8),
            Data(text.replacingOccurrences(of: "\"actualMinutes\":null", with: "\"actualMinutes\":1.5").utf8) + Data("{}".utf8),
            codec.resultReply(result, action: .on),
            codec.statusReply(result.status),
            codec.failure(.restore, outcome: "unavailable", message: "Unavailable after send"),
        ]
        for data in invalid {
            XCTAssertThrowsError(try client.decodeActionReply(data, action: .restore)) { error in
                guard case IdleLockClientError.completionUnknown = error else {
                    return XCTFail("Postwrite malformed response became \(error)")
                }
            }
        }
        XCTAssertThrowsError(try client.decodeActionReply(
            codec.failure(.restore, outcome: "rejected", message: "No work queued"), action: .restore
        )) { error in
            guard case IdleLockClientError.rejected = error else { return XCTFail("Expected exact admission refusal") }
        }
    }

    func testInvalidControllerResultsFailClosedAfterWrite() throws {
        let dependency = IdleLockDependency(setting: .system, profile: .battery, acquired: true, actualMinutes: 0)
        for status in [
            IdleLockStatus(phase: .active, message: "duplicate", dependencies: [dependency, dependency]),
            IdleLockStatus(phase: .active, message: "overflow", saverDelaySeconds: Int(Int32.max) + 1),
            IdleLockStatus(phase: .active, message: "negative", saverDelaySeconds: -1),
            IdleLockStatus(phase: .active, message: "invalid original", originalSaverDelaySeconds: 0),
            IdleLockStatus(phase: .active, message: "invalid journal", journalFingerprint: "short"),
            IdleLockStatus(phase: .active, message: "invalid journal", journalFingerprint: String(repeating: "G", count: 64)),
        ] {
            let data = codec.resultReply(IdleLockResult(succeeded: true, message: "done", status: status), action: .on)
            XCTAssertLessThanOrEqual(data.count, LockWireCodec.maximumBytes)
            XCTAssertThrowsError(try codec.decodeReply(data, action: .on)) { error in
                guard case IdleLockClientError.completionUnknown = error else { return XCTFail("Expected unknown") }
            }
        }
    }

    func testJournalFingerprintCannotBeDroppedOrLooselyTyped() throws {
        let status = IdleLockStatus(phase: .off, message: "configured state unavailable")
        let encoded = String(decoding: codec.statusReply(status), as: UTF8.self)
        for value in ["false", "0", "{}", "[]", #""uppercaseAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA""#] {
            let changed = encoded.replacingOccurrences(of: "\"journalFingerprint\":null", with: "\"journalFingerprint\":\(value)")
            XCTAssertThrowsError(try codec.decodeReply(Data(changed.utf8), action: .status))
        }
        let missing = encoded.replacingOccurrences(of: "\"journalFingerprint\":null,", with: "")
        XCTAssertNotEqual(missing, encoded)
        XCTAssertThrowsError(try codec.decodeReply(Data(missing.utf8), action: .status))
    }

    func testMessagesRemainBoundedIncludingEscapesAndUnicode() throws {
        for message in [String(repeating: "\u{0000}", count: 20_000), String(repeating: "🪵", count: 20_000)] {
            let status = IdleLockStatus(phase: .off, message: message)
            let data = codec.statusReply(status)
            XCTAssertLessThanOrEqual(data.count, LockWireCodec.maximumBytes)
            guard case .status(let decoded) = try codec.decodeReply(data, action: .status) else {
                return XCTFail("Expected bounded status")
            }
            XCTAssertLessThanOrEqual(decoded.message.utf8.count, 768)
        }
    }

    private func testClient() -> IdleLockClient {
        IdleLockClient(
            requirements: { throw IdleLockClientError.unavailable("No policy reads in tests") },
            fetch: { nil }, launch: { _ in XCTFail("Unexpected launch") }
        )
    }
}
