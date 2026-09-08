import Darwin
import Foundation
import Security
import XCTest
@testable import HearthHelper
@testable import HearthIPC

private final class FakeBackend: IdleSleepBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values = ["battery": 1, "adapter": 5]
    private var writes: [String] = []
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let pause: Bool
    let failure: String?
    let beforeReadReturns: (@Sendable () -> Void)?
    let rejectBeforeLaunch: Bool

    init(
        pause: Bool = false, failure: String? = nil, beforeReadReturns: (@Sendable () -> Void)? = nil,
        rejectBeforeLaunch: Bool = false
    ) {
        self.pause = pause
        self.failure = failure
        self.beforeReadReturns = beforeReadReturns
        self.rejectBeforeLaunch = rejectBeforeLaunch
    }

    func readMinutes(profile: String, lease: FileHandle, maintenance: FileHandle) throws -> Int {
        let value = lock.withLock { values[profile]! }
        beforeReadReturns?()
        return value
    }

    func write(_ change: IdleSleepChange, lease: FileHandle, maintenance: FileHandle) -> HelperCommandOutcome {
        if rejectBeforeLaunch {
            return HelperCommandOutcome(profile: change.profile, exitCode: 1, message: "Not launched", didExecute: false)
        }
        entered.signal()
        if pause { release.wait() }
        return lock.withLock {
            writes.append(change.profile)
            if change.profile == failure {
                return HelperCommandOutcome(profile: change.profile, exitCode: 7, message: "Fake failure")
            }
            values[change.profile] = change.minutes
            return HelperCommandOutcome(profile: change.profile, exitCode: 0)
        }
    }

    func written() -> [String] { lock.withLock { writes } }
}

private struct TestMaintenanceLock: MaintenanceLockProviding {
    let path: String

    func acquire() throws -> MaintenanceLease {
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        let lease = MaintenanceLease(owning: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            throw HelperClientError.unavailable("Test maintenance in progress.")
        }
        return lease
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[HelperCommandOutcome]] = []
    func add(_ result: [HelperCommandOutcome]) { lock.withLock { values.append(result) } }
    func results() -> [[HelperCommandOutcome]] { lock.withLock { values } }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ data: Data) { lock.withLock { self.data = data } }
    func get() -> Data? { lock.withLock { data } }
}

final class WorkerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard getuid() != 0 else { throw XCTSkip("These tests require a normal unprivileged account.") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-lease-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testLeaseRejectsWrongOwnerRootModeHardlinksAndAccess() throws {
        let lease = try handle()
        defer { try? lease.close() }
        XCTAssertThrowsError(try LockLease(transferring: lease, callerUID: 0))
        XCTAssertThrowsError(try LockLease(transferring: lease, callerUID: getuid() + 1))
        XCTAssertEqual(fchmod(lease.fileDescriptor, 0o644), 0)
        XCTAssertThrowsError(try LockLease(transferring: lease, callerUID: getuid()))
        XCTAssertEqual(fchmod(lease.fileDescriptor, 0o600), 0)
        let path = directory.appendingPathComponent("state.lock").path
        let linked = directory.appendingPathComponent("alias").path
        XCTAssertEqual(link(path, linked), 0)
        XCTAssertThrowsError(try LockLease(transferring: lease, callerUID: getuid()))
        XCTAssertEqual(unlink(linked), 0)
        let readOnly = FileHandle(fileDescriptor: open(path, O_RDONLY), closeOnDealloc: true)
        defer { try? readOnly.close() }
        XCTAssertThrowsError(try LockLease(transferring: readOnly, callerUID: getuid()))
        XCTAssertEqual(fcntl(lease.fileDescriptor, F_SETFL, O_APPEND), 0)
        XCTAssertThrowsError(try LockLease(transferring: lease, callerUID: getuid()))
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        XCTAssertThrowsError(try LockLease(transferring: pipe.fileHandleForReading, callerUID: getuid()))
    }

