import Foundation
import XCTest
@testable import HearthCore

final class FakeScreenSaver: ScreenSaverControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration = ScreenSaverConfiguration(
        storedValue: .integer(300), effectiveSeconds: 300,
        dictionarySource: .currentUserCurrentHost, valueSource: .currentUserCurrentHost,
        contextFingerprint: String(repeating: "a", count: 64)
    )
    private var absentConfiguration = ScreenSaverConfiguration(
        storedValue: .absent, effectiveSeconds: 1200,
        dictionarySource: .registeredDefaults, valueSource: .registeredDefaults,
        contextFingerprint: String(repeating: "a", count: 64)
    )
    private var availability: ScreenSaverAvailability = .ready
    private var changes: [(ScreenSaverStoredValue, ScreenSaverConfiguration)] = []
    var beforeApply: (@Sendable () throws -> Void)?
    var beforeObserve: (@Sendable () throws -> Void)?
    var rejected = false
    var unknown = false
    var ignoreWrite = false
    var omitConfiguration = false

    func observe() throws -> ScreenSaverObservation {
        try beforeObserve?()
        return lock.withLock {
            ScreenSaverObservation(
                delaySeconds: configuration.effectiveSeconds, availability: availability,
                message: "Fake screen-saver status", configuration: omitConfiguration ? nil : configuration
            )
        }
    }

    func apply(value: ScreenSaverStoredValue, expected: ScreenSaverConfiguration) throws {
        try beforeApply?()
        try lock.withLock {
            guard !rejected, configuration == expected, availability == .ready else {
                throw ScreenSaverError.rejected("Fake setter refused before writing")
            }
            changes.append((value, expected))
            if !ignoreWrite {
                switch value {
                case .absent: configuration = absentConfiguration
                case .integer(let seconds):
                    configuration = explicitConfiguration(seconds, context: configuration.contextFingerprint)
                }
            }
            if unknown { throw ScreenSaverError.completionUnknown("Fake lost reply") }
        }
    }

    func set(_ seconds: Int) {
        lock.withLock { configuration = explicitConfiguration(seconds, context: configuration.contextFingerprint) }
    }
    func setConfiguration(_ value: ScreenSaverConfiguration) {
        lock.withLock {
            configuration = value
            if value.storedValue == .absent { absentConfiguration = value }
        }
    }
    func setAvailability(_ value: ScreenSaverAvailability) { lock.withLock { availability = value } }
    func writes() -> [(ScreenSaverStoredValue, ScreenSaverConfiguration)] { lock.withLock { changes } }

    private func explicitConfiguration(_ seconds: Int, context: String) -> ScreenSaverConfiguration {
        ScreenSaverConfiguration(
            storedValue: .integer(seconds), effectiveSeconds: seconds,
            dictionarySource: .currentUserCurrentHost, valueSource: .currentUserCurrentHost,
            contextFingerprint: context
        )
    }
}

private struct SnapshotLockController: IdleLockControlling {
    let snapshot: IdleLockStatus
    let afterRead: @Sendable () throws -> Void

    func status() throws -> IdleLockStatus {
        try afterRead()
        return snapshot
    }

    func perform(_ request: IdleLockRequest) throws -> IdleLockResult {
        throw HearthError.command("This read-only snapshot fixture cannot perform a Lock action.")
    }
}

