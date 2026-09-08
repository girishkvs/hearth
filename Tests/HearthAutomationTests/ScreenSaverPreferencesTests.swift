import Foundation
import HearthCore
import XCTest
@testable import HearthAutomation

final class ScreenSaverPreferencesTests: XCTestCase {
    func testAbsentTimerUsesInstalledResourceWithoutInventingStoredValue() throws {
        let store = FakeScreenSaverPreferences()
        let observed = try controller(store).observe()
        XCTAssertEqual(observed.delaySeconds, 1234)
        XCTAssertEqual(observed.configuration?.storedValue, .absent)
        XCTAssertEqual(observed.configuration?.dictionarySource, .registeredDefaults)
        XCTAssertEqual(observed.configuration?.valueSource, .registeredDefaults)
        XCTAssertEqual(observed.availability, .ready)
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(store.synchronizations, 0)
        XCTAssertTrue(observed.message.contains("not an immediate runtime-state observation"))
    }

    func testFirstNonemptyDictionaryWinsEvenWithoutTimerKey() throws {
        let store = FakeScreenSaverPreferences()
        store.domains[.currentUserCurrentHost] = ["moduleName": "synthetic"]
        store.domains[.currentUserAnyHost] = ["idleTime": 300]
        let observed = try controller(store).observe()
        XCTAssertEqual(observed.delaySeconds, 1234)
        XCTAssertEqual(observed.configuration?.dictionarySource, .currentUserCurrentHost)
        XCTAssertEqual(observed.configuration?.valueSource, .registeredDefaults)
        XCTAssertEqual(observed.configuration?.storedValue, .absent)
    }

    func testFallbackOrderIsDictionaryScopedAndExcludesAnyUserCurrentHost() throws {
        let store = FakeScreenSaverPreferences()
        store.domains[.anyUserCurrentHost] = ["idleTime": 5]
        store.domains[.anyUserAnyHost] = ["idleTime": 800]
        XCTAssertEqual(try controller(store).observe().delaySeconds, 800)
        store.domains[.currentUserAnyHost] = ["idleTime": 400]
        XCTAssertEqual(try controller(store).observe().configuration?.valueSource, .currentUserAnyHost)
        XCTAssertEqual(try controller(store).observe().delaySeconds, 400)
        store.domains[.currentUserAnyHost] = ["moduleName": "synthetic"]
        XCTAssertEqual(try controller(store).observe().delaySeconds, 1234)
        store.domains[.currentUserCurrentHost] = ["idleTime": 200]
        XCTAssertEqual(try controller(store).observe().delaySeconds, 200)
    }

    func testCreatingAndRemovingOnlyOwnedKeyRestoresExactAbsence() throws {
        let store = FakeScreenSaverPreferences()
        let subject = controller(store)
        let original = try configuration(subject)
        try subject.apply(value: .integer(0), expected: original)
        let applied = try configuration(subject)
        XCTAssertEqual(applied.storedValue, .integer(0))
        XCTAssertEqual(applied.effectiveSeconds, 0)
        XCTAssertEqual(applied.dictionarySource, .currentUserCurrentHost)
        XCTAssertEqual(applied.contextFingerprint, original.contextFingerprint)
        try subject.apply(value: original.storedValue, expected: applied)
        XCTAssertEqual(try configuration(subject), original)
        XCTAssertEqual(store.writes, [.integer(0), .absent])
        XCTAssertEqual(store.synchronizations, 2)
        XCTAssertNil(store.domains[.currentUserCurrentHost]?["idleTime"])
    }

    func testExistingIntegerIsRestoredAndOtherValuesStayUntouched() throws {
        let store = FakeScreenSaverPreferences()
        store.domains[.currentUserCurrentHost] = [
            "idleTime": 600, "lastDelayTime": 700, "askForPassword": true,
            "askForPasswordDelay": 15, "moduleName": "synthetic",
        ]
        let otherBefore = try protectedFingerprint(store)
        let subject = controller(store)
        let original = try configuration(subject)
        try subject.apply(value: .integer(0), expected: original)
        try subject.apply(value: original.storedValue, expected: configuration(subject))
        XCTAssertEqual(try configuration(subject), original)
        XCTAssertEqual(store.writes, [.integer(0), .integer(600)])
        XCTAssertEqual(try protectedFingerprint(store), otherBefore)
    }

