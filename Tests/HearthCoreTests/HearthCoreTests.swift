import Darwin
import Foundation
import XCTest
@testable import HearthCore

final class FakeRunner: PowerCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PowerProfile: Int]
    private var calls: [[PowerChange]] = []
    private var failures: Set<PowerProfile> = []
    private var skipped: Set<PowerProfile> = []
    private var failReadAfterApply = false
    private var didApply = false
    private var unconfirmed = false
    private var availability = HelperAvailability.ready
    var beforeApply: (@Sendable () throws -> Void)?

    init(_ values: [PowerProfile: Int] = [.battery: 1, .adapter: 0]) { self.values = values }

    func helperAvailability() -> HelperAvailability { lock.withLock { availability } }

    func readSettings() throws -> PowerSettings {
        try lock.withLock {
            if failReadAfterApply && didApply { throw HearthError.command("Read-back failed") }
            return PowerSettings(values: values, currentSource: "Battery")
        }
    }

    func apply(_ changes: [PowerChange]) throws -> [CommandOutcome] {
        try beforeApply?()
        return lock.withLock {
            calls.append(changes)
            didApply = true
            return changes.map { change in
                if skipped.contains(change.profile) {
                    return CommandOutcome(profile: change.profile, exitCode: 75, message: "Observed value changed externally.", didExecute: false)
                }
                if !failures.contains(change.profile) { values[change.profile] = change.minutes }
                return CommandOutcome(
                    profile: change.profile,
                    exitCode: unconfirmed ? nil : (failures.contains(change.profile) ? 1 : 0),
                    message: failures.contains(change.profile) ? "Helper command failed" : ""
                )
            }
        }
    }

    func set(_ profile: PowerProfile, _ value: Int?) { lock.withLock { values[profile] = value } }
    func fail(_ profiles: Set<PowerProfile>) { lock.withLock { failures = profiles } }
    func skip(_ profiles: Set<PowerProfile>) { lock.withLock { skipped = profiles } }
    func failReadback() { lock.withLock { failReadAfterApply = true } }
    func recoverReads() { lock.withLock { failReadAfterApply = false } }
    func omitConfirmation() { lock.withLock { unconfirmed = true } }
    func batches() -> [[PowerChange]] { lock.withLock { calls } }
    func setAvailability(_ state: HelperState) {
        lock.withLock {
            availability = HelperAvailability(state: state, message: "Explicit Hearth setup/repair is required.")
        }
    }
}

final class HearthCoreTests: XCTestCase {
    private var directory: URL!
    private var runner: FakeRunner!
    private var service: HearthService!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-core-test-\(UUID())")
        runner = FakeRunner()
        service = HearthService(runner: runner, stateDirectory: directory)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testDefaultOnDoesNotInventAlreadyZeroAdapterBaseline() throws {
        let result = try service.perform(PowerRequest(action: .on))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(runner.batches().count, 1)
        XCTAssertEqual(runner.batches()[0].map(\.profile), [.battery])
        XCTAssertEqual(result.status.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
        XCTAssertNil(result.status.profiles.first { $0.profile == .adapter }?.originalMinutes)
        let restored = try service.perform(PowerRequest(action: .restore))
        XCTAssertTrue(restored.succeeded)
        XCTAssertEqual(try runner.readSettings().values, [.battery: 1, .adapter: 0])
        XCTAssertFalse(restored.status.hasManagedChanges)
    }

    func testRepeatedOnIsIdempotentAcrossServiceInstances() throws {
        _ = try service.perform(PowerRequest(action: .on))
        let second = HearthService(runner: runner, stateDirectory: directory)
        let result = try second.perform(PowerRequest(action: .on))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(runner.batches().count, 1)
        XCTAssertEqual(result.status.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
    }

    func testBothChangesUseOneBatchAndIndependentBaselines() throws {
        runner.set(.adapter, 15)
        _ = try service.perform(PowerRequest(action: .on))
        XCTAssertEqual(runner.batches().count, 1)
        XCTAssertEqual(runner.batches()[0].count, 2)
        XCTAssertEqual(runner.batches()[0].map(\.expectedMinutes), [1, 15])
        _ = try service.perform(PowerRequest(action: .restore, target: .adapter))
        XCTAssertEqual(try runner.readSettings().values, [.battery: 0, .adapter: 15])
        XCTAssertTrue(try service.status().hasManagedChanges)
        _ = try service.perform(PowerRequest(action: .restore, target: .battery))
        XCTAssertEqual(try runner.readSettings().values, [.battery: 1, .adapter: 15])
    }

    func testExplicitTimeoutBecomesNewSetting() throws {
        _ = try service.perform(PowerRequest(action: .on))
        let result = try service.perform(PowerRequest(action: .sleep, target: .battery, minutes: 9))
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.status.hasManagedChanges)
        _ = try service.perform(PowerRequest(action: .restore))
        XCTAssertEqual(try runner.readSettings().values[.battery], 9)
    }

    func testExplicitSleepWorksForUnmanagedNeverProfile() throws {
        _ = try service.perform(PowerRequest(action: .sleep, target: .adapter, minutes: 12))
        XCTAssertEqual(try runner.readSettings().values[.adapter], 12)
        XCTAssertFalse(try service.status().hasManagedChanges)
    }

    func testExternalChangePreservedInsteadOfStaleRestore() throws {
        _ = try service.perform(PowerRequest(action: .on))
        runner.set(.battery, 7)
        let result = try service.perform(PowerRequest(action: .restore))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.outcomes.first { $0.profile == .battery }?.kind, .preserved)
        XCTAssertEqual(try runner.readSettings().values[.battery], 7)
        XCTAssertFalse(result.status.hasManagedChanges)
        XCTAssertEqual(runner.batches().count, 1)
    }

