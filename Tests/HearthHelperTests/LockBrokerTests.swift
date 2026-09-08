import Darwin
import Foundation
import Security
import XCTest
@testable import HearthHelper
@testable import HearthIPC

private struct BrokerForbiddenBackend: IdleSleepBackend {
    func readMinutes(
        profile: HelperPowerProfile, setting: HelperPowerSetting, lease: FileHandle, maintenance: FileHandle
    ) throws -> Int {
        XCTFail("Rendezvous must not read power")
        throw HelperClientError.unavailable("Forbidden")
    }

    func write(_ change: IdleSleepChange, lease: FileHandle, maintenance: FileHandle) -> HelperCommandOutcome {
        XCTFail("Rendezvous must not write power")
        return HelperCommandOutcome(profile: change.profile, exitCode: 1, didExecute: false)
    }
}

private struct BrokerForbiddenMaintenance: MaintenanceLockProviding {
    func acquire() throws -> MaintenanceLease {
        XCTFail("Rendezvous must not open the maintenance lock")
        throw HelperClientError.unavailable("Forbidden")
    }
}

private final class BrokerTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
}

@objc private protocol BrokerMarkerXPC {
    func marker(reply: @escaping @Sendable (Int) -> Void)
}

private final class BrokerMarker: NSObject, BrokerMarkerXPC {
    let number: Int
    init(_ number: Int) { self.number = number }
    func marker(reply: @escaping @Sendable (Int) -> Void) { reply(number) }
}

private final class BrokerMarkerDelegate: NSObject, NSXPCListenerDelegate {
    let requirement: ValidatedCodeRequirement
    let number: Int

    init(requirement: ValidatedCodeRequirement, number: Int) {
        self.requirement = requirement
        self.number = number
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(), getuid() != 0 else { return false }
        connection.setCodeSigningRequirement(requirement.text)
        connection.exportedInterface = NSXPCInterface(with: BrokerMarkerXPC.self)
        connection.exportedObject = BrokerMarker(number)
        connection.activate()
        return true
    }
}

final class LockBrokerTests: XCTestCase {
    func testBrokerUIDIsolationCapacityAndRootRefusal() throws {
        let broker = LockEndpointBroker(capacity: 1000)
        let listener = NSXPCListener.anonymous()
        defer { listener.invalidate() }
        let endpoint = listener.endpoint
        XCTAssertFalse(broker.publish(endpoint, uid: 0, registration: UUID()))
        XCTAssertNil(broker.endpoint(uid: 0))
        for uid in uid_t(1000)..<uid_t(1032) {
            XCTAssertTrue(broker.publish(endpoint, uid: uid, registration: UUID()))
            XCTAssertNotNil(broker.endpoint(uid: uid))
        }
        XCTAssertFalse(broker.publish(endpoint, uid: 1032, registration: UUID()))
        XCTAssertNil(broker.endpoint(uid: 1032))
        XCTAssertNil(broker.endpoint(uid: 999))
        XCTAssertTrue(broker.publish(endpoint, uid: 1000, registration: UUID()), "Existing UID may replace at capacity")
    }

    func testOldInvalidationCannotDeleteReplacement() throws {
        let broker = LockEndpointBroker()
        let first = NSXPCListener.anonymous()
        let second = NSXPCListener.anonymous()
        defer { first.invalidate(); second.invalidate() }
        let old = UUID()
        let new = UUID()
        let secondEndpoint = second.endpoint
        XCTAssertTrue(broker.publish(first.endpoint, uid: 501, registration: old))
        XCTAssertTrue(broker.publish(secondEndpoint, uid: 501, registration: new))
        broker.remove(uid: 501, registration: old)
        XCTAssertTrue(broker.endpoint(uid: 501) === secondEndpoint)
        broker.remove(uid: 502, registration: new)
        XCTAssertNotNil(broker.endpoint(uid: 501))
        broker.remove(uid: 501, registration: new)
        XCTAssertNil(broker.endpoint(uid: 501))
    }

