import Foundation
import XCTest
import HearthCore
@testable import HearthCLI

final class StatusPrinterTests: XCTestCase {
    func testUnavailableHelperStillShowsActualSettingsAndSetupGuidance() throws {
        for state in [HelperState.setupRequired, .incompatible, .unavailable] {
            let status = try readStatus(helper: HelperAvailability(state: state, message: "Fake helper needs repair."))
            let text = StatusPrinter().text(status)
            XCTAssertTrue(text.contains("System — Battery: Idle sleep after 5 minute(s)"))
            XCTAssertTrue(text.contains("System — Power adapter: Never idle sleeps"))
            XCTAssertTrue(text.contains("Display — Battery: Display off after 2 minute(s)"))
            XCTAssertTrue(text.contains("Display — Power adapter: No idle display timeout"))
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
        XCTAssertEqual(object["schemaVersion"] as? Int, 4)
        let system = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        let display = try XCTUnwrap(object["displayProfiles"] as? [[String: Any]])
        XCTAssertEqual(system.first { $0["profile"] as? String == "battery" }?["actualMinutes"] as? Int, 5)
        XCTAssertEqual(display.first { $0["profile"] as? String == "battery" }?["actualMinutes"] as? Int, 2)
        XCTAssertTrue(system.allSatisfy { $0["setting"] as? String == "system" })
        XCTAssertTrue(display.allSatisfy { $0["setting"] as? String == "display" })
    }

    func testLockStatusIncludesGlobalScopeAndBorrowedOwnership() throws {
        let lock = IdleLockStatus(
            phase: .active, message: "Fake Lock configured.", saverDelaySeconds: 0, originalSaverDelaySeconds: 300,
            dependencies: [
                IdleLockDependency(setting: .system, profile: .battery, acquired: false, actualMinutes: 0),
                IdleLockDependency(setting: .display, profile: .adapter, acquired: true, actualMinutes: 0),
            ], canRestore: true, hasManagedChanges: true
        )
        let text = StatusPrinter().lockText(lock)
        XCTAssertTrue(text.contains("Current user · keeps System and Display awake"))
        XCTAssertTrue(text.contains("borrowed; prior setting retained"))
        XCTAssertTrue(text.contains("Required by Lock"))
        XCTAssertTrue(text.contains("hearth lock restore"))
        XCTAssertTrue(text.contains("Lock: Configured"))
        XCTAssertTrue(text.contains("do not prove immediate macOS timer adoption"))
        XCTAssertTrue(text.contains("may adopt or restore the timer later"))
        XCTAssertFalse(text.contains("Lock: Active"))
        let status = try readStatus(helper: .ready, lock: lock)
        let json = try StatusPrinter().json(status)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let encoded = try XCTUnwrap(object["idleLock"] as? [String: Any])
        XCTAssertEqual(encoded["phase"] as? String, "active")
        XCTAssertEqual(encoded["hasManagedChanges"] as? Bool, true)
        XCTAssertEqual(encoded["saverDelaySeconds"] as? Int, 0)
        XCTAssertEqual(encoded["originalSaverDelaySeconds"] as? Int, 300)
        XCTAssertEqual((encoded["dependencies"] as? [[String: Any]])?.count, 2)
    }

    func testUnconfirmedLockNeverReportsActiveProtection() {
        for phase in [IdleLockPhase.off, .setupRequired, .unavailable, .needsRestore, .uncertain] {
            let text = StatusPrinter().lockText(IdleLockStatus(phase: phase, message: "Sample \(phase.rawValue)"))
            XCTAssertFalse(text.contains("Lock: Configured"))
            XCTAssertFalse(text.contains("Lock: Active"))
        }
        XCTAssertFalse(StatusPrinter().lockText(nil).contains("choose Enable Lock controls"))
        let setup = StatusPrinter().lockText(IdleLockStatus(phase: .setupRequired, message: "Legacy setup status."))
        XCTAssertFalse(setup.contains("Enable Lock controls"))
    }

    func testGetterFailureRetainsErrorWithoutPermissionInstructions() {
        let text = StatusPrinter().lockText(IdleLockStatus(
            phase: .unavailable,
            message: "Synthetic preference synchronization failure."
        ))
        XCTAssertTrue(text.contains("Synthetic preference synchronization failure"))
        XCTAssertTrue(text.contains("Lock: Unavailable"))
        XCTAssertFalse(text.contains("Enable Lock controls"))
        XCTAssertFalse(text.contains("Lock: Active"))
    }

    func testUnconfirmedStatusExplainsBlockedControlsAndSafeDiagnostics() throws {
        let lock = IdleLockStatus(
            phase: .uncertain, message: "Sample unconfirmed change.",
            saverDelaySeconds: 0, originalSaverDelaySeconds: 300,
            dependencies: [IdleLockDependency(setting: .system, profile: .battery, acquired: true, actualMinutes: 0)],
            hasManagedChanges: true
        )
        let text = StatusPrinter().text(try readStatus(helper: .ready, lock: lock))
        XCTAssertTrue(text.contains("Configuration unconfirmed"))
        XCTAssertTrue(text.contains("does not mean cancelled or unchanged"))
        XCTAssertTrue(text.contains("Lock, Restore Lock and required System/Display changes are blocked"))
        XCTAssertTrue(text.contains("Saved effective screen-saver idle delay: 300 seconds"))
        XCTAssertTrue(text.contains("state.json"))
        XCTAssertTrue(text.contains("hearth status --json"))
        XCTAssertTrue(text.contains("Status does not retry the write"))
        XCTAssertFalse(text.contains("use 'hearth lock restore' first"))
        XCTAssertFalse(text.contains("Use 'hearth lock restore' to release"))
        XCTAssertNil(IdleLockStatus(phase: .active, message: "Confirmed.", canRestore: true).recoveryGuidance)
    }

    private func readStatus(helper: HelperAvailability, lock: IdleLockStatus? = nil) throws -> HearthStatus {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-cli-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = try HearthService(runner: StatusRunner(helper: helper), stateDirectory: directory).status()
        return HearthStatus(
            schemaVersion: status.schemaVersion, currentSource: status.currentSource, profiles: status.profiles,
            warnings: status.warnings, helper: status.helper, displayProfiles: status.displayProfiles, idleLock: lock
        )
    }
}

private struct StatusRunner: PowerCommandRunning {
    let helper: HelperAvailability

    func helperAvailability() -> HelperAvailability { helper }

    func readSettings() throws -> PowerSettings {
        PowerSettings(values: [.battery: 5, .adapter: 0], currentSource: "Fake power adapter", displayValues: [.battery: 2, .adapter: 0])
    }

    func apply(_ changes: [PowerChange]) throws -> [CommandOutcome] {
        XCTFail("Status printing must never request a power write.")
        throw HearthError.command("Unexpected fake power write.")
    }
}