    func testAbsentPrimaryCanBorrowOrAcquireFallbackTimerWithoutWritingFallback() throws {
        let store = FakeScreenSaverPreferences()
        store.domains[.currentUserAnyHost] = ["idleTime": 500]
        let subject = controller(store)
        let original = try configuration(subject)
        XCTAssertEqual(original.storedValue, .absent)
        XCTAssertEqual(original.valueSource, .currentUserAnyHost)
        try subject.apply(value: .integer(0), expected: original)
        try subject.apply(value: .absent, expected: configuration(subject))
        XCTAssertEqual(try configuration(subject), original)
        XCTAssertEqual(store.domains[.currentUserAnyHost]?["idleTime"] as? Int, 500)
    }

    func testShadowingFallbackSecurityOrUnrelatedValuesIsRejectedBeforeAnyWrite() throws {
        for key in ["askForPassword", "askForPasswordDelay", "moduleName", "lastDelayTime"] {
            let store = FakeScreenSaverPreferences()
            store.domains[.currentUserAnyHost] = ["idleTime": 500, key: "synthetic preserved value"]
            let subject = controller(store)
            let observation = try subject.observe()
            XCTAssertEqual(observation.availability, .unavailable)
            XCTAssertEqual(observation.delaySeconds, 500)
            assertRejected { try subject.apply(value: .integer(0), expected: XCTUnwrap(observation.configuration)) }
            XCTAssertTrue(store.writes.isEmpty)
            XCTAssertEqual(store.synchronizations, 0)
        }
    }

    func testFallbackMatchingRegisteredOtherValuesDoesNotCreateFalseConflict() throws {
        let store = FakeScreenSaverPreferences()
        store.resource = ScreenSaverEngineDefaults(
            values: ["idleTime": 1234, "syntheticOption": true], resourceData: Data("resource with option".utf8)
        )
        store.domains[.currentUserAnyHost] = ["idleTime": 500, "syntheticOption": true]
        let subject = controller(store)
        let original = try configuration(subject)
        XCTAssertEqual(try subject.observe().availability, .ready)
        try subject.apply(value: .integer(0), expected: original)
        try subject.apply(value: .absent, expected: configuration(subject))
        XCTAssertEqual(try configuration(subject), original)
    }

    func testNonemptyPrimaryDoesNotShadowFallbackWhenAddingTimer() throws {
        let store = FakeScreenSaverPreferences()
        store.domains[.currentUserCurrentHost] = ["moduleName": "primary"]
        store.domains[.currentUserAnyHost] = ["askForPassword": true, "idleTime": 500]
        let subject = controller(store)
        let original = try configuration(subject)
        try subject.apply(value: .integer(0), expected: original)
        try subject.apply(value: .absent, expected: configuration(subject))
        XCTAssertEqual(try configuration(subject), original)
        XCTAssertEqual(store.domains[.currentUserCurrentHost]?.count, 1)
    }

    func testRemovingTimerCannotExposeDifferentUnrelatedFallbackValues() throws {
        let store = FakeScreenSaverPreferences()
        store.domains[.currentUserCurrentHost] = ["idleTime": 0]
        store.domains[.currentUserAnyHost] = ["idleTime": 500, "askForPassword": true]
        let subject = controller(store)
        let expected = try configuration(subject)
        assertRejected { try subject.apply(value: .absent, expected: expected) }
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(store.synchronizations, 0)
    }

    func testZeroAlreadyStoredIsIdempotentWithoutSynchronization() throws {
        let store = FakeScreenSaverPreferences()
        store.domains[.currentUserCurrentHost] = ["idleTime": 0]
        let subject = controller(store)
        try subject.apply(value: .integer(0), expected: configuration(subject))
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(store.synchronizations, 0)
    }

    func testMalformedExplicitTimerIsNeverCoerced() {
        for value: Any in [true, NSNumber(value: 300.0), "300", -1, Int64(Int32.max) + 1, ["unexpected": 1]] {
            let store = FakeScreenSaverPreferences()
            store.domains[.currentUserCurrentHost] = ["idleTime": value]
            XCTAssertThrowsError(try controller(store).observe())
            XCTAssertTrue(store.writes.isEmpty)
        }
    }