    func testEndpointPublishesOnceAndCannotResurrectAfterInvalidationWithoutPowerWork() throws {
        let broker = LockEndpointBroker()
        let worker = makeWorker()
        let owner = LockPublisherEndpoint(broker: broker, callerUID: 501)
        let same = HelperEndpoint(worker: worker, callerUID: 501, broker: broker)
        let other = HelperEndpoint(worker: worker, callerUID: 502, broker: broker)
        let root = LockPublisherEndpoint(broker: broker, callerUID: 0)
        let listener = NSXPCListener.anonymous()
        defer { listener.invalidate() }
        let accepted = BrokerTestValue(false)
        owner.publishLockEndpoint(listener.endpoint) { accepted.set($0) }
        XCTAssertTrue(accepted.get())
        let fetched = BrokerTestValue<NSXPCListenerEndpoint?>(nil)
        same.lockEndpoint { fetched.set($0) }
        XCTAssertNotNil(fetched.get())
        other.lockEndpoint { fetched.set($0) }
        XCTAssertNil(fetched.get())
        owner.publishLockEndpoint(listener.endpoint) { accepted.set($0) }
        XCTAssertFalse(accepted.get())
        root.publishLockEndpoint(listener.endpoint) { accepted.set($0) }
        XCTAssertFalse(accepted.get())
        owner.invalidateRegistration()
        owner.publishLockEndpoint(listener.endpoint) { accepted.set($0) }
        XCTAssertFalse(accepted.get())
        same.lockEndpoint { fetched.set($0) }
        XCTAssertNil(fetched.get())
        XCTAssertEqual(HelperWireCodec.version, 2)
        XCTAssertEqual(HelperWireCodec().availabilityRequest(), Data(#"{"version":2}"#.utf8))
    }

    func testAnonymousBrokerRoundTripAndPublisherLeaseCleanup() throws {
        guard getuid() != 0 else { throw XCTSkip("Unprivileged anonymous XPC test") }
        let requirement = try selfRequirement()
        let delegate = HelperListenerDelegate(worker: makeWorker(), requirement: requirement, appRequirement: requirement)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(requirement.text)
        listener.activate()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        let brokerEndpoint = listener.endpoint
        let client = makeClient(brokerEndpoint, requirement: requirement)
        XCTAssertNil(try client.lockEndpoint())
        let native = NSXPCListener.anonymous()
        defer { native.invalidate() }
        var publication: HelperLockEndpointPublication? = try client.publishLockEndpoint(native.endpoint)
        let publicationIsAlive = { [weak publication] in publication != nil }
        XCTAssertTrue(try XCTUnwrap(publication).isValid)
        XCTAssertNotNil(try client.lockEndpoint())
        publication = nil
        XCTAssertFalse(publicationIsAlive(), "The connection's handlers must not cycle-retain its publication lease")
        var endpoint: NSXPCListenerEndpoint?
        for _ in 0..<50 {
            endpoint = try client.lockEndpoint()
            if endpoint == nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNil(endpoint)
    }

    func testAnonymousReplacementSurvivesOldPublisherInvalidation() throws {
        let requirement = try selfRequirement()
        let delegate = HelperListenerDelegate(worker: makeWorker(), requirement: requirement, appRequirement: requirement)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(requirement.text)
        listener.activate()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        let client = makeClient(listener.endpoint, requirement: requirement)
        let first = NSXPCListener.anonymous()
        let second = NSXPCListener.anonymous()
        let firstMarker = BrokerMarkerDelegate(requirement: requirement, number: 1)
        let secondMarker = BrokerMarkerDelegate(requirement: requirement, number: 2)
        first.delegate = firstMarker
        second.delegate = secondMarker
        first.setConnectionCodeSigningRequirement(requirement.text)
        second.setConnectionCodeSigningRequirement(requirement.text)
        first.activate()
        second.activate()
        defer { first.invalidate(); second.invalidate(); withExtendedLifetime((firstMarker, secondMarker)) {} }
        let old = try client.publishLockEndpoint(first.endpoint)
        XCTAssertEqual(try marker(XCTUnwrap(client.lockEndpoint()), requirement: requirement), 1)
        let new = try client.publishLockEndpoint(second.endpoint)
        defer { new.invalidate() }
        old.invalidate()
        for _ in 0..<10 {
            XCTAssertEqual(try marker(XCTUnwrap(client.lockEndpoint()), requirement: requirement), 2)
            Thread.sleep(forTimeInterval: 0.005)
        }
        new.invalidate()
        var last: NSXPCListenerEndpoint?
        for _ in 0..<50 {
            last = try client.lockEndpoint()
            if last == nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNil(last)
    }

    func testMixedRoleClientCanLookupButCannotPublishOnAppOnlyListener() throws {
        let clients = try selfRequirement()
        let app = try ValidatedCodeRequirement(#"identifier "dev.girishkvs.hearth.tests.enrolled-app-only""#)
        let delegate = HelperListenerDelegate(worker: makeWorker(), requirement: clients, appRequirement: app)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(clients.text)
        listener.activate()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        let client = makeClient(listener.endpoint, requirement: clients)
        XCTAssertNil(try client.lockEndpoint())
        let native = NSXPCListener.anonymous()
        defer { native.invalidate() }
        XCTAssertThrowsError(try client.publishLockEndpoint(native.endpoint))
        XCTAssertNil(try client.lockEndpoint())
        XCTAssertFalse(
            (HelperEndpoint(worker: makeWorker(), callerUID: getuid()) as NSObject)
                .responds(to: #selector(HearthLockPublisherXPC.publishLockEndpoint(_:reply:))),
            "The mixed-role exported object must not implement publication."
        )
    }

    func testClientPinsHelperOnSeparatePublisherConnection() throws {
        let requirement = try selfRequirement()
        let delegate = HelperListenerDelegate(worker: makeWorker(), requirement: requirement, appRequirement: requirement)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(requirement.text)
        listener.activate()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        let brokerEndpoint = listener.endpoint
        let wrong = try ValidatedCodeRequirement(#"identifier "dev.girishkvs.hearth.tests.wrong-helper""#)
        let client = HelperClient(connectionFactory: {
            let connection = NSXPCConnection(listenerEndpoint: brokerEndpoint)
            connection.remoteObjectInterface = HelperXPCInterface().make()
            connection.setCodeSigningRequirement(requirement.text)
            return connection
        }, publisherConnectionFactory: { endpoint in
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = LockPublisherXPCInterface().make()
            connection.setCodeSigningRequirement(wrong.text)
            return connection
        })
        let native = NSXPCListener.anonymous()
        defer { native.invalidate() }
        XCTAssertThrowsError(try client.publishLockEndpoint(native.endpoint))
    }

    private func makeClient(
        _ endpoint: NSXPCListenerEndpoint, requirement: ValidatedCodeRequirement
    ) -> HelperClient {
        HelperClient(connectionFactory: {
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = HelperXPCInterface().make()
            connection.setCodeSigningRequirement(requirement.text)
            return connection
        }, publisherConnectionFactory: { publisher in
            let connection = NSXPCConnection(listenerEndpoint: publisher)
            connection.remoteObjectInterface = LockPublisherXPCInterface().make()
            connection.setCodeSigningRequirement(requirement.text)
            return connection
        })
    }

    private func marker(_ endpoint: NSXPCListenerEndpoint, requirement: ValidatedCodeRequirement) throws -> Int {
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.setCodeSigningRequirement(requirement.text)
        connection.remoteObjectInterface = NSXPCInterface(with: BrokerMarkerXPC.self)
        let done = DispatchSemaphore(value: 0)
        let result = BrokerTestValue<Int?>(nil)
        connection.invalidationHandler = { done.signal() }
        connection.activate()
        defer { connection.invalidate() }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! any BrokerMarkerXPC
        proxy.marker { result.set($0); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        return try XCTUnwrap(result.get())
    }

    private func makeWorker() -> HelperWorker {
        HelperWorker(backend: BrokerForbiddenBackend(), maintenance: BrokerForbiddenMaintenance())
    }

    private func selfRequirement() throws -> ValidatedCodeRequirement {
        var dynamic: SecCode?
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            throw NSError(domain: "BrokerSelfRequirement", code: 1)
        }
        return try ValidatedCodeRequirement(text as String)
    }
}