    func testExternalChangePreservedDuringRepeatedOn() throws {
        _ = try service.perform(PowerRequest(action: .on))
        runner.set(.battery, 8)
        let result = try service.perform(PowerRequest(action: .on))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(try runner.readSettings().values[.battery], 8)
    }

    func testHelperSkippedExternalZeroDoesNotInventAnOverride() throws {
        let fake = runner!
        runner.beforeApply = { fake.set(.battery, 0) }
        runner.skip([.battery])
        let result = try service.perform(PowerRequest(action: .on, target: .battery))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.outcomes.first?.kind, .preserved)
        XCTAssertEqual(result.status.profiles.first { $0.profile == .battery }?.actualMinutes, 0)
        XCTAssertFalse(result.status.hasManagedChanges)
        XCTAssertTrue(try load().profiles.isEmpty)
    }

    func testHelperSkippedRestoreKeepsExistingBaselineWhenValueStillMatchesOverride() throws {
        _ = try service.perform(PowerRequest(action: .on, target: .battery))
        runner.skip([.battery])
        let result = try service.perform(PowerRequest(action: .restore, target: .battery))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.status.hasManagedChanges)
        XCTAssertEqual(result.status.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
    }

    func testPartialActivationRetainsOnlySuccessfulBaseline() throws {
        runner.set(.adapter, 10)
        runner.fail([.adapter])
        let result = try service.perform(PowerRequest(action: .on))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
        XCTAssertNil(result.status.profiles.first { $0.profile == .adapter }?.originalMinutes)
        XCTAssertEqual(try runner.readSettings().values, [.battery: 0, .adapter: 10])
    }

    func testFailedRestoreRetainsBaseline() throws {
        _ = try service.perform(PowerRequest(action: .on))
        runner.fail([.battery])
        let result = try service.perform(PowerRequest(action: .restore))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
        runner.fail([])
        XCTAssertTrue(try service.perform(PowerRequest(action: .restore)).succeeded)
    }

    func testFailedExplicitSleepRetainsOverride() throws {
        _ = try service.perform(PowerRequest(action: .on))
        runner.fail([.battery])
        let result = try service.perform(PowerRequest(action: .sleep, target: .battery, minutes: 5))
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.status.hasManagedChanges)
    }

    func testReadbackFailureKeepsPendingJournalForRecovery() throws {
        runner.failReadback()
        XCTAssertThrowsError(try service.perform(PowerRequest(action: .on)))
        let state = try load()
        XCTAssertEqual(state.profiles["battery"]?.pending?.original, 1)
        XCTAssertEqual(state.profiles["battery"]?.pending?.applied, 0)
        runner.recoverReads()
        let status = try service.status()
        XCTAssertEqual(status.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
        XCTAssertNil(try load().profiles["battery"]?.pending)
    }

    func testJournalExistsBeforeHelperRequestAndLocksOtherClients() throws {
        let testDirectory = directory!
        let testRunner = runner!
        runner.beforeApply = {
            let data = try Data(contentsOf: testDirectory.appendingPathComponent("state.json"))
            let state = try JSONDecoder().decode(SavedState.self, from: data)
            XCTAssertEqual(state.profiles["battery"]?.pending?.action, .on)
            XCTAssertThrowsError(try HearthService(runner: testRunner, stateDirectory: testDirectory).status()) { error in
                XCTAssertEqual(error.localizedDescription, HearthError.busy.localizedDescription)
            }
        }
        _ = try service.perform(PowerRequest(action: .on))
    }

    func testSurvivingCommandRetainsLockAfterCallerClosesItsDescriptor() throws {
        let store = StateStore(directory: directory)
        let ready = directory.appendingPathComponent("worker-ready")
        let completed = DispatchSemaphore(value: 0)
        let arguments = ["-c", "/usr/bin/touch \"$1\"; exec /bin/sleep 1", "hearth-lock-test", ready.path]
        try store.withLockDescriptor { descriptor in
            let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            DispatchQueue.global().async {
                defer { completed.signal() }
                do {
                    let result = try ProcessExecutor().run(
                        "/bin/sh",
                        arguments,
                        standardInput: input
                    )
                    XCTAssertEqual(result.exitCode, 0)
                } catch {
                    XCTFail("Harmless worker failed: \(error)")
                }
            }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: ready.path) {
                guard Date() < deadline else {
                    XCTFail("Worker did not start.")
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        // Closing the initiating descriptor models the lock's behavior after a caller crash.
        XCTAssertThrowsError(try service.status()) { error in
            XCTAssertEqual(error.localizedDescription, HearthError.busy.localizedDescription)
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertNoThrow(try service.status())
    }

    func testUnavailableHelperShowsActualSettingsAndBlocksEveryAction() throws {
        for state in [HelperState.setupRequired, .incompatible, .unavailable] {
            runner.setAvailability(state)
            let status = try service.status()
            XCTAssertEqual(status.helper.state, state)
            XCTAssertFalse(status.helper.isReady)
            XCTAssertEqual(status.profiles.first { $0.profile == .battery }?.actualMinutes, 1)
            for request in [
                try PowerRequest(action: .on),
                try PowerRequest(action: .restore),
                try PowerRequest(action: .sleep, minutes: 10),
            ] {
                XCTAssertThrowsError(try service.perform(request)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("setup/repair"))
                }
            }
        }
        XCTAssertTrue(runner.batches().isEmpty)
        XCTAssertTrue(try load().profiles.isEmpty)
    }

    func testLostHelperDoesNotDiscardExistingRestoreState() throws {
        _ = try service.perform(PowerRequest(action: .on))
        runner.setAvailability(.unavailable)
        XCTAssertThrowsError(try service.perform(PowerRequest(action: .restore)))
        let status = try service.status()
        XCTAssertTrue(status.hasManagedChanges)
        XCTAssertEqual(status.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
        XCTAssertEqual(status.profiles.first { $0.profile == .battery }?.actualMinutes, 0)
        XCTAssertEqual(runner.batches().count, 1)
    }

    func testIndeterminateHelperResponseKeepsJournalUntilLaterRecovery() throws {
        runner.beforeApply = {
            throw HearthError.indeterminateHelper("Fake timed-out helper request may still be running.")
        }
        XCTAssertThrowsError(try service.perform(PowerRequest(action: .on)))
        XCTAssertEqual(try load().profiles["battery"]?.pending?.original, 1)
        XCTAssertEqual(try load().profiles["battery"]?.pending?.applied, 0)
        runner.set(.battery, 0)
        let recovered = try service.status()
        XCTAssertEqual(recovered.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
        XCTAssertNil(try load().profiles["battery"]?.pending)
    }

    func testDirectSystemWritesWithoutJournalLeaseFailBeforeIPC() throws {
        XCTAssertThrowsError(try SystemPowerRunner().apply([PowerChange(profile: .battery, minutes: 0)])) { error in
            XCTAssertTrue(error.localizedDescription.contains("journal lock lease"))
        }
    }

    func testInterruptedActivationBeforeWriteDropsUnappliedBaseline() throws {
        try seed(ProfileState(pending: PendingOperation(action: .on, original: 1, applied: 0)))
        XCTAssertFalse(try service.status().hasManagedChanges)
        XCTAssertTrue(try load().profiles.isEmpty)
    }

    func testInterruptedActivationAfterWriteRecoversBaseline() throws {
        runner.set(.battery, 0)
        try seed(ProfileState(pending: PendingOperation(action: .on, original: 1, applied: 0)))
        XCTAssertEqual(try service.status().profiles.first { $0.profile == .battery }?.originalMinutes, 1)
        _ = try service.perform(PowerRequest(action: .restore))
        XCTAssertEqual(try runner.readSettings().values[.battery], 1)
    }

    func testInterruptedRestoreAfterWriteClearsBaseline() throws {
        try seed(ProfileState(
            override: OverrideState(original: 1, applied: 0),
            pending: PendingOperation(action: .restore, original: 0, applied: 1)
        ))
        XCTAssertFalse(try service.status().hasManagedChanges)
    }

    func testInterruptedRestoreBeforeWriteRetainsBaseline() throws {
        runner.set(.battery, 0)
        try seed(ProfileState(
            override: OverrideState(original: 1, applied: 0),
            pending: PendingOperation(action: .restore, original: 0, applied: 1)
        ))
        XCTAssertTrue(try service.status().hasManagedChanges)
    }

    func testInterruptedExplicitTimeoutAfterWriteClearsOverride() throws {
        runner.set(.battery, 12)
        try seed(ProfileState(
            override: OverrideState(original: 1, applied: 0),
            pending: PendingOperation(action: .sleep, original: 0, applied: 12)
        ))
        XCTAssertFalse(try service.status().hasManagedChanges)
    }

    func testInterruptedUnmanagedTimeoutDoesNotInventBaseline() throws {
        try seed(ProfileState(pending: PendingOperation(action: .sleep, original: 1, applied: 12)))
        XCTAssertFalse(try service.status().hasManagedChanges)
        XCTAssertTrue(try load().profiles.isEmpty)
    }

    func testInterruptedOperationExternalChangeIsPreserved() throws {
        runner.set(.battery, 14)
        try seed(ProfileState(pending: PendingOperation(action: .on, original: 1, applied: 0)))
        let status = try service.status()
        XCTAssertFalse(status.hasManagedChanges)
        XCTAssertFalse(status.warnings.isEmpty)
        XCTAssertEqual(try runner.readSettings().values[.battery], 14)
    }

    func testUnavailableProfileRetainsState() throws {
        runner.set(.battery, nil)
        try seed(ProfileState(override: OverrideState(original: 1, applied: 0)))
        let status = try service.status()
        XCTAssertTrue(status.hasManagedChanges)
        XCTAssertFalse(status.warnings.isEmpty)
        XCTAssertFalse(try service.perform(PowerRequest(action: .restore, target: .battery)).succeeded)
    }

    func testMissingStateNeverGuessesRestoreValues() throws {
        runner.set(.battery, 0)
        XCTAssertTrue(try service.perform(PowerRequest(action: .restore)).succeeded)
        XCTAssertTrue(runner.batches().isEmpty)
        XCTAssertFalse(try service.status().hasManagedChanges)
    }

    func testCorruptStateShowsActualValuesButBlocksWrites() throws {
        _ = try service.status()
        let file = directory.appendingPathComponent("state.json")
        try Data("damaged".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let status = try service.status()
        XCTAssertEqual(status.profiles.first { $0.profile == .battery }?.actualMinutes, 1)
        XCTAssertFalse(status.warnings.isEmpty)
        XCTAssertThrowsError(try service.perform(PowerRequest(action: .on)))
        XCTAssertTrue(runner.batches().isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "damaged")
    }

    func testStateVersionAndValuesAreValidated() throws {
        XCTAssertThrowsError(try SavedState(version: 2).validate())
        XCTAssertThrowsError(try SavedState(profiles: [
            "battery": ProfileState(override: OverrideState(original: -1, applied: 0)),
        ]).validate())
        XCTAssertThrowsError(try SavedState(profiles: ["ups": ProfileState()]).validate())
    }

    func testPrivateAtomicStateFiles() throws {
        _ = try service.perform(PowerRequest(action: .on))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        for file in ["state.json", "state.lock"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["state.json", "state.lock"])
    }

    func testSymlinkStateIsNotFollowedOrOverwritten() throws {
        _ = try service.status()
        let path = directory.appendingPathComponent("state.json")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: directory.appendingPathComponent("unrelated"))
        XCTAssertThrowsError(try service.perform(PowerRequest(action: .on)))
        XCTAssertFalse(try service.status().warnings.isEmpty)
        XCTAssertTrue(runner.batches().isEmpty)
    }

    func testReportedFailureDespiteAppliedValueKeepsTruthfulOwnership() throws {
        runner.omitConfirmation()
        let result = try service.perform(PowerRequest(action: .on))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status.profiles.first { $0.profile == .battery }?.actualMinutes, 0)
        XCTAssertTrue(result.status.hasManagedChanges)
    }

    func testRequestAndPowerChangeValidation() throws {
        for minutes in [-1, 0, Int.max] {
            XCTAssertThrowsError(try PowerRequest(action: .sleep, minutes: minutes))
        }
        XCTAssertThrowsError(try PowerRequest(action: .sleep))
        XCTAssertThrowsError(try PowerRequest(action: .on, minutes: 10))
        XCTAssertThrowsError(try PowerChange(profile: .battery, minutes: -1))
        let decoded = try JSONDecoder().decode(PowerRequest.self, from: Data(#"{"action":"sleep","target":"both","minutes":0}"#.utf8))
        XCTAssertThrowsError(try service.perform(decoded))
        XCTAssertTrue(runner.batches().isEmpty)
    }

    private func load() throws -> SavedState {
        let store = StateStore(directory: directory)
        return try store.withLock { try store.load() }
    }

    private func seed(_ record: ProfileState) throws {
        let store = StateStore(directory: directory)
        try store.withLock { try store.save(SavedState(profiles: ["battery": record])) }
    }
}

final class PowerParserTests: XCTestCase {
    func testExactSleepAndSectionsIncludingAnnotationsAndUPS() throws {
        let input = """
        Battery Power:
         displaysleep 2
         Sleep On Power Button 1
         sleep 1 (sleep prevented by example)
         lowpowermode 1
        AC Power:
         displaysleep 10
         sleep 0
        UPS Power:
         sleep 77
        """
        let settings = try PMSetParser().parse(custom: input, battery: "Now drawing from 'Battery Power'\n")
        XCTAssertEqual(settings.values, [.battery: 1, .adapter: 0])
        XCTAssertEqual(settings.currentSource, "Battery")
    }

    func testDesktopAdapterOnly() throws {
        let settings = try PMSetParser().parse(custom: "AC Power:\n sleep 20", battery: "Now drawing from 'AC Power'")
        XCTAssertEqual(settings.values, [.adapter: 20])
        XCTAssertEqual(settings.currentSource, "Power adapter")
    }

    func testMalformedAndAmbiguousOutputsFailClosed() {
        for input in [
            "", "Battery Power:\n displaysleep 1", "Battery Power:\n sleep nope",
            "Battery Power:\n sleep -1", "AC Power:\n sleep 1\n sleep 2",
            "Battery Power:\n sleep 1\nAC Power:\n displaysleep 1",
            "AC Power:\n sleep 1\nAC Power:\n sleep 2",
        ] {
            XCTAssertThrowsError(try PMSetParser().parse(custom: input, battery: ""), input)
        }
    }

}