    func testMissingMalformedAndZeroRegisteredDefaultsAreHandledExplicitly() throws {
        for value: Any? in [nil, true, NSNumber(value: 1200.0), "1200", -1] {
            let store = FakeScreenSaverPreferences()
            store.resource = ScreenSaverEngineDefaults(
                values: value.map { ["idleTime": $0] } ?? [:], resourceData: Data("malformed resource".utf8)
            )
            XCTAssertThrowsError(try controller(store).observe())
        }
        let store = FakeScreenSaverPreferences()
        store.resource = ScreenSaverEngineDefaults(values: ["idleTime": 0], resourceData: Data("explicit resource zero".utf8))
        XCTAssertEqual(try controller(store).observe().delaySeconds, 0)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testMaximumIntegerRemainsExact() throws {
        let store = FakeScreenSaverPreferences()
        store.domains[.currentUserCurrentHost] = ["idleTime": Int32.max]
        XCTAssertEqual(try controller(store).observe().configuration?.storedValue, .integer(Int(Int32.max)))
    }

    func testUnavailableResourceDoesNotGuessFromStoredOrDefaultValues() {
        let store = FakeScreenSaverPreferences()
        store.resourceFails = true
        store.domains[.currentUserCurrentHost] = ["idleTime": 300]
        XCTAssertThrowsError(try controller(store).observe())
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testExactKeyAndWholeDictionaryDisagreementFailsClosed() {
        let store = FakeScreenSaverPreferences()
        store.domains[.currentUserCurrentHost] = ["idleTime": 300]
        store.exactReadOverride = { 400 }
        XCTAssertThrowsError(try controller(store).observe())
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testExternalPresenceOrContextChangesRejectExpectedSnapshot() throws {
        for change: (FakeScreenSaverPreferences) -> Void in [
            { $0.domains[.currentUserCurrentHost]?["idleTime"] = 600 },
            { $0.domains[.currentUserCurrentHost]?["moduleName"] = "changed" },
            { $0.domains[.currentUserAnyHost]?["idleTime"] = 700 },
            { $0.domains[.anyUserCurrentHost]?["askForPassword"] = true },
            { $0.domains[.anyUserAnyHost]?["moduleName"] = "changed" },
            { $0.resource = ScreenSaverEngineDefaults(values: ["idleTime": 1234], resourceData: Data("updated resource".utf8)) },
            { $0.resource = ScreenSaverEngineDefaults(values: $0.resource.values, resourceData: $0.resource.resourceData, runtimeIdentity: "updated OS build") },
        ] {
            let store = FakeScreenSaverPreferences()
            let subject = controller(store)
            let original = try configuration(subject)
            change(store)
            assertRejected { try subject.apply(value: .integer(0), expected: original) }
            XCTAssertTrue(store.writes.isEmpty)
            XCTAssertEqual(store.synchronizations, 0)
        }
    }

    func testPolicyRestrictionsAndReadFailuresRetainConfigurationButForbidWrites() throws {
        for policy in [FakeTimerPolicy(.managed), FakeTimerPolicy(.unavailable), FakeTimerPolicy(failing: true)] {
            let store = FakeScreenSaverPreferences()
            let subject = SystemScreenSaverController(preferences: store, policy: policy)
            let observed = try subject.observe()
            XCTAssertNotEqual(observed.availability, .ready)
            XCTAssertNotEqual(observed.availability, .setupRequired)
            XCTAssertEqual(observed.configuration?.storedValue, .absent)
            XCTAssertEqual(observed.delaySeconds, 1234)
            assertRejected { try subject.apply(value: .integer(0), expected: XCTUnwrap(observed.configuration)) }
            XCTAssertTrue(store.writes.isEmpty)
        }
    }

    func testPolicyIsRecheckedBeforeMutation() throws {
        let store = FakeScreenSaverPreferences()
        let policy = FakeTimerPolicy()
        let subject = SystemScreenSaverController(preferences: store, policy: policy)
        let original = try configuration(subject)
        policy.availability = .managed
        assertRejected { try subject.apply(value: .integer(0), expected: original) }
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testContextChangeBetweenWritePreflightReadsRejectsBeforeMutation() throws {
        let store = FakeScreenSaverPreferences()
        let subject = controller(store)
        let original = try configuration(subject)
        var primaryReads = 0
        store.beforeCopy = { scope in
            if scope == .currentUserCurrentHost {
                primaryReads += 1
                if primaryReads == 2 { store.domains[.currentUserAnyHost]?["moduleName"] = "external" }
            }
        }
        assertRejected { try subject.apply(value: .integer(0), expected: original) }
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertEqual(store.synchronizations, 0)
    }

    func testInvalidRequestedValueDoesNotReadPolicyOrMutate() throws {
        let store = FakeScreenSaverPreferences()
        let policy = FakeTimerPolicy()
        let subject = SystemScreenSaverController(preferences: store, policy: policy)
        let original = try configuration(subject)
        let checks = policy.checks
        for value in [-1, Int.max] {
            assertRejected { try subject.apply(value: .integer(value), expected: original) }
        }
        XCTAssertEqual(policy.checks, checks)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testFalseSyncRetainsUnknownCompletionAndForbidsFurtherWrites() throws {
        let store = FakeScreenSaverPreferences()
        store.syncResult = false
        let subject = controller(store)
        let original = try configuration(subject)
        assertUnknown { try subject.apply(value: .integer(0), expected: original) }
        let observed = try subject.observe()
        XCTAssertEqual(observed.availability, .unavailable)
        XCTAssertEqual(observed.configuration?.storedValue, .integer(0))
        XCTAssertTrue(observed.message.contains("diagnostic only"))
        assertUnknown { try subject.apply(value: .absent, expected: XCTUnwrap(observed.configuration)) }
        XCTAssertEqual(store.writes, [.integer(0)])
        XCTAssertEqual(store.synchronizations, 1)
    }

    func testPostSyncExternalChangeIsUnknownNotSuccessfulOrReplayed() throws {
        let store = FakeScreenSaverPreferences()
        store.afterSync = { store.domains[.currentUserCurrentHost]?["idleTime"] = 400 }
        let subject = controller(store)
        let original = try configuration(subject)
        assertUnknown { try subject.apply(value: .integer(0), expected: original) }
        XCTAssertEqual(store.writes, [.integer(0)])
        XCTAssertEqual(store.domains[.currentUserCurrentHost]?["idleTime"] as? Int, 400)
        XCTAssertEqual(try subject.observe().availability, .unavailable)
    }

    func testPostSyncResourceReadFailureRemainsUnknown() throws {
        let store = FakeScreenSaverPreferences()
        store.afterSync = { store.resourceFails = true }
        let subject = controller(store)
        let original = try configuration(subject)
        assertUnknown { try subject.apply(value: .integer(0), expected: original) }
        assertUnknown { try subject.apply(value: .absent, expected: original) }
        XCTAssertEqual(store.writes.count, 1)
    }

    func testPostSyncContextChangeDoesNotMasqueradeAsSuccessfulReadback() throws {
        let store = FakeScreenSaverPreferences()
        store.afterSync = { store.domains[.currentUserAnyHost]?["moduleName"] = "external" }
        let subject = controller(store)
        let original = try configuration(subject)
        assertUnknown { try subject.apply(value: .integer(0), expected: original) }
        XCTAssertEqual(try subject.observe().configuration?.storedValue, .integer(0))
        XCTAssertEqual(try subject.observe().availability, .unavailable)
        XCTAssertEqual(store.writes, [.integer(0)])
    }

    func testContextFingerprintIsStableAcrossDictionaryOrderAndTypedAcrossValues() throws {
        let resolver = ScreenSaverPreferenceResolver()
        XCTAssertEqual(try resolver.fingerprint(["a": 1, "b": 2]), try resolver.fingerprint(["b": 2, "a": 1]))
        XCTAssertNotEqual(try resolver.fingerprint(["value": true]), try resolver.fingerprint(["value": 1]))
        XCTAssertNotEqual(try resolver.fingerprint(["value": 1]), try resolver.fingerprint(["value": 1.0]))
        XCTAssertThrowsError(try resolver.fingerprint(["unsupported": URL(fileURLWithPath: "/synthetic")]))
    }

    func testRealControllerAndCoreRestoreAbsenceWithoutLosingBorrowedSystemOwnership() throws {
        try withIntegration { directory, store, power, service in
            let enabled = try service.perform(IdleLockRequest(action: .on))
            XCTAssertTrue(enabled.succeeded)
            XCTAssertEqual(enabled.status.phase, .active)
            XCTAssertEqual(store.writes, [.integer(0)])
            let combined = try HearthService(runner: power, stateDirectory: directory, idleLockController: service).status()
            XCTAssertEqual(combined.idleLock?.phase, .active)
            XCTAssertNotNil(combined.idleLock?.journalFingerprint)
            XCTAssertTrue(try service.perform(IdleLockRequest(action: .restore)).succeeded)
            XCTAssertEqual(store.writes, [.integer(0), .absent])
            XCTAssertNil(store.domains[.currentUserCurrentHost]?["idleTime"])
            XCTAssertEqual(power.settings.values, [.battery: 0, .adapter: 0])
            XCTAssertEqual(power.settings.displayValues, [.battery: 2, .adapter: 10])
            XCTAssertTrue(power.writes.allSatisfy { $0.setting == .display })
            let state = try integrationState(directory)
            XCTAssertEqual(state["version"] as? Int, 4)
            XCTAssertNil(state["lockOverride"])
            let profiles = try XCTUnwrap(state["profiles"] as? [String: [String: [String: Int]]])
            XCTAssertEqual(profiles["battery"]?["override"], ["original": 1, "applied": 0])
            XCTAssertEqual((state["displayProfiles"] as? [String: Any])?.count, 0)
        }
    }

    func testRealControllerContextChangeKeepsOwnedZeroAndOriginalJournal() throws {
        try withIntegration { directory, store, power, service in
            XCTAssertTrue(try service.perform(IdleLockRequest(action: .on)).succeeded)
            let writes = power.writes.count
            store.domains[.currentUserAnyHost]?["moduleName"] = "external"
            let status = try service.status()
            XCTAssertEqual(status.phase, .needsRestore)
            XCTAssertFalse(status.canRestore)
            XCTAssertFalse(try service.perform(IdleLockRequest(action: .restore)).succeeded)
            XCTAssertEqual(store.writes, [.integer(0)])
            XCTAssertEqual(power.writes.count, writes)
            XCTAssertNotNil(try integrationState(directory)["lockOverride"])
        }
    }

    func testRealControllerUnknownSyncRemainsQuarantinedAfterControllerRecreation() throws {
        try withIntegration { directory, store, power, service in
            store.syncResult = false
            XCTAssertFalse(try service.perform(IdleLockRequest(action: .on)).succeeded)
            XCTAssertEqual(try service.status().phase, .uncertain)
            let recreated = IdleLockService(runner: power, screenSaver: controller(store), stateDirectory: directory)
            XCTAssertEqual(try recreated.status().phase, .uncertain)
            XCTAssertFalse(try recreated.perform(IdleLockRequest(action: .restore)).succeeded)
            XCTAssertEqual(store.writes, [.integer(0)])
            XCTAssertEqual(store.synchronizations, 1)
            XCTAssertNotNil(try integrationState(directory)["lockOverride"])
            XCTAssertEqual(power.settings.values[.battery], 0)
        }
    }

    private func withIntegration(
        _ body: (URL, FakeScreenSaverPreferences, TimerIntegrationPower, IdleLockService) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-cf-integration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Cannot remove isolated integration state: \(error)") }
        }
        let state = directory.appendingPathComponent("state.json")
        try Data(#"{"version":3,"profiles":{"battery":{"override":{"original":1,"applied":0}}},"displayProfiles":{}}"#.utf8).write(to: state)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
        let store = FakeScreenSaverPreferences()
        let power = TimerIntegrationPower()
        let service = IdleLockService(runner: power, screenSaver: controller(store), stateDirectory: directory)
        try body(directory, store, power, service)
    }

    private func integrationState(_ directory: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("state.json"))) as? [String: Any])
    }

    private func controller(_ store: FakeScreenSaverPreferences) -> SystemScreenSaverController {
        SystemScreenSaverController(preferences: store, policy: FakeTimerPolicy())
    }

    private func configuration(_ subject: SystemScreenSaverController) throws -> ScreenSaverConfiguration {
        try XCTUnwrap(subject.observe().configuration)
    }

    private func protectedFingerprint(_ store: FakeScreenSaverPreferences) throws -> String {
        var values = store.domains[.currentUserCurrentHost] ?? [:]
        values.removeValue(forKey: "idleTime")
        return try ScreenSaverPreferenceResolver().fingerprint(values)
    }

    private func assertRejected(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case ScreenSaverError.rejected = error else { return XCTFail("Expected definite rejection: \(error)", file: file, line: line) }
        }
    }

    private func assertUnknown(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case ScreenSaverError.completionUnknown = error else { return XCTFail("Expected unknown completion: \(error)", file: file, line: line) }
        }
    }
}