    func testLeaseNeverReadsOrWritesAndHoldsLockUntilLastClose() throws {
        let handle = try handle()
        try handle.write(contentsOf: Data("untouched".utf8))
        let offset = try handle.offset()
        XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        var lease: LockLease? = try LockLease(transferring: handle, callerUID: getuid())
        XCTAssertEqual(try handle.offset(), offset)
        XCTAssertNotEqual(lease?.handle.fileDescriptor, handle.fileDescriptor)
        try handle.close()
        let observer = try observer()
        defer { try? observer.close() }
        XCTAssertEqual(flock(observer.fileDescriptor, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        lease = nil
        XCTAssertEqual(flock(observer.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("state.lock")), Data("untouched".utf8))
    }

    func testLeaseRejectsAnActualExtendedACL() throws {
        let handle = try handle()
        defer { try? handle.close() }
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "everyone allow read", directory.appendingPathComponent("state.lock").path]
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        XCTAssertThrowsError(try LockLease(transferring: handle, callerUID: getuid()))
    }

    func testMismatchDoesNotWriteAndPartialFailureReturnsEachProfile() throws {
        let backend = FakeBackend(failure: "adapter")
        let worker = worker(backend: backend)
        let handle = try handle()
        defer { try? handle.close() }
        let done = expectation(description: "partial results")
        let box = OutcomeBox()
        try worker.submit([
            IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 99),
            IdleSleepChange(profile: "adapter", minutes: 0, expectedMinutes: 5),
        ], lease: handle, callerUID: getuid()) {
            box.add($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(box.results().first?.map(\.exitCode), [75, 7])
        XCTAssertEqual(box.results().first?.map(\.didExecute), [false, true])
        XCTAssertEqual(backend.written(), ["adapter"])
        XCTAssertTrue(box.results()[0][0].message.contains("External change preserved"))
    }

    func testDefiniteBeforeLaunchRejectionReportsNoExecution() throws {
        let backend = FakeBackend(rejectBeforeLaunch: true)
        let worker = worker(backend: backend)
        let handle = try handle()
        defer { try? handle.close() }
        let done = expectation(description: "completed rejection")
        let box = OutcomeBox()
        try worker.submit(
            [IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 1)],
            lease: handle, callerUID: getuid()
        ) {
            box.add($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(box.results().first?.first?.didExecute, false)
        XCTAssertEqual(box.results().first?.first?.exitCode, 1)
        XCTAssertTrue(backend.written().isEmpty)
    }

    func testHarmlessChildKeepsLeaseAfterBothParentDescriptorsClose() throws {
        let handle = try handle()
        XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        var lease: LockLease? = try LockLease(transferring: handle, callerUID: getuid())
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.3"]
        child.standardInput = lease!.handle
        try child.run()
        // Process retains its configured FileHandle, so close it explicitly to simulate
        // losing every helper-side descriptor while the child still has inherited fd 0.
        try lease!.handle.close()
        lease = nil
        try handle.close()
        let observer = try observer()
        defer { try? observer.close() }
        XCTAssertEqual(flock(observer.fileDescriptor, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(flock(observer.fileDescriptor, LOCK_EX | LOCK_NB), 0)
    }

    func testNativeChildInheritsBothJournalAndMaintenanceLocks() throws {
        let journal = try handle()
        defer { try? journal.close() }
        XCTAssertEqual(flock(journal.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        let operation = try maintenance().acquire()
        let output = FileHandle(fileDescriptor: open("/dev/null", O_RDWR | O_CLOEXEC), closeOnDealloc: true)
        defer { try? output.close() }
        var actions: InheritedLockActions? = try InheritedLockActions(
            journal: journal.fileDescriptor, maintenance: operation.handle.fileDescriptor,
            output: output.fileDescriptor
        )
        let arguments = ["/bin/sleep", "0.3"]
        var argv = arguments.map { strdup($0) } + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sleep", &actions!.actions, &actions!.attributes, &argv, &environment)
        XCTAssertEqual(result, 0)
        guard result == 0 else { return }
        actions = nil
        try journal.close()
        try operation.handle.close()
        let journalObserver = try observer()
        let operationObserver = open(maintenance().path, O_RDWR | O_CLOEXEC)
        defer {
            try? journalObserver.close()
            close(operationObserver)
        }
        XCTAssertGreaterThanOrEqual(operationObserver, 0)
        XCTAssertEqual(flock(journalObserver.fileDescriptor, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(flock(operationObserver, LOCK_EX | LOCK_NB), -1)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, 0), pid)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(flock(journalObserver.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(flock(operationObserver, LOCK_EX | LOCK_NB), 0)
    }

    func testContinuousMaintenanceLockGatesAvailabilityAndQueueing() throws {
        let backend = FakeBackend(pause: true)
        let worker = worker(backend: backend)
        let journal = try handle()
        defer { try? journal.close(); backend.release.signal() }
        let changes = [IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 1)]
        let done = expectation(description: "in-flight operation")
        try worker.submit(changes, lease: journal, callerUID: getuid()) { _ in done.fulfill() }
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 3), .success)
        let installer = open(maintenance().path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(installer, 0)
        XCTAssertEqual(flock(installer, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        backend.release.signal()
        wait(for: [done], timeout: 3)
        var acquired = false
        for _ in 0..<100 {
            if flock(installer, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(acquired)
        XCTAssertThrowsError(try worker.checkAvailability())
        XCTAssertThrowsError(try worker.submit(changes, lease: journal, callerUID: getuid()) { _ in })
        close(installer)
        XCTAssertEqual(backend.written(), ["battery"])
        try worker.checkAvailability()
        let resumed = expectation(description: "writes resume after exclusive lock closes")
        backend.release.signal()
        try worker.submit(
            [IdleSleepChange(profile: "battery", minutes: 1, expectedMinutes: 0)],
            lease: journal, callerUID: getuid()
        ) { _ in resumed.fulfill() }
        wait(for: [resumed], timeout: 3)
        XCTAssertEqual(backend.written(), ["battery", "battery"])
    }

    func testInstallerRecordIsNotAHelperWriteBarrier() throws {
        let marker = directory.appendingPathComponent("maintenance.plist").path
        let backend = FakeBackend(beforeReadReturns: {
            _ = FileManager.default.createFile(atPath: marker, contents: Data())
        })
        let worker = worker(backend: backend)
        let journal = try handle()
        defer { try? journal.close() }
        let done = expectation(description: "installer record does not block write")
        let box = OutcomeBox()
        try worker.submit(
            [IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 1)],
            lease: journal, callerUID: getuid()
        ) {
            box.add($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        XCTAssertEqual(backend.written(), ["battery"])
        XCTAssertEqual(box.results().first?.first?.didExecute, true)
        XCTAssertEqual(box.results().first?.first?.exitCode, 0)
        try worker.checkAvailability()
    }

    func testSerialBoundedWorkRetainsQueuedLeaseAfterCallerClose() throws {
        let backend = FakeBackend(pause: true)
        let worker = worker(backend: backend, capacity: 2)
        let handle = try handle()
        XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        let box = OutcomeBox()
        let change = [IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 1)]
        try worker.submit(change, lease: handle, callerUID: getuid()) { box.add($0); first.fulfill() }
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 3), .success)
        try worker.submit(change, lease: handle, callerUID: getuid()) { box.add($0); second.fulfill() }
        XCTAssertThrowsError(try worker.submit(change, lease: handle, callerUID: getuid()) { _ in })
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 0.05), .timedOut)
        try handle.close()
        let observer = try observer()
        defer { try? observer.close() }
        XCTAssertEqual(flock(observer.fileDescriptor, LOCK_EX | LOCK_NB), -1)
        backend.release.signal()
        wait(for: [first, second], timeout: 3)
        // The second batch performs its precondition read only after the first completes.
        XCTAssertEqual(box.results().map { $0[0].exitCode }, [0, 75])
        XCTAssertEqual(backend.written(), ["battery"])
        var acquired = false
        for _ in 0..<100 {
            if flock(observer.fileDescriptor, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(acquired)
    }

    func testMalformedBatchNeverReachesBackend() throws {
        let backend = FakeBackend()
        let worker = worker(backend: backend)
        let handle = try handle()
        defer { try? handle.close() }
        XCTAssertThrowsError(try worker.submit(
            [IdleSleepChange(profile: "ups", minutes: 0, expectedMinutes: 1)],
            lease: handle, callerUID: getuid(), completion: { _ in }
        ))
        XCTAssertTrue(backend.written().isEmpty)
    }

    func testActualHelperInterfaceOverAnonymousXPCWithFakeBackend() throws {
        let backend = FakeBackend()
        let worker = worker(backend: backend)
        let requirement = try currentProcessRequirement()
        let delegate = HelperListenerDelegate(worker: worker, requirement: requirement)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(requirement.text)
        listener.activate()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = HelperXPCInterface().make()
        connection.setCodeSigningRequirement(requirement.text)
        connection.activate()
        defer {
            connection.invalidate()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }
        let done = expectation(description: "production typed interface reply")
        let response = DataBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail(error.localizedDescription)
            done.fulfill()
        } as! any HearthHelperXPC
        let handle = try handle()
        defer { try? handle.close() }
        XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        let changes = [
            IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 1),
            IdleSleepChange(profile: "adapter", minutes: 10, expectedMinutes: 5),
        ]
        proxy.apply(try HelperWireCodec().applyRequest(changes), lease: handle) {
            response.set($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let data = try XCTUnwrap(response.get())
        let outcomes = try HelperWireCodec().decodeApplyReply(data, changes: changes)
        XCTAssertEqual(outcomes.map(\.exitCode), [0, 0])
        XCTAssertEqual(backend.written(), ["battery", "adapter"])
    }

    func testXPCInvalidationDoesNotReleaseRunningWorkerLease() throws {
        let backend = FakeBackend(pause: true)
        let worker = worker(backend: backend)
        let requirement = try currentProcessRequirement()
        let delegate = HelperListenerDelegate(worker: worker, requirement: requirement)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(requirement.text)
        listener.activate()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = HelperXPCInterface().make()
        connection.setCodeSigningRequirement(requirement.text)
        connection.activate()
        defer {
            backend.release.signal()
            connection.invalidate()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! any HearthHelperXPC
        let handle = try handle()
        XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        proxy.apply(try HelperWireCodec().applyRequest([
            IdleSleepChange(profile: "battery", minutes: 0, expectedMinutes: 1),
        ]), lease: handle) { _ in }
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 3), .success)
        connection.invalidate()
        try handle.close()
        let observer = try observer()
        defer { try? observer.close() }
        XCTAssertEqual(flock(observer.fileDescriptor, LOCK_EX | LOCK_NB), -1)
        backend.release.signal()
        var acquired = false
        for _ in 0..<300 {
            if flock(observer.fileDescriptor, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(acquired)
        XCTAssertEqual(backend.written(), ["battery"])
    }

    private func currentProcessRequirement() throws -> ValidatedCodeRequirement {
        var dynamic: SecCode?
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess,
              let dynamic,
              SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess,
              let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
              let hash = fields[kSecCodeInfoUnique as String] as? Data else {
            throw HelperClientError.unavailable("Cannot inspect test host signing identity.")
        }
        let cdhash = hash.map { String(format: "%02x", $0) }.joined()
        return try ValidatedCodeRequirement("identifier \"\(identifier)\" and cdhash H\"\(cdhash)\"")
    }

    private func worker(backend: FakeBackend, capacity: Int = 8) -> HelperWorker {
        HelperWorker(backend: backend, maintenance: maintenance(), capacity: capacity)
    }

    private func maintenance() -> TestMaintenanceLock {
        TestMaintenanceLock(
            path: directory.appendingPathComponent("operation.lock").path
        )
    }

    private func handle() throws -> FileHandle {
        let path = directory.appendingPathComponent("state.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func observer() throws -> FileHandle {
        let fd = open(directory.appendingPathComponent("state.lock").path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
