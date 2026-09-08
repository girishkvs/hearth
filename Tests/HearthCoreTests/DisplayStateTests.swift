import Foundation
import XCTest
@testable import HearthCore

final class DisplayStateTests: XCTestCase {
    private var directory: URL!
    private var runner: FakeRunner!
    private var service: HearthService!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-display-test-\(UUID())")
        runner = FakeRunner()
        service = HearthService(runner: runner, stateDirectory: directory)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testLegacyRequestDefaultsToSystemAndExplicitInvalidSettingsFail() throws {
        let decoder = JSONDecoder()
        let request = try decoder.decode(PowerRequest.self, from: Data(#"{"action":"on","target":"both"}"#.utf8))
        XCTAssertEqual(request.setting, .system)
        _ = try service.perform(request)
        XCTAssertEqual(try runner.readSettings().displayValues, [.battery: 2, .adapter: 10])
        for value in ["null", #""screenLock""#, "1", "true"] {
            XCTAssertThrowsError(try decoder.decode(
                PowerRequest.self, from: Data(#"{"action":"on","target":"both","setting":\#(value)}"#.utf8)
            ))
        }
    }

    func testActiveVersionOneMigrationPreservesExactSystemOwnership() throws {
        let legacy = #"{"version":1,"profiles":{"battery":{"override":{"original":1,"applied":0}}}}"#
        try writeRaw(legacy)
        runner.set(.battery, 0)
        let migrated = try service.status()
        let state = try load()
        XCTAssertEqual(state.version, 4)
        XCTAssertEqual(state.profiles, ["battery": ProfileState(override: OverrideState(original: 1, applied: 0))])
        XCTAssertTrue(state.displayProfiles.isEmpty)
        XCTAssertEqual(migrated.schemaVersion, 4)
        XCTAssertEqual(migrated.profiles.first?.actualMinutes, 0)
        XCTAssertEqual(migrated.profiles.first?.originalMinutes, 1)
        XCTAssertTrue(migrated.displayProfiles.allSatisfy { !$0.isManaged })
        XCTAssertTrue(runner.batches().isEmpty)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        _ = try service.status()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("state.json")), bytes)

        _ = try service.perform(PowerRequest(action: .on, setting: .display))
        XCTAssertEqual(try load().profiles, state.profiles)
        XCTAssertEqual(try load().displayProfiles["battery"]?.override?.original, 2)
        XCTAssertEqual(try load().displayProfiles["adapter"]?.override?.original, 10)
        _ = try service.perform(PowerRequest(action: .restore, setting: .display))
        XCTAssertEqual(try load().profiles, state.profiles)
        XCTAssertEqual(try runner.readSettings().values[.battery], 0)
        _ = try service.perform(PowerRequest(action: .restore))
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
        XCTAssertEqual(try runner.readSettings().displayValues, [.battery: 2, .adapter: 10])
    }

    func testLegacyPendingOperationsRecoverWithoutCreatingDisplayState() throws {
        let cases: [(String, Int, Bool)] = [
            (#"{"pending":{"action":"on","original":1,"applied":0}}"#, 0, true),
            (#"{"pending":{"action":"on","original":1,"applied":0}}"#, 1, false),
            (#"{"override":{"original":1,"applied":0},"pending":{"action":"restore","original":0,"applied":1}}"#, 0, true),
            (#"{"override":{"original":1,"applied":0},"pending":{"action":"restore","original":0,"applied":1}}"#, 1, false),
            (#"{"override":{"original":1,"applied":0},"pending":{"action":"sleep","original":0,"applied":9}}"#, 9, false),
        ]
        for (record, actual, managed) in cases {
            try writeRaw(#"{"version":1,"profiles":{"battery":\#(record)}}"#)
            runner.set(.battery, actual)
            let status = try service.status()
            XCTAssertEqual(status.profiles.first?.isManaged, managed, record)
            XCTAssertTrue(try load().displayProfiles.isEmpty)
            XCTAssertEqual(try load().version, 4)
        }
        XCTAssertTrue(runner.batches().isEmpty)
    }

    func testUnavailableLegacySystemProfileIsRetainedDuringMigration() throws {
        try writeRaw(#"{"version":1,"profiles":{"battery":{"override":{"original":1,"applied":0}}}}"#)
        runner.set(.battery, nil)
        let status = try service.status()
        XCTAssertFalse(status.warnings.isEmpty)
        XCTAssertEqual(try load().profiles["battery"]?.override?.original, 1)
        XCTAssertEqual(try load().profiles["battery"]?.override?.applied, 0)
        XCTAssertTrue(try load().displayProfiles.isEmpty)
    }

    func testCorruptFutureAndInvalidDisplayStateAreNeverReplaced() throws {
        for raw in [
            #"{"version":5,"profiles":{},"displayProfiles":{}}"#,
            #"{"version":2,"profiles":{}}"#,
            #"{"version":1,"profiles":{},"displayProfiles":{"battery":{"override":{"original":2,"applied":0}}}}"#,
            #"{"version":2,"profiles":{},"displayProfiles":{"battery":{"override":{"original":0,"applied":0}}}}"#,
            #"{"version":2,"profiles":{},"displayProfiles":{"ups":{"override":{"original":2,"applied":0}}}}"#,
        ] {
            try writeRaw(raw)
            XCTAssertFalse(try service.status().warnings.isEmpty, raw)
            for setting in PowerSetting.allCases {
                XCTAssertThrowsError(try service.perform(PowerRequest(action: .on, setting: setting)), raw)
            }
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8), raw)
        }
        XCTAssertTrue(runner.batches().isEmpty)
    }

    func testDisplayAndSystemActivationRestoreAndPermanentTimeoutStayIndependent() throws {
        _ = try service.perform(PowerRequest(action: .on))
        let systemRecord = try load().profiles
        _ = try service.perform(PowerRequest(action: .on, target: .battery, setting: .display))
        _ = try service.perform(PowerRequest(action: .on, target: .battery, setting: .display))
        XCTAssertEqual(runner.batches().count, 2)
        XCTAssertEqual(runner.batches().last?.map(\.setting), [.display])
        XCTAssertEqual(runner.batches().last?.map(\.expectedMinutes), [2])
        XCTAssertEqual(try runner.readSettings().displayValues, [.battery: 0, .adapter: 10])
        XCTAssertEqual(try load().profiles, systemRecord)

        _ = try service.perform(PowerRequest(action: .sleep, target: .battery, minutes: 7, setting: .display))
        XCTAssertTrue(try load().displayProfiles.isEmpty)
        XCTAssertEqual(try load().profiles, systemRecord)
        _ = try service.perform(PowerRequest(action: .restore, setting: .display))
        XCTAssertEqual(try runner.readSettings().displayValues[.battery], 7)
        _ = try service.perform(PowerRequest(action: .restore))
        XCTAssertEqual(try runner.readSettings().displayValues[.battery], 7)
        XCTAssertFalse(try service.status().hasManagedChanges)
    }

    func testDisplayAlreadyZeroNeverInventsBaseline() throws {
        runner.setDisplay(.adapter, 0)
        let result = try service.perform(PowerRequest(action: .on, setting: .display))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(runner.batches().first?.map(\.profile), [.battery])
        XCTAssertNil(result.status.displayProfiles.first { $0.profile == .adapter }?.originalMinutes)
        XCTAssertEqual(try runner.readSettings().values, [.battery: 1, .adapter: 0])
    }

    func testExternalChangesAreScopedBySettingNotJustProfile() throws {
        _ = try service.perform(PowerRequest(action: .on))
        _ = try service.perform(PowerRequest(action: .on, setting: .display))
        runner.set(.battery, 8)
        let displayRestore = try service.perform(PowerRequest(action: .restore, setting: .display))
        XCTAssertTrue(displayRestore.succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 8)
        XCTAssertEqual(try runner.readSettings().displayValues, [.battery: 2, .adapter: 10])

        _ = try service.perform(PowerRequest(action: .on, target: .battery))
        _ = try service.perform(PowerRequest(action: .on, target: .battery, setting: .display))
        runner.setDisplay(.battery, 5)
        let result = try service.perform(PowerRequest(action: .restore, target: .battery, setting: .display))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.outcomes.first?.setting, .display)
        XCTAssertEqual(result.outcomes.first?.kind, .preserved)
        XCTAssertEqual(try load().profiles["battery"]?.override?.original, 8)
        XCTAssertEqual(try runner.readSettings().displayValues[.battery], 5)
    }

    func testSkippedDisplayWriteCannotClaimAnExternalZero() throws {
        let fake = runner!
        runner.beforeApply = { fake.setDisplay(.battery, 0) }
        runner.skip([.battery])
        let result = try service.perform(PowerRequest(action: .on, target: .battery, setting: .display))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.outcomes.first?.kind, .preserved)
        XCTAssertTrue(try load().displayProfiles.isEmpty)
        XCTAssertTrue(try load().profiles.isEmpty)
    }

    func testPartialDisplayFailureRetainsOnlySuccessfulBaselineAndSystemState() throws {
        _ = try service.perform(PowerRequest(action: .on))
        let systemRecord = try load().profiles
        runner.fail([.adapter])
        let result = try service.perform(PowerRequest(action: .on, setting: .display))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try load().displayProfiles["battery"]?.override?.original, 2)
        XCTAssertNil(try load().displayProfiles["adapter"])
        XCTAssertEqual(try load().profiles, systemRecord)
        runner.fail([.battery])
        XCTAssertFalse(try service.perform(PowerRequest(action: .restore, setting: .display)).succeeded)
        XCTAssertEqual(try load().displayProfiles["battery"]?.override?.original, 2)
        runner.fail([])
        XCTAssertTrue(try service.perform(PowerRequest(action: .restore, setting: .display)).succeeded)
        XCTAssertEqual(try load().profiles, systemRecord)
    }

    func testUnavailableDisplayRetainsPendingStateAndDoesNotBlockSystem() throws {
        try seedDisplay(ProfileState(pending: PendingOperation(action: .on, original: 2, applied: 0)))
        runner.setDisplay(.battery, nil)
        let status = try service.status()
        XCTAssertTrue(status.hasManagedChanges)
        XCTAssertEqual(status.displayProfiles.first?.phase, "pending-on")
        XCTAssertFalse(try service.perform(PowerRequest(action: .restore, target: .battery, setting: .display)).succeeded)
        XCTAssertTrue(try service.perform(PowerRequest(action: .on, target: .battery)).succeeded)
        XCTAssertEqual(try load().displayProfiles["battery"]?.pending?.original, 2)
    }

    func testDisplayReadbackFailureAndUnknownCompletionRetainPendingRecovery() throws {
        _ = try service.perform(PowerRequest(action: .on))
        let systemRecord = try load().profiles
        runner.failReadback()
        XCTAssertThrowsError(try service.perform(PowerRequest(action: .on, setting: .display)))
        XCTAssertEqual(try load().displayProfiles["battery"]?.pending?.original, 2)
        XCTAssertEqual(try load().profiles, systemRecord)
        runner.recoverReads()
        XCTAssertEqual(try service.status().displayProfiles.first?.originalMinutes, 2)
        _ = try service.perform(PowerRequest(action: .restore, setting: .display))
        runner.beforeApply = { throw HearthError.indeterminateHelper("Fake lost reply") }
        XCTAssertThrowsError(try service.perform(PowerRequest(action: .on, setting: .display)))
        XCTAssertEqual(try load().displayProfiles["battery"]?.pending?.original, 2)
        runner.setDisplay(.battery, 0)
        runner.setDisplay(.adapter, 0)
        let recovered = try service.status()
        XCTAssertTrue(recovered.displayProfiles.allSatisfy(\.isManaged))
        XCTAssertEqual(try load().profiles, systemRecord)
    }

    func testAllDisplayPendingActionsRecoverBeforeAfterAndExternalWrites() throws {
        let records: [ProfileState] = [
            ProfileState(pending: PendingOperation(action: .on, original: 2, applied: 0)),
            ProfileState(override: OverrideState(original: 2, applied: 0),
                         pending: PendingOperation(action: .restore, original: 0, applied: 2)),
            ProfileState(override: OverrideState(original: 2, applied: 0),
                         pending: PendingOperation(action: .sleep, original: 0, applied: 9)),
            ProfileState(pending: PendingOperation(action: .sleep, original: 2, applied: 9)),
        ]
        for record in records {
            let pending = try XCTUnwrap(record.pending)
            for actual in [pending.original, pending.applied, 14] {
                try seedDisplay(record)
                runner.setDisplay(.battery, actual)
                let result = try service.status()
                let expectedManaged = actual == pending.applied
                    ? pending.action == .on
                    : actual == pending.original && record.override != nil
                XCTAssertEqual(result.displayProfiles.first?.isManaged, expectedManaged, "\(pending.action) \(actual)")
                XCTAssertNil(try load().displayProfiles["battery"]?.pending)
                XCTAssertEqual(try runner.readSettings().displayValues[.battery], actual)
                XCTAssertTrue(try load().profiles.isEmpty)
            }
        }
        XCTAssertTrue(runner.batches().isEmpty)
    }

    func testOneJournalLockSerializesSystemAndDisplayClients() throws {
        let testDirectory = directory!
        let fake = runner!
        runner.beforeApply = {
            let data = try Data(contentsOf: testDirectory.appendingPathComponent("state.json"))
            let state = try JSONDecoder().decode(SavedState.self, from: data)
            XCTAssertEqual(state.displayProfiles["battery"]?.pending?.original, 2)
            XCTAssertThrowsError(try HearthService(runner: fake, stateDirectory: testDirectory)
                .perform(PowerRequest(action: .on))) { error in
                XCTAssertEqual(error.localizedDescription, HearthError.busy.localizedDescription)
            }
        }
        XCTAssertTrue(try service.perform(PowerRequest(action: .on, setting: .display)).succeeded)
        XCTAssertEqual(runner.batches().count, 1)
        XCTAssertEqual(try runner.readSettings().values, [.battery: 1, .adapter: 0])
    }

    func testIncompatibleHelperBlocksBothSettingsBeforeMigratingLegacyState() throws {
        let legacy = #"{"version":1,"profiles":{"battery":{"override":{"original":1,"applied":0}}}}"#
        try writeRaw(legacy)
        runner.setAvailability(.incompatible)
        for setting in PowerSetting.allCases {
            XCTAssertThrowsError(try service.perform(PowerRequest(action: .on, setting: setting)))
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("state.json"), encoding: .utf8), legacy)
        XCTAssertTrue(runner.batches().isEmpty)
    }

    private func load() throws -> SavedState {
        let store = StateStore(directory: directory)
        return try store.withLock { try store.load() }
    }

    private func seedDisplay(_ record: ProfileState) throws {
        let store = StateStore(directory: directory)
        try store.withLock { try store.save(SavedState(displayProfiles: ["battery": record])) }
    }

    private func writeRaw(_ raw: String) throws {
        let store = StateStore(directory: directory)
        try store.withLock {
            let file = directory.appendingPathComponent("state.json")
            try Data(raw.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