private final class FakeScreenSaverPreferences: ScreenSaverPreferencesAccessing, @unchecked Sendable {
    var domains = Dictionary(uniqueKeysWithValues: ScreenSaverReadScope.allCases.map { ($0, [String: Any]()) })
    var resource = ScreenSaverEngineDefaults(values: ["idleTime": 1234], resourceData: Data("synthetic registered default 1234".utf8))
    var resourceFails = false
    var exactReadOverride: (() -> Any?)?
    var beforeCopy: ((ScreenSaverReadScope) -> Void)?
    var syncResult = true
    var afterSync: (() -> Void)?
    var writes: [ScreenSaverStoredValue] = []
    var synchronizations = 0

    func copyValues(in scope: ScreenSaverReadScope) throws -> [String: Any] {
        beforeCopy?(scope)
        return domains[scope] ?? [:]
    }
    func copyCurrentHostTimer() -> Any? {
        if let exactReadOverride { return exactReadOverride() }
        return domains[.currentUserCurrentHost]?["idleTime"]
    }
    func engineDefaults() throws -> ScreenSaverEngineDefaults {
        if resourceFails { throw ScreenSaverError.unavailable("Synthetic missing engine resource.") }
        return resource
    }
    func setCurrentHostTimer(_ value: ScreenSaverStoredValue) throws {
        writes.append(value)
        switch value {
        case .absent: domains[.currentUserCurrentHost]?.removeValue(forKey: "idleTime")
        case .integer(let value): domains[.currentUserCurrentHost]?["idleTime"] = NSNumber(value: value)
        }
    }
    func synchronizeCurrentHost() -> Bool {
        synchronizations += 1
        afterSync?()
        return syncResult
    }
}

