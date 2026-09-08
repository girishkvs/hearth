import Foundation
import XCTest
import HearthCore
@testable import HearthCLI

final class StatusPrinterTests: XCTestCase {
    func testUnavailableHelperStillShowsActualSettingsAndSetupGuidance() throws {
        for state in [HelperState.setupRequired, .incompatible, .unavailable] {
            let status = try readStatus(helper: HelperAvailability(state: state, message: "Fake helper needs repair."))
            let text = StatusPrinter().text(status)
            XCTAssertTrue(text.contains("Battery: Idle sleep after 5 minute(s)"))
            XCTAssertTrue(text.contains("Power adapter: Never idle sleeps"))
            XCTAssertTrue(text.contains("Fake helper needs repair."))
            XCTAssertTrue(text.contains("Power changes are disabled"))
            XCTAssertTrue(text.contains("hearth setup"))
        }
    }

    func testReadyHelperDoesNotReportDisabledWrites() throws {
        let status = try readStatus(helper: .ready)
        let text = StatusPrinter().text(status)
        XCTAssertTrue(text.contains("Helper: Ready."))
        XCTAssertFalse(text.contains("Power changes are disabled"))
    }

    func testJSONIncludesHelperStateAndMessageWithoutComputedReadiness() throws {
        let status = try readStatus(helper: HelperAvailability(state: .unavailable, message: "Fake helper offline."))
        let json = try StatusPrinter().json(status)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let helper = try XCTUnwrap(object["helper"] as? [String: Any])
        XCTAssertEqual(helper["state"] as? String, "unavailable")
        XCTAssertEqual(helper["message"] as? String, "Fake helper offline.")
        XCTAssertNil(helper["isReady"])
    }

    private func readStatus(helper: HelperAvailability) throws -> HearthStatus {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-cli-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        return try HearthService(runner: StatusRunner(helper: helper), stateDirectory: directory).status()
    }
}

private struct StatusRunner: PowerCommandRunning {
    let helper: HelperAvailability

    func helperAvailability() -> HelperAvailability { helper }

    func readSettings() throws -> PowerSettings {
        PowerSettings(values: [.battery: 5, .adapter: 0], currentSource: "Fake power adapter")
    }

    func apply(_ changes: [PowerChange]) throws -> [CommandOutcome] {
        XCTFail("Status printing must never request a power write.")
        throw HearthError.command("Unexpected fake power write.")
    }
}
