import Foundation
import HearthCore
import XCTest
@testable import HearthLockIPC

final class LockTestController: IdleLockControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [IdleLockAction] = []
    private var observations = 0
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let pause: Bool
    let throwsAfterWrite: Bool

    init(pause: Bool = false, throwsAfterWrite: Bool = false) {
        self.pause = pause
        self.throwsAfterWrite = throwsAfterWrite
    }

    func status() throws -> IdleLockStatus {
        lock.withLock { observations += 1 }
        return IdleLockStatus(phase: .off, message: "fake", canEnable: true)
    }

    func perform(_ request: IdleLockRequest) throws -> IdleLockResult {
        lock.withLock { actions.append(request.action) }
        entered.signal()
        if pause { release.wait() }
        if throwsAfterWrite { throw ScreenSaverError.completionUnknown("Fake uncertain write") }
        return IdleLockResult(succeeded: true, message: "fake", status: IdleLockStatus(phase: .off, message: "fake"))
    }

    func counts() -> (actions: [IdleLockAction], observations: Int) { lock.withLock { (actions, observations) } }
}

final class LockTestLease: LockLifetimeLease, @unchecked Sendable {}

final class LockTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
}

final class LockWorkerTests: XCTestCase {
    func testHandshakeIsNoOpAndRequiredBeforeRequest() throws {
        let controller = LockTestController()
        let worker = LockRequestWorker(controller: controller, lease: LockTestLease())
        let endpoint = LockConnectionEndpoint(worker: worker)
        let refusal = LockTestBox<Data?>(nil)
        endpoint.request(LockWireCodec().request(.on)) { refusal.set($0) }
        XCTAssertThrowsError(try LockWireCodec().decodeReply(XCTUnwrap(refusal.get()), action: .on))
        endpoint.handshake { XCTAssertEqual($0, LockWireCodec.version) }
        endpoint.handshake { XCTAssertEqual($0, 0, "Repeated handshakes fail closed") }
        XCTAssertTrue(controller.counts().actions.isEmpty)
        XCTAssertEqual(controller.counts().observations, 0)
        XCTAssertFalse(worker.isBusy)
    }

    func testStatusNeverPerformsAnAction() throws {
        let controller = LockTestController()
        let worker = LockRequestWorker(controller: controller, lease: LockTestLease())
        let done = expectation(description: "status")
        worker.submit(.status) { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(controller.counts().observations, 1)
        XCTAssertTrue(controller.counts().actions.isEmpty)
    }

    func testQueueIsBoundedSerializedAndStopRefusesBusyWork() throws {
        let controller = LockTestController(pause: true)
        let worker = LockRequestWorker(controller: controller, lease: LockTestLease(), capacity: 2)
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        worker.submit(.on) { _ in first.fulfill() }
        XCTAssertEqual(controller.entered.wait(timeout: .now() + 2), .success)
        worker.submit(.restore) { _ in second.fulfill() }
        let rejected = LockTestBox<Data?>(nil)
        worker.submit(.on) { rejected.set($0) }
        XCTAssertThrowsError(try LockWireCodec().decodeReply(XCTUnwrap(rejected.get()), action: .on))
        XCTAssertTrue(worker.isBusy)
        XCTAssertFalse(worker.stopIfIdle())
        XCTAssertEqual(controller.counts().actions, [.on])
        controller.release.signal()
        XCTAssertEqual(controller.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(controller.counts().actions, [.on, .restore])
        controller.release.signal()
        wait(for: [first, second], timeout: 3)
        for _ in 0..<100 where worker.isBusy { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(worker.stopIfIdle())
        worker.submit(.on) { rejected.set($0) }
        XCTAssertThrowsError(try LockWireCodec().decodeReply(XCTUnwrap(rejected.get()), action: .on))
        XCTAssertEqual(controller.counts().actions.count, 2)
    }

    func testConnectionCannotReplayActionAndInvalidationDoesNotCancelAcceptedWork() throws {
        let controller = LockTestController(pause: true)
        let worker = LockRequestWorker(controller: controller, lease: LockTestLease())
        let endpoint = LockConnectionEndpoint(worker: worker)
        endpoint.handshake { XCTAssertEqual($0, LockWireCodec.version) }
        let done = expectation(description: "accepted action completes")
        let request = LockWireCodec().request(.on)
        endpoint.request(request) { _ in done.fulfill() }
        XCTAssertEqual(controller.entered.wait(timeout: .now() + 2), .success)
        let refusal = LockTestBox<Data?>(nil)
        endpoint.request(request) { refusal.set($0) }
        XCTAssertThrowsError(try LockWireCodec().decodeReply(XCTUnwrap(refusal.get()), action: .on))
        endpoint.invalidate()
        XCTAssertTrue(worker.isBusy)
        XCTAssertFalse(worker.stopIfIdle())
        controller.release.signal()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(controller.counts().actions, [.on])
    }

    func testLeaseOutlivesClientAndDroppedWorkerUntilAcceptedWorkCompletes() throws {
        let controller = LockTestController(pause: true)
        var lease: LockTestLease? = LockTestLease()
        let leaseIsAlive = { [weak lease] in lease != nil }
        var worker: LockRequestWorker? = LockRequestWorker(controller: controller, lease: lease!)
        lease = nil
        let done = expectation(description: "work finished")
        worker?.submit(.on) { _ in done.fulfill() }
        XCTAssertEqual(controller.entered.wait(timeout: .now() + 2), .success)
        worker = nil
        XCTAssertTrue(leaseIsAlive())
        controller.release.signal()
        wait(for: [done], timeout: 3)
        for _ in 0..<100 where leaseIsAlive() { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertFalse(leaseIsAlive())
    }

    func testControllerExceptionAfterWriteIsUnknownNeverRejected() throws {
        let controller = LockTestController(throwsAfterWrite: true)
        let worker = LockRequestWorker(controller: controller, lease: LockTestLease())
        let done = expectation(description: "unknown")
        let response = LockTestBox<Data?>(nil)
        worker.submit(.on) { response.set($0); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertThrowsError(try LockWireCodec().decodeReply(XCTUnwrap(response.get()), action: .on)) { error in
            guard case IdleLockClientError.completionUnknown = error else { return XCTFail("Must not report no-op") }
        }
        XCTAssertEqual(controller.counts().actions, [.on])
    }
}