private final class FakeTimerPolicy: IdleLockPolicyReading, @unchecked Sendable {
    var availability: ScreenSaverAvailability
    var checks = 0
    let failing: Bool
    init(_ availability: ScreenSaverAvailability = .ready, failing: Bool = false) {
        self.availability = availability
        self.failing = failing
    }
    func assess() throws -> IdleLockPolicyAssessment {
        checks += 1
        if failing { throw ScreenSaverError.unavailable("Synthetic policy read failure.") }
        return IdleLockPolicyAssessment(availability: availability, message: "Synthetic policy assessment.")
    }
}

private final class TimerIntegrationPower: PowerCommandRunning, @unchecked Sendable {
    var settings = PowerSettings(values: [.battery: 0, .adapter: 0], currentSource: "Synthetic", displayValues: [.battery: 2, .adapter: 10])
    var writes: [PowerChange] = []

    func readSettings() throws -> PowerSettings { settings }
    func apply(_ changes: [PowerChange]) throws -> [CommandOutcome] {
        try changes.map { change in
            guard settings.values(for: change.setting)[change.profile] == change.expectedMinutes else {
                throw HearthError.command("Synthetic expected-value conflict.")
            }
            writes.append(change)
            var system = settings.values
            var display = settings.displayValues
            if change.setting == .system { system[change.profile] = change.minutes }
            else { display[change.profile] = change.minutes }
            settings = PowerSettings(values: system, currentSource: "Synthetic", displayValues: display)
            return CommandOutcome(profile: change.profile, exitCode: 0, setting: change.setting)
        }
    }
}