final class IdleLockServiceTests: XCTestCase {
    private var directory: URL!
    private var runner: FakeRunner!
    private var saver: FakeScreenSaver!
    private var controller: IdleLockService!
    private var service: HearthService!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-lock-test-\(UUID())")
        runner = FakeRunner()
        saver = FakeScreenSaver()
        controller = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        service = HearthService(runner: runner, stateDirectory: directory, idleLockController: controller)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testLockCoordinatesAllAvailableProfilesAndRestoresOnlyAcquiredValues() throws {
        let result = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.status.phase, .active)
        XCTAssertEqual(result.status.dependencies.count, 4)
        XCTAssertEqual(result.status.dependencies.filter(\.acquired).count, 3)
        XCTAssertEqual(try saver.observe().delaySeconds, 0)
        XCTAssertEqual(try runner.readSettings().values, [.battery: 0, .adapter: 0])
        XCTAssertEqual(try runner.readSettings().displayValues, [.battery: 0, .adapter: 0])
        let restored = try controller.perform(IdleLockRequest(action: .restore))
        XCTAssertTrue(restored.succeeded)
        XCTAssertFalse(restored.message.contains("Detected external changes"))
        XCTAssertFalse(restored.status.hasManagedChanges)
        XCTAssertEqual(try saver.observe().delaySeconds, 300)
        XCTAssertEqual(try runner.readSettings().values, [.battery: 1, .adapter: 0])
        XCTAssertEqual(try runner.readSettings().displayValues, [.battery: 2, .adapter: 10])
        XCTAssertFalse(try service.status().hasManagedChanges)
    }

    func testBorrowedActiveSystemZeroOriginalOneRemainsExactlyOwned() throws {
        _ = try service.perform(PowerRequest(action: .on))
        let baseline = try load().profiles
        XCTAssertEqual(baseline["battery"]?.override, OverrideState(original: 1, applied: 0))
        XCTAssertTrue(try service.performIdleLock(IdleLockRequest(action: .on)).succeeded)
        XCTAssertTrue(try service.performIdleLock(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try load().profiles, baseline)
        XCTAssertEqual(try runner.readSettings().values[.battery], 0)
        XCTAssertEqual(try saver.observe().delaySeconds, 300)
        XCTAssertTrue(try service.status().hasManagedChanges)
    }

    func testSchemaOneTwoAndThreeMigrationNeverInventsLockOwnership() throws {
        let store = StateStore(directory: directory)
        for version in [1, 2, 3] {
            try store.withLock {
                try store.save(SavedState(version: version, profiles: [
                    "battery": ProfileState(override: OverrideState(original: 1, applied: 0))
                ]))
            }
            runner.set(.battery, 0)
            let status = try service.status()
            XCTAssertEqual(status.schemaVersion, 4)
            XCTAssertEqual(try load().version, 4)
            XCTAssertNil(try load().lockOverride)
            XCTAssertEqual(try load().profiles["battery"]?.override?.original, 1)
            XCTAssertTrue(try load().displayProfiles.isEmpty)
        }
        XCTAssertTrue(saver.writes().isEmpty)
        XCTAssertTrue(runner.batches().isEmpty)
    }

    func testAlreadyNeverSettingsAreBorrowedWithoutBaselines() throws {
        runner.set(.battery, 0)
        runner.setDisplay(.battery, 0)
        runner.setDisplay(.adapter, 0)
        saver.set(0)
        let result = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.status.dependencies.allSatisfy { !$0.acquired })
        XCTAssertNil(result.status.originalSaverDelaySeconds)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertTrue(runner.batches().isEmpty)
        XCTAssertTrue(saver.writes().isEmpty)
        XCTAssertEqual(try saver.observe().delaySeconds, 0)
    }

    func testRepeatedLockOnDoesNotReplaceOriginalOrWriteAgain() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let snapshot = try load()
        let count = runner.batches().count
        let second = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        XCTAssertTrue(try second.perform(IdleLockRequest(action: .on)).succeeded)
        XCTAssertEqual(try load(), snapshot)
        XCTAssertEqual(runner.batches().count, count)
        XCTAssertEqual(saver.writes().count, 1)
    }

    func testRequiredPowerOperationsAreBlockedWithDirectRestoreLockGuidance() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let snapshot = try load()
        for setting in PowerSetting.allCases {
            for action in [PowerAction.on, .restore, .sleep] {
                XCTAssertThrowsError(try service.perform(PowerRequest(
                    action: action, minutes: action == .sleep ? 5 : nil, setting: setting
                ))) { error in
                    XCTAssertTrue(error.localizedDescription.contains("Restore Lock"))
                }
            }
        }
        XCTAssertEqual(try load(), snapshot)
        XCTAssertTrue(try service.status().idleLock?.dependencies.allSatisfy { $0.actualMinutes == 0 } == true)
    }

    func testPermissionAndManagedRestrictionsRejectBeforeAnyPowerWrite() throws {
        for availability in [ScreenSaverAvailability.setupRequired, .managed, .unavailable] {
            saver.setAvailability(availability)
            XCTAssertFalse(try controller.status().canEnable)
            let result = try controller.perform(IdleLockRequest(action: .on))
            XCTAssertFalse(result.succeeded)
            XCTAssertFalse(result.status.hasManagedChanges)
        }
        XCTAssertTrue(runner.batches().isEmpty)
        XCTAssertTrue(saver.writes().isEmpty)
        XCTAssertNil(try load().lockOverride)
    }

    func testHelperUnavailableAndMissingSettingRefuseBeforeMutation() throws {
        runner.setAvailability(.incompatible)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        runner.setAvailability(.ready)
        runner.setDisplay(.battery, nil)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        XCTAssertTrue(runner.batches().isEmpty)
        XCTAssertTrue(saver.writes().isEmpty)
    }

    func testAdapterOnlyMacCoordinatesAndRestoresWithoutPhantomBattery() throws {
        runner.set(.battery, nil)
        runner.setDisplay(.battery, nil)
        let result = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.status.dependencies.map(\.profile), [.adapter, .adapter])
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().displayValues, [.adapter: 10])
    }

    func testPartialPowerFailureKeepsTransactionAndRestoresOnlySuccesses() throws {
        runner.fail([.adapter])
        let failed = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.status.phase, .needsRestore)
        XCTAssertTrue(failed.status.hasManagedChanges)
        XCTAssertTrue(saver.writes().isEmpty)
        XCTAssertEqual(try saver.observe().delaySeconds, 300)
        runner.fail([])
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
        XCTAssertEqual(try runner.readSettings().displayValues, [.battery: 2, .adapter: 10])
    }

    func testSkippedExternalZeroNeverBecomesLockOwned() throws {
        let fake = runner!
        runner.beforeApply = { fake.set(.battery, 0) }
        runner.skip([.battery])
        let failed = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertFalse(failed.succeeded)
        XCTAssertNil(try load().profiles["battery"])
        runner.beforeApply = nil
        runner.skip([])
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 0)
        XCTAssertEqual(runner.batches().count, 1)
        XCTAssertTrue(saver.writes().isEmpty)
    }

    func testNestedPowerReadCannotReplaceTheDurableLockBaseline() throws {
        let fake = runner!
        let file = directory.appendingPathComponent("state.json")
        runner.beforeRead = {
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
            if state.lockOverride?.phase == .enabling { fake.set(.battery, 7) }
        }
        let result = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try load().lockOverride?.dependencies.first?.original, 1)
        XCTAssertNil(try load().profiles["battery"])
        runner.beforeRead = nil
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 7)
        XCTAssertTrue(runner.batches().isEmpty)
    }

    func testRestorePersistsObservedLostOwnershipBeforeReleasingLastDependency() throws {
        runner.set(.battery, 0)
        runner.setDisplay(.battery, 0)
        _ = try controller.perform(IdleLockRequest(action: .on))
        let fake = runner!
        saver.beforeApply = { fake.setDisplay(.adapter, 7) }
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertNil(try load().displayProfiles["adapter"])
        XCTAssertEqual(try runner.readSettings().displayValues[.adapter], 7)
        runner.setDisplay(.adapter, 0)
        _ = try service.perform(PowerRequest(action: .restore, target: .adapter, setting: .display))
        XCTAssertEqual(try runner.readSettings().displayValues[.adapter], 0)
    }

    func testLostPowerReplyRetainsItsPendingRecordWithoutSendingSaverWrite() throws {
        runner.beforeApply = { throw HearthError.indeterminateHelper("Fake unknown helper completion") }
        let result = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try load().profiles["battery"]?.pending?.original, 1)
        XCTAssertTrue(saver.writes().isEmpty)
        runner.beforeApply = nil
        runner.set(.battery, 0)
        XCTAssertEqual(try controller.status().phase, .needsRestore)
        XCTAssertEqual(try load().profiles["battery"]?.override?.original, 1)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
    }

    func testPowerReadbackFailureKeepsLockAndPowerJournalsForLaterRecovery() throws {
        runner.failReadback()
        XCTAssertThrowsError(try controller.perform(IdleLockRequest(action: .on)))
        XCTAssertEqual(try load().profiles["battery"]?.pending?.original, 1)
        XCTAssertNotNil(try load().lockOverride)
        XCTAssertTrue(saver.writes().isEmpty)
        runner.recoverReads()
        XCTAssertEqual(try controller.status().phase, .needsRestore)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
    }

    func testUnknownRestoreCompletionRetainsAllPowerDependencies() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let powerCalls = runner.batches().count
        saver.unknown = true
        let result = try controller.perform(IdleLockRequest(action: .restore))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status.phase, .uncertain)
        XCTAssertEqual(runner.batches().count, powerCalls)
        XCTAssertEqual(try saver.observe().delaySeconds, 300)
        XCTAssertEqual(try load().lockOverride?.phase, .restoring)
        XCTAssertTrue(try load().lockOverride?.saverWritePending == true)
    }

    func testDefiniteSaverRejectionKeepsPowerForOneRestoreLock() throws {
        saver.rejected = true
        let failed = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.status.phase, .needsRestore)
        XCTAssertEqual(try load().lockOverride?.saverWritePending, false)
        saver.rejected = false
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
        XCTAssertEqual(try saver.observe().delaySeconds, 300)
    }

    func testExternalSaverChangeBeforeDispatchIsNotOverwrittenOrClaimed() throws {
        let fakeSaver = saver!
        saver.beforeApply = { fakeSaver.set(90) }
        let result = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try load().lockOverride?.saverApplied, false)
        XCTAssertEqual(try load().lockOverride?.saverWritePending, false)
        saver.beforeApply = nil
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try saver.observe().delaySeconds, 90)
        XCTAssertTrue(saver.writes().isEmpty)
    }

    func testUnknownSaverCompletionCannotBeClearedByMatchingReadback() throws {
        saver.unknown = true
        let result = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status.phase, .uncertain)
        XCTAssertEqual(try saver.observe().delaySeconds, 0)
        let saved = try load()
        XCTAssertTrue(saved.lockOverride?.saverWritePending == true)
        saver.unknown = false
        for seconds in [0, 300, 700] {
            saver.set(seconds)
            XCTAssertEqual(try controller.status().phase, .uncertain)
            XCTAssertFalse(try controller.status().canRestore)
            XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
            XCTAssertFalse(try controller.perform(IdleLockRequest(action: .on)).succeeded)
            XCTAssertEqual(try load().lockOverride, saved.lockOverride)
        }
        for setting in PowerSetting.allCases {
            XCTAssertThrowsError(try service.perform(PowerRequest(action: .restore, setting: setting))) { error in
                XCTAssertTrue(error.localizedDescription.contains("Restore Lock and required System/Display changes are blocked"))
                XCTAssertTrue(error.localizedDescription.contains("hearth status --json"))
                XCTAssertFalse(error.localizedDescription.contains("Use Restore Lock to release"))
            }
        }
        XCTAssertEqual(try load().lockOverride, saved.lockOverride)
        runner.set(.battery, 8)
        runner.setDisplay(.battery, 9)
        XCTAssertEqual(try service.status().idleLock?.phase, .uncertain)
        XCTAssertEqual(try load().profiles, saved.profiles)
        XCTAssertEqual(try load().displayProfiles, saved.displayProfiles)
        XCTAssertEqual(saver.writes().count, 1)
    }

    func testSaverNoReadbackDoesNotClaimActiveAndPreservesActual() throws {
        saver.ignoreWrite = true
        let result = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status.phase, .uncertain)
        XCTAssertTrue(try load().lockOverride?.saverWritePending == true)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try saver.observe().delaySeconds, 300)
    }

    func testExternalSaverAndPowerChangesArePreservedDuringRestore() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        saver.set(120)
        runner.setDisplay(.battery, 7)
        XCTAssertEqual(try controller.status().phase, .needsRestore)
        let result = try controller.perform(IdleLockRequest(action: .restore))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(try saver.observe().delaySeconds, 120)
        XCTAssertEqual(try runner.readSettings().displayValues[.battery], 7)
        XCTAssertEqual(try runner.readSettings().displayValues[.adapter], 10)
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
        XCTAssertEqual(saver.writes().count, 1)
    }

    func testPolicyRevocationDoesNotInventRestorationOrWeakenAuthentication() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        saver.setAvailability(.managed)
        let status = try controller.status()
        XCTAssertEqual(status.phase, .needsRestore)
        XCTAssertFalse(status.canRestore)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try load().lockOverride?.saverOriginal, 300)
        saver.setAvailability(.ready)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
    }

    func testObservedManagedFiniteDelayCanBePreservedWithoutWritingIt() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        saver.set(60)
        saver.setAvailability(.managed)
        XCTAssertTrue(try controller.status().canRestore)
        let result = try controller.perform(IdleLockRequest(action: .restore))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(try saver.observe().delaySeconds, 60)
        XCTAssertEqual(saver.writes().count, 1)
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
    }

    func testPartialRestoreRetainsRemainingOwnershipAndDoesNotRepeatSaverWrite() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        runner.fail([.battery])
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try saver.observe().delaySeconds, 300)
        XCTAssertEqual(saver.writes().count, 2)
        let saved = try load()
        XCTAssertTrue(saved.lockOverride?.saverReleased == true)
        XCTAssertNil(saved.lockOverride?.saverExternalChangePreserved)
        let encoded = try JSONEncoder().encode(saved)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil((fields["lockOverride"] as? [String: Any])?["saverExternalChangePreserved"])
        XCTAssertEqual(try JSONDecoder().decode(SavedState.self, from: encoded), saved)
        _ = try controller.status()
        runner.fail([])
        let relaunched = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        let restored = try relaunched.perform(IdleLockRequest(action: .restore))
        XCTAssertTrue(restored.succeeded)
        XCTAssertFalse(restored.message.contains("Detected external changes"))
        XCTAssertEqual(saver.writes().count, 2)
    }

    func testUnavailableOwnedProfileKeepsRestoreState() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        runner.setDisplay(.battery, nil)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertNotNil(try load().lockOverride)
        runner.setDisplay(.battery, 0)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().displayValues[.battery], 2)
    }

    func testJournalDurableBeforeSaverWriteAndBlocksAllOtherClients() throws {
        let testDirectory = directory!
        let fake = runner!
        saver.beforeApply = {
            let state = try JSONDecoder().decode(
                SavedState.self, from: Data(contentsOf: testDirectory.appendingPathComponent("state.json")))
            XCTAssertTrue(state.lockOverride?.saverWritePending == true)
            XCTAssertThrowsError(try HearthService(runner: fake, stateDirectory: testDirectory).status()) { error in
                XCTAssertEqual(error.localizedDescription, HearthError.busy.localizedDescription)
            }
        }
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
    }

    func testInterruptedPlanDoesNotAcquireExternalZeroOrRepeatActivation() throws {
        let store = StateStore(directory: directory)
        try store.withLock {
            try store.save(SavedState(lockOverride: LockOverride(
                phase: .enabling,
                dependencies: [
                    LockPowerOwnership(setting: .system, profile: .battery, original: 1),
                    LockPowerOwnership(setting: .display, profile: .battery, original: 2),
                ], saverOriginal: 300
            )))
        }
        runner.set(.battery, 0)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 0)
        XCTAssertTrue(runner.batches().isEmpty)
        XCTAssertTrue(saver.writes().isEmpty)
    }

    func testStandardStatusRetainsLockDependencyWhenNativeControllerUnavailable() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let other = HearthService(runner: runner, stateDirectory: directory)
        let status = try other.status()
        XCTAssertTrue(status.idleLock?.hasManagedChanges == true)
        XCTAssertTrue(status.idleLock?.requires(.system, profile: .battery) == true)
        XCTAssertFalse(status.idleLock?.canEnable == true)
    }

    func testNewerPowerObservationInvalidatesStaleActiveStatus() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let snapshot = try controller.status()
        let power = runner!
        let count = power.batches().count
        let result = try snapshotService(snapshot) { power.setDisplay(.adapter, 7) }.status()
        XCTAssertNotEqual(result.idleLock?.phase, .active)
        XCTAssertFalse(result.idleLock?.canRestore == true)
        XCTAssertEqual(result.idleLock?.dependencies.first { $0.setting == .display && $0.profile == .adapter }?.actualMinutes, 7)
        XCTAssertEqual(result.idleLock?.originalSaverDelaySeconds, 300)
        XCTAssertEqual(power.batches().count, count)
        XCTAssertTrue(try service.status().idleLock?.canRestore == true, "A fresh consistent observation must still permit normal restoration.")
    }

    func testNewerPendingJournalAlwaysOverridesStaleActiveStatus() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let snapshot = try controller.status()
        let store = StateStore(directory: directory)
        let result = try snapshotService(snapshot) {
            try store.withLock {
                var state = try store.load()
                state.lockOverride?.phase = .restoring
                state.lockOverride?.saverWritePending = true
                try store.save(state)
            }
        }.status()
        XCTAssertEqual(result.idleLock?.phase, .uncertain)
        XCTAssertFalse(result.idleLock?.canRestore == true)
        XCTAssertTrue(result.idleLock?.hasManagedChanges == true)
        XCTAssertEqual(result.idleLock?.originalSaverDelaySeconds, 300)
        XCTAssertTrue(try load().lockOverride?.saverWritePending == true)
    }

    func testCompletedConcurrentRestoreDoesNotLeaveFabricatedActiveStatus() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let snapshot = try controller.status()
        let native = controller!
        let result = try snapshotService(snapshot) {
            _ = try native.perform(IdleLockRequest(action: .restore))
        }.status()
        XCTAssertNotEqual(result.idleLock?.phase, .active)
        XCTAssertFalse(result.idleLock?.hasManagedChanges == true)
        XCTAssertFalse(result.idleLock?.canRestore == true)
        XCTAssertEqual(result.profiles.first { $0.profile == .battery }?.actualMinutes, 1)
        XCTAssertNil(try load().lockOverride)
    }

    func testNewAvailableProfileInvalidatesOldProtectionScope() throws {
        runner.set(.battery, nil)
        runner.setDisplay(.battery, nil)
        _ = try controller.perform(IdleLockRequest(action: .on))
        let snapshot = try controller.status()
        let power = runner!
        let result = try snapshotService(snapshot) {
            power.set(.battery, 1)
            power.setDisplay(.battery, 2)
        }.status()
        XCTAssertNotEqual(result.idleLock?.phase, .active)
        XCTAssertFalse(result.idleLock?.canRestore == true)
        XCTAssertEqual(result.idleLock?.dependencies.count, 2)
    }

    func testNewHelperFailureCannotRetainStaleReadiness() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let snapshot = try controller.status()
        let power = runner!
        let result = try snapshotService(snapshot) { power.setAvailability(.unavailable) }.status()
        XCTAssertEqual(result.helper.state, .unavailable)
        XCTAssertNotEqual(result.idleLock?.phase, .active)
        XCTAssertFalse(result.idleLock?.canRestore == true)
        XCTAssertTrue(result.idleLock?.hasManagedChanges == true)
    }

    func testUnbackedActiveControllerValueCannotClaimProtection() throws {
        let intended = IdleLockStatus(
            phase: .active, message: "Intended state is not evidence.",
            saverDelaySeconds: 0, canRestore: true, hasManagedChanges: true
        )
        let result = try snapshotService(intended) {}.status()
        XCTAssertNotEqual(result.idleLock?.phase, .active)
        XCTAssertFalse(result.idleLock?.hasManagedChanges == true)
        XCTAssertFalse(result.idleLock?.canRestore == true)
    }

    func testNewlyUntrustedJournalCannotRetainReadyToEnable() throws {
        let snapshot = try controller.status()
        XCTAssertTrue(snapshot.canEnable)
        let file = directory.appendingPathComponent("state.json")
        let result = try snapshotService(snapshot) {
            try Data("damaged".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }.status()
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertFalse(result.idleLock?.canEnable == true)
        XCTAssertFalse(result.idleLock?.canRestore == true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "damaged")
    }

    func testInvalidAndOlderLockJournalsFailClosed() throws {
        let dependencies = [
            LockPowerOwnership(setting: .system, profile: .battery, original: 1),
            LockPowerOwnership(setting: .display, profile: .battery, original: 2),
        ]
        let pending = LockOverride(phase: .enabling, dependencies: dependencies, saverOriginal: 300)
        XCTAssertThrowsError(try SavedState(version: 2, lockOverride: pending).validate())
        XCTAssertThrowsError(try LockOverride(phase: .active, dependencies: dependencies, saverOriginal: 300).validate())
        XCTAssertThrowsError(try LockOverride(phase: .enabling, dependencies: dependencies, saverOriginal: -1).validate())
        XCTAssertThrowsError(try LockOverride(phase: .enabling, dependencies: [dependencies[0], dependencies[0]], saverOriginal: 300).validate())
        XCTAssertThrowsError(try LockOverride(phase: .enabling, dependencies: [dependencies[0]], saverOriginal: 300).validate())
        let raw = #"{"version":2,"profiles":{},"displayProfiles":{},"lockOverride":{}}"#
        let store = StateStore(directory: directory)
        try store.withLock {
            let file = directory.appendingPathComponent("state.json")
            try Data(raw.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        XCTAssertThrowsError(try controller.perform(IdleLockRequest(action: .on)))
        XCTAssertTrue(saver.writes().isEmpty)
        XCTAssertTrue(runner.batches().isEmpty)
    }

    func testTypedAbsenceAndInheritedDefaultsRestoreWithoutInventingAnInteger() throws {
        let originals = [
            configuration(.absent, seconds: 1200, dictionary: .registeredDefaults, value: .registeredDefaults),
            configuration(.absent, seconds: 600, dictionary: .currentUserCurrentHost, value: .registeredDefaults),
            configuration(.absent, seconds: 300, dictionary: .currentUserAnyHost, value: .currentUserAnyHost),
            configuration(.absent, seconds: 60, dictionary: .anyUserAnyHost, value: .anyUserAnyHost),
            configuration(.integer(Int(Int32.max)), seconds: Int(Int32.max)),
        ]
        for original in originals {
            saver.setConfiguration(original)
            XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
            let saved = try XCTUnwrap(load().lockOverride)
            XCTAssertEqual(saved.backend, .preferences)
            XCTAssertEqual(saved.saverOriginalConfiguration, original)
            XCTAssertEqual(saved.saverAppliedConfiguration?.storedValue, .integer(0))
            XCTAssertEqual(saved.saverAppliedConfiguration?.contextFingerprint, original.contextFingerprint)
            XCTAssertFalse(saved.saverWritePending)
            let bytes = try JSONEncoder().encode(try load())
            XCTAssertEqual(try JSONDecoder().decode(SavedState.self, from: bytes), try load())
            XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
            XCTAssertEqual(try saver.observe().configuration, original)
            XCTAssertEqual(saver.writes().last?.0, original.storedValue)
            XCTAssertNil(try load().lockOverride)
        }
    }

    func testBorrowedInheritedZeroKeepsPresenceAndIndependentSystemBaseline() throws {
        _ = try service.perform(PowerRequest(action: .on))
        let systemBaseline = try load().profiles
        let original = configuration(.absent, seconds: 0, dictionary: .currentUserAnyHost, value: .currentUserAnyHost)
        saver.setConfiguration(original)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        XCTAssertNil(try load().lockOverride?.saverOriginal)
        XCTAssertEqual(try load().lockOverride?.saverOriginalConfiguration, original)
        XCTAssertNil(try load().lockOverride?.saverAppliedConfiguration)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try load().profiles, systemBaseline)
        XCTAssertEqual(try saver.observe().configuration, original)
        XCTAssertTrue(saver.writes().isEmpty)
        XCTAssertEqual(try runner.readSettings().values[.battery], 0)
        XCTAssertEqual(try load().profiles["battery"]?.override?.original, 1)
    }

    func testFullTypedSnapshotAndDependencyPlanAreDurableBeforeFirstPowerWrite() throws {
        let original = configuration(.absent, seconds: 1200, dictionary: .registeredDefaults, value: .registeredDefaults)
        saver.setConfiguration(original)
        let file = directory.appendingPathComponent("state.json")
        let fakeSaver = saver!
        runner.beforeApply = {
            let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
            XCTAssertEqual(state.version, 4)
            XCTAssertEqual(state.lockOverride?.saverOriginalConfiguration, original)
            XCTAssertEqual(state.lockOverride?.dependencies.count, 4)
            XCTAssertEqual(state.lockOverride?.dependencies.first?.original, 1)
            XCTAssertFalse(state.lockOverride?.saverWritePending == true)
            XCTAssertTrue(fakeSaver.writes().isEmpty)
        }
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
    }

    func testExternalStoredTimerAndPresenceChangesReleaseTimerWithoutWriting() throws {
        let externalConfigurations = [
            configuration(.integer(60), seconds: 60, context: String(repeating: "b", count: 64)),
            configuration(.absent, seconds: 0, dictionary: .currentUserAnyHost, value: .currentUserAnyHost),
        ]
        for external in externalConfigurations {
            saver.set(300)
            XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
            let writes = saver.writes().count
            saver.setConfiguration(external)
            let status = try controller.status()
            XCTAssertEqual(status.phase, .needsRestore)
            XCTAssertTrue(status.canRestore)
            XCTAssertTrue(try load().lockOverride?.saverReleased == true)
            XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
            XCTAssertEqual(try saver.observe().configuration, external)
            XCTAssertEqual(saver.writes().count, writes)
        }
    }

    func testExternalTimerNoticeSurvivesStatusPollAndServiceRecreation() throws {
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        saver.set(120)
        XCTAssertEqual(try controller.status().phase, .needsRestore)
        let saved = try load()
        XCTAssertEqual(saved.version, 4)
        XCTAssertTrue(saved.lockOverride?.saverReleased == true)
        XCTAssertEqual(saved.lockOverride?.saverExternalChangePreserved, true)
        _ = try controller.status()
        XCTAssertEqual(try load(), saved)

        let relaunched = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        let restored = try relaunched.perform(IdleLockRequest(action: .restore))
        XCTAssertTrue(restored.succeeded)
        XCTAssertTrue(restored.message.contains("Detected external changes"))
        XCTAssertEqual(try saver.observe().delaySeconds, 120)
        XCTAssertEqual(saver.writes().count, 1)
        XCTAssertEqual(try runner.readSettings().values, [.battery: 1, .adapter: 0])
        XCTAssertEqual(try runner.readSettings().displayValues, [.battery: 2, .adapter: 10])
        XCTAssertNil(try load().lockOverride)
    }

    func testExternalTimerNoticeSurvivesPartialPowerRestoreAndReload() throws {
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        saver.set(120)
        runner.fail([.battery])
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertTrue(try load().lockOverride?.saverReleased == true)
        XCTAssertEqual(try load().lockOverride?.saverExternalChangePreserved, true)
        XCTAssertEqual(saver.writes().count, 1)

        runner.fail([])
        let relaunched = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        _ = try relaunched.status()
        let restored = try relaunched.perform(IdleLockRequest(action: .restore))
        XCTAssertTrue(restored.succeeded)
        XCTAssertTrue(restored.message.contains("Detected external changes"))
        XCTAssertEqual(try saver.observe().delaySeconds, 120)
        XCTAssertEqual(saver.writes().count, 1)
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
        XCTAssertEqual(try runner.readSettings().displayValues, [.battery: 2, .adapter: 10])
    }

    func testSchemaFourWithoutExternalNoticeProvenanceDoesNotGuessReleaseReason() throws {
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        saver.set(120)
        _ = try controller.status()
        let store = StateStore(directory: directory)
        try store.withLock {
            var saved = try store.load()
            saved.lockOverride?.saverExternalChangePreserved = nil
            try store.save(saved)
        }
        let oldRecord = try load()
        XCTAssertEqual(oldRecord.version, 4)
        XCTAssertTrue(oldRecord.lockOverride?.saverReleased == true)
        let relaunched = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        let restored = try relaunched.perform(IdleLockRequest(action: .restore))
        XCTAssertTrue(restored.succeeded)
        XCTAssertFalse(restored.message.contains("Detected external changes"))
        XCTAssertEqual(try saver.observe().delaySeconds, 120)
        XCTAssertEqual(saver.writes().count, 1)
    }

    func testExternalNoticeProvenanceRejectsMalformedOrInconsistentRecords() throws {
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        var active = try XCTUnwrap(load().lockOverride)
        active.saverExternalChangePreserved = true
        XCTAssertThrowsError(try active.validate())
        saver.set(120)
        _ = try controller.status()
        let encoded = try JSONEncoder().encode(try load())
        for invalid: Any in ["true", 1] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var record = try XCTUnwrap(object["lockOverride"] as? [String: Any])
            record["saverExternalChangePreserved"] = invalid
            object["lockOverride"] = record
            XCTAssertThrowsError(try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testContextOnlyChangeRetainsTimerAndPowerOwnershipForReview() throws {
        let original = configuration(.absent, seconds: 1200, dictionary: .registeredDefaults, value: .registeredDefaults)
        saver.setConfiguration(original)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        let baseline = try load()
        let external = configuration(.integer(0), seconds: 0, context: String(repeating: "b", count: 64))
        saver.setConfiguration(external)
        let powerWrites = runner.batches().count
        let status = try controller.status()
        XCTAssertEqual(status.phase, .needsRestore)
        XCTAssertFalse(status.canEnable)
        XCTAssertFalse(status.canRestore)
        XCTAssertTrue(status.message.contains("context changed"))
        XCTAssertTrue(status.message.contains("ownership are retained"))
        XCTAssertEqual(try load(), baseline)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try load().lockOverride?.saverOriginalConfiguration, original)
        XCTAssertEqual(try load().lockOverride?.saverAppliedConfiguration, baseline.lockOverride?.saverAppliedConfiguration)
        XCTAssertFalse(try load().lockOverride?.saverReleased == true)
        XCTAssertFalse(try load().lockOverride?.saverWritePending == true)
        XCTAssertTrue(try load().lockOverride?.dependencies.allSatisfy { !$0.released } == true)
        XCTAssertEqual(try load().profiles, baseline.profiles)
        XCTAssertEqual(try load().displayProfiles, baseline.displayProfiles)
        XCTAssertEqual(runner.batches().count, powerWrites)
        XCTAssertEqual(saver.writes().count, 1)
        for setting in PowerSetting.allCases {
            XCTAssertThrowsError(try service.perform(PowerRequest(action: .restore, setting: setting)))
        }
        let summary = try service.status()
        XCTAssertEqual(summary.idleLock?.phase, .needsRestore)
        XCTAssertFalse(summary.idleLock?.canRestore == true)
        XCTAssertTrue(summary.idleLock?.message.contains("context changed") == true)
        XCTAssertEqual(try saver.observe().configuration, external)
    }

    func testObservedLostTimerOwnershipCannotReviveOnMatchingZero() throws {
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        let owned = try XCTUnwrap(saver.observe().configuration)
        saver.setConfiguration(configuration(.absent, seconds: 0, dictionary: .registeredDefaults, value: .registeredDefaults))
        XCTAssertEqual(try controller.status().phase, .needsRestore)
        saver.setConfiguration(owned)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(saver.writes().count, 1)
        XCTAssertEqual(try saver.observe().configuration, owned)
    }

    func testExternalContextChangeAtRestoreDispatchIsDefinitelyRejected() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let fakeSaver = saver!
        let external = configuration(.integer(0), seconds: 0, context: String(repeating: "b", count: 64))
        saver.beforeApply = { fakeSaver.setConfiguration(external) }
        let writes = runner.batches().count
        let result = try controller.perform(IdleLockRequest(action: .restore))
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(try load().lockOverride?.saverWritePending == true)
        XCTAssertEqual(try load().lockOverride?.saverOriginalConfiguration?.storedValue, .integer(300))
        XCTAssertEqual(runner.batches().count, writes)
        XCTAssertEqual(saver.writes().count, 1)
        saver.beforeApply = nil
        XCTAssertFalse(try controller.status().canRestore)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertFalse(try load().lockOverride?.saverReleased == true)
        XCTAssertTrue(try load().lockOverride?.dependencies.allSatisfy { !$0.released } == true)
        XCTAssertEqual(runner.batches().count, writes)
        XCTAssertEqual(saver.writes().count, 1)
        XCTAssertEqual(try saver.observe().configuration, external)
    }

    func testSuccessfulSetterWithoutFreshTypedReadRemainsUnconfirmed() throws {
        let fakeSaver = saver!
        saver.beforeObserve = {
            if !fakeSaver.writes().isEmpty {
                throw ScreenSaverError.unavailable("Fake fresh read failed")
            }
        }
        let result = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status.phase, .uncertain)
        XCTAssertTrue(try load().lockOverride?.saverWritePending == true)
        XCTAssertNil(try load().lockOverride?.saverAppliedConfiguration)
        saver.beforeObserve = nil
        XCTAssertEqual(try controller.status().phase, .uncertain)
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(saver.writes().count, 1)
    }

    func testCrashPendingTypedIntentCannotBeRecoveredFromStoredZero() throws {
        let original = try XCTUnwrap(saver.observe().configuration)
        let store = StateStore(directory: directory)
        let pending = LockOverride(
            phase: .enabling, dependencies: [
                LockPowerOwnership(setting: .system, profile: .battery, original: 1),
                LockPowerOwnership(setting: .display, profile: .battery, original: 2),
            ], saverOriginal: 300, saverWritePending: true,
            backend: .preferences, saverOriginalConfiguration: original
        )
        try store.withLock { try store.save(SavedState(lockOverride: pending)) }
        saver.set(0)
        let relaunched = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        XCTAssertEqual(try relaunched.status().phase, .uncertain)
        XCTAssertTrue(try relaunched.status().message.contains("CFPreferences"))
        XCTAssertFalse(try relaunched.perform(IdleLockRequest(action: .on)).succeeded)
        XCTAssertFalse(try relaunched.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try load().lockOverride, pending)
        XCTAssertTrue(saver.writes().isEmpty)
        XCTAssertTrue(runner.batches().isEmpty)
    }

    func testInstalledLegacyActiveAndPendingNumericTimersStayQuarantined() throws {
        for pending in [false, true] {
            try seedLegacyTimer(pending: pending)
            let first = try controller.status()
            XCTAssertEqual(first.phase, pending ? .uncertain : .needsRestore)
            XCTAssertFalse(first.canEnable)
            XCTAssertFalse(first.canRestore)
            XCTAssertTrue(first.message.contains("Legacy AppleEvents"))
            let migrated = try load()
            XCTAssertEqual(migrated.version, 4)
            XCTAssertEqual(migrated.lockOverride?.backend, .legacyAppleEvents)
            XCTAssertEqual(migrated.lockOverride?.saverOriginal, 300)
            XCTAssertNil(migrated.lockOverride?.saverOriginalConfiguration)
            for seconds in [0, 300, 700] {
                saver.set(seconds)
                XCTAssertFalse(try controller.status().canRestore)
                XCTAssertFalse(try controller.perform(IdleLockRequest(action: .on)).succeeded)
                XCTAssertFalse(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
                XCTAssertThrowsError(try service.perform(PowerRequest(action: .restore, target: .battery)))
                XCTAssertEqual(try load().lockOverride, migrated.lockOverride)
            }
        }
        XCTAssertTrue(runner.batches().isEmpty)
        XCTAssertTrue(saver.writes().isEmpty)
    }

    func testLegacyPendingRetainsPowerOriginalsEvenAfterExternalChange() throws {
        try seedLegacyTimer(pending: true)
        _ = try controller.status()
        let baseline = try load()
        runner.set(.battery, 8)
        runner.setDisplay(.battery, 7)
        XCTAssertEqual(try service.status().idleLock?.phase, .uncertain)
        XCTAssertEqual(try load(), baseline)
    }

    func testLegacyWithoutTimerOwnershipCanReleaseAcquiredPowerThenEnableFreshLock() throws {
        let store = StateStore(directory: directory)
        runner.set(.battery, 0)
        runner.setDisplay(.battery, 0)
        let saved = LockOverride(phase: .active, dependencies: [
            LockPowerOwnership(setting: .system, profile: .battery, original: 1),
            LockPowerOwnership(setting: .display, profile: .battery, original: nil),
        ], saverOriginal: nil)
        try store.withLock {
            try store.save(SavedState(version: 3, profiles: [
                "battery": ProfileState(override: OverrideState(original: 1, applied: 0))
            ], lockOverride: saved))
        }
        XCTAssertEqual(try controller.status().phase, .needsRestore)
        XCTAssertTrue(try controller.status().canRestore)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
        XCTAssertEqual(try runner.readSettings().displayValues[.battery], 0)
        XCTAssertTrue(saver.writes().isEmpty)
        XCTAssertTrue(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        XCTAssertEqual(try load().lockOverride?.backend, .preferences)
    }

    func testCombinedStatusRejectsSameNumericDelayWithChangedTypedJournal() throws {
        _ = try controller.perform(IdleLockRequest(action: .on))
        let snapshot = try controller.status()
        let store = StateStore(directory: directory)
        let replacement = configuration(.absent, seconds: 300, dictionary: .currentUserAnyHost, value: .currentUserAnyHost)
        let result = try snapshotService(snapshot) {
            try store.withLock {
                var state = try store.load()
                let saved = try XCTUnwrap(state.lockOverride)
                state.lockOverride = LockOverride(
                    phase: saved.phase, dependencies: saved.dependencies, saverOriginal: saved.saverOriginal,
                    saverApplied: true, backend: .preferences,
                    saverOriginalConfiguration: replacement, saverAppliedConfiguration: saved.saverAppliedConfiguration
                )
                try store.save(state)
            }
        }.status()
        XCTAssertEqual(result.idleLock?.phase, .needsRestore)
        XCTAssertFalse(result.idleLock?.canRestore == true)
        XCTAssertEqual(result.idleLock?.originalSaverDelaySeconds, snapshot.originalSaverDelaySeconds)
        XCTAssertNotEqual(result.idleLock?.journalFingerprint, snapshot.journalFingerprint)
    }

    func testSyntheticAndMalformedConfigurationsCannotEnable() throws {
        saver.omitConfiguration = true
        XCTAssertFalse(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        saver.omitConfiguration = false
        for invalid in [
            configuration(.integer(-1), seconds: -1),
            configuration(.integer(Int(Int32.max) + 1), seconds: Int(Int32.max) + 1),
            configuration(.integer(300), seconds: 301),
            configuration(.integer(300), seconds: 300, context: String(repeating: "A", count: 64)),
            configuration(.integer(300), seconds: 300, context: "short"),
            configuration(.absent, seconds: 300),
        ] {
            saver.setConfiguration(invalid)
            XCTAssertFalse(try controller.status().canEnable)
            XCTAssertFalse(try controller.perform(IdleLockRequest(action: .on)).succeeded)
        }
        XCTAssertTrue(saver.writes().isEmpty)
        XCTAssertTrue(runner.batches().isEmpty)
        XCTAssertNil(try load().lockOverride)
    }

    func testStoredValueCodableRetainsAbsenceAndValidatesIntegers() throws {
        for value in [ScreenSaverStoredValue.absent, .integer(0), .integer(300), .integer(Int(Int32.max))] {
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(ScreenSaverStoredValue.self, from: encoded), value)
        }
        for raw in [
            #"{"integer":{"_0":-1}}"#, #"{"integer":{"_0":2147483648}}"#,
            #"{"integer":{"_0":true}}"#, #"{"integer":{"_0":2.5}}"#, #"{"integer":{"_0":"300"}}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(ScreenSaverStoredValue.self, from: Data(raw.utf8)))
        }
    }

    func testInvalidTypedJournalsCannotInventOrChangePreferenceOwnership() throws {
        let original = configuration(.absent, seconds: 1200, dictionary: .registeredDefaults, value: .registeredDefaults)
        let dependencies = [
            LockPowerOwnership(setting: .system, profile: .battery, original: 1),
            LockPowerOwnership(setting: .display, profile: .battery, original: 2),
        ]
        let pending = LockOverride(
            phase: .enabling, dependencies: dependencies, saverOriginal: 1200,
            backend: .preferences, saverOriginalConfiguration: original
        )
        XCTAssertNoThrow(try SavedState(lockOverride: pending).validate())
        XCTAssertThrowsError(try SavedState(version: 3, lockOverride: pending).validate())
        XCTAssertThrowsError(try LockOverride(
            phase: .enabling, dependencies: dependencies, saverOriginal: 1200,
            backend: .preferences
        ).validate())
        XCTAssertThrowsError(try LockOverride(
            phase: .active, dependencies: dependencies, saverOriginal: 1200,
            saverApplied: true, backend: .preferences, saverOriginalConfiguration: original,
            saverAppliedConfiguration: configuration(.integer(0), seconds: 0, context: String(repeating: "b", count: 64))
        ).validate())
        XCTAssertThrowsError(try LockOverride(
            phase: .enabling, dependencies: dependencies, saverOriginal: 1200,
            backend: .legacyAppleEvents, saverOriginalConfiguration: original
        ).validate())
        XCTAssertThrowsError(try LockOverride(
            phase: .enabling, dependencies: dependencies, saverOriginal: 1200,
            backend: .preferences, recordVersion: 2, saverOriginalConfiguration: original
        ).validate())
    }

    func testConfiguredMessagesDiscloseDelayedAdoptionAndRestore() throws {
        let enabled = try controller.perform(IdleLockRequest(action: .on))
        XCTAssertTrue(enabled.message.contains("configured"))
        XCTAssertTrue(enabled.status.message.contains("may adopt or restore"))
        XCTAssertTrue(enabled.message.contains("production API"))
        let restored = try controller.perform(IdleLockRequest(action: .restore))
        XCTAssertTrue(restored.message.contains("settings saved"))
        XCTAssertTrue(restored.message.contains("may adopt or restore"))
    }

    private func configuration(
        _ stored: ScreenSaverStoredValue, seconds: Int,
        dictionary: ScreenSaverPreferenceScope = .currentUserCurrentHost,
        value: ScreenSaverPreferenceScope = .currentUserCurrentHost,
        context: String = String(repeating: "a", count: 64)
    ) -> ScreenSaverConfiguration {
        ScreenSaverConfiguration(
            storedValue: stored, effectiveSeconds: seconds,
            dictionarySource: dictionary, valueSource: value, contextFingerprint: context
        )
    }

    private func seedLegacyTimer(pending: Bool) throws {
        let raw = """
        {"version":3,"profiles":{"battery":{"override":{"original":1,"applied":0}}},
        "displayProfiles":{"battery":{"override":{"original":2,"applied":0}}},
        "lockOverride":{"phase":"\(pending ? "enabling" : "active")",
        "dependencies":[{"setting":"system","profile":"battery","original":1,"released":false},
        {"setting":"display","profile":"battery","original":2,"released":false}],
        "saverOriginal":300,"saverApplied":\(!pending),"saverWritePending":\(pending),"saverReleased":false}}
        """
        let store = StateStore(directory: directory)
        try store.withLock {
            let file = directory.appendingPathComponent("state.json")
            try Data(raw.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        runner.set(.battery, 0)
        runner.setDisplay(.battery, 0)
    }

    private func load() throws -> SavedState {
        let store = StateStore(directory: directory)
        return try store.withLock { try store.load() }
    }

    private func snapshotService(_ snapshot: IdleLockStatus, afterRead: @escaping @Sendable () throws -> Void) -> HearthService {
        HearthService(
            runner: runner, stateDirectory: directory,
            idleLockController: SnapshotLockController(snapshot: snapshot, afterRead: afterRead)
        )
    }
}
