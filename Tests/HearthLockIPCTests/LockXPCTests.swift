import Darwin
import Foundation
import HearthCore
import HearthIPC
import Security
import XCTest
@testable import HearthLockIPC

private final class TestPublication: LockEndpointPublishingLease, @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.withLock { valid } }
    func invalidate() { lock.withLock { valid = false } }
}

private final class IncompatibleHandshake: NSObject, HearthLockXPC {
    let requests: LockTestBox<Int>
    init(requests: LockTestBox<Int>) { self.requests = requests }
    func handshake(reply: @escaping @Sendable (Int) -> Void) { reply(1) }
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        requests.set(requests.get() + 1)
        reply(Data())
    }
}

private final class IncompatibleHandshakeDelegate: NSObject, NSXPCListenerDelegate {
    let requests: LockTestBox<Int>
    let peers: LockPeerRequirements
    init(requests: LockTestBox<Int>, peers: LockPeerRequirements) {
        self.requests = requests
        self.peers = peers
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.setCodeSigningRequirement(peers.clients.text)
        connection.exportedInterface = LockXPCInterface().make()
        connection.exportedObject = IncompatibleHandshake(requests: requests)
        connection.activate()
        return true
    }
}

final class LockXPCTests: XCTestCase {
    func testOldServerHandshakeCannotReceiveAnyStatusOrWriteRequest() throws {
        let peers = try selfRequirements()
        let requests = LockTestBox(0)
        let launches = LockTestBox(0)
        let delegate = IncompatibleHandshakeDelegate(requests: requests, peers: peers)
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(peers.clients.text)
        listener.delegate = delegate
        listener.activate()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        let endpoint = listener.endpoint
        let client = IdleLockClient(
            requirements: { peers }, fetch: { endpoint },
            launch: { _ in launches.set(launches.get() + 1) }
        )
        let status = try client.status()
        XCTAssertEqual(status.phase, .unavailable)
        XCTAssertTrue(status.message.contains("update is required"))
        XCTAssertThrowsError(try client.perform(IdleLockRequest(action: .on))) { error in
            guard case IdleLockClientError.incompatible = error else { return XCTFail("Expected update required, not permission setup.") }
        }
        XCTAssertEqual(requests.get(), 0)
        XCTAssertEqual(launches.get(), 0)
    }

    func testAnonymousPinnedStatusActionAndStopLifetime() throws {
        let peers = try selfRequirements()
        let controller = LockTestController()
        let endpoint = LockTestBox<NSXPCListenerEndpoint?>(nil)
        let publication = TestPublication()
        let listener = makeListener(controller, peers: peers, endpoint: endpoint, publication: publication)
        try listener.start()
        defer { XCTAssertTrue(listener.stop()) }
        XCTAssertTrue(listener.isRunning)
        let client = makeClient(peers, endpoint: endpoint)
        XCTAssertEqual(try client.status().phase, .off)
        XCTAssertTrue(try client.perform(IdleLockRequest(action: .on)).succeeded)
        XCTAssertTrue(try client.perform(IdleLockRequest(action: .restore)).succeeded)
        XCTAssertEqual(controller.counts().actions, [.on, .restore])
        for _ in 0..<100 where listener.isBusy { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertTrue(listener.stop())
        XCTAssertFalse(publication.isValid)
        XCTAssertFalse(listener.isRunning)
    }

    func testStatusMissingEndpointDoesNotLaunchOrPerform() throws {
        let peers = try selfRequirements()
        let fetched = LockTestBox(0)
        let launched = LockTestBox(0)
        let client = IdleLockClient(
            requirements: { peers }, fetch: { fetched.set(fetched.get() + 1); return nil },
            launch: { _ in launched.set(launched.get() + 1) }
        )
        XCTAssertEqual(try client.status().phase, .unavailable)
        XCTAssertEqual(fetched.get(), 1)
        XCTAssertEqual(launched.get(), 0)
        XCTAssertThrowsError(try client.perform(IdleLockRequest(action: .on)))
        XCTAssertEqual(launched.get(), 1)
        XCTAssertEqual(fetched.get(), 4)
    }

    func testExplicitActionLaunchesOnlyBeforeSendThenNeverRetriesTimeout() throws {
        let peers = try selfRequirements()
        let controller = LockTestController(pause: true)
        let endpoint = LockTestBox<NSXPCListenerEndpoint?>(nil)
        let publication = TestPublication()
        let listener = makeListener(controller, peers: peers, endpoint: endpoint, publication: publication)
        let launches = LockTestBox(0)
        let client = IdleLockClient(
            requirements: { peers }, fetch: { endpoint.get() },
            launch: { _ in launches.set(launches.get() + 1); try listener.start() },
            actionTimeout: 0.15
        )
        defer { controller.release.signal() }
        XCTAssertThrowsError(try client.perform(IdleLockRequest(action: .on))) { error in
            guard case IdleLockClientError.completionUnknown = error else { return XCTFail("Expected unknown, got \(error)") }
        }
        XCTAssertEqual(controller.counts().actions, [.on])
        XCTAssertEqual(launches.get(), 1)
        XCTAssertTrue(listener.isBusy)
        XCTAssertFalse(listener.stop())
        XCTAssertTrue(publication.isValid)
        controller.release.signal()
        for _ in 0..<200 where listener.isBusy { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertFalse(listener.isBusy)
        XCTAssertTrue(listener.stop())
        XCTAssertFalse(publication.isValid)
        XCTAssertEqual(controller.counts().actions, [.on])
    }

    func testSpoofedEndpointCannotAnswerWithWrongAppRequirement() throws {
        let peers = try selfRequirements()
        let controller = LockTestController()
        let endpoint = LockTestBox<NSXPCListenerEndpoint?>(nil)
        let listener = makeListener(controller, peers: peers, endpoint: endpoint, publication: TestPublication())
        try listener.start()
        defer { XCTAssertTrue(listener.stop()) }
        let wrong = try ValidatedCodeRequirement(#"identifier "dev.girishkvs.hearth.tests.nonexistent""#)
        let client = makeClient(LockPeerRequirements(app: wrong, clients: peers.clients), endpoint: endpoint)
        XCTAssertEqual(try client.status().phase, .unavailable)
        XCTAssertTrue(controller.counts().actions.isEmpty)
    }

    func testListenerRejectsNonEnrolledClientBeforeAnyControllerCall() throws {
        let peers = try selfRequirements()
        let wrong = try ValidatedCodeRequirement(#"identifier "dev.girishkvs.hearth.tests.nonexistent""#)
        let controller = LockTestController()
        let endpoint = LockTestBox<NSXPCListenerEndpoint?>(nil)
        let listener = makeListener(
            controller, peers: LockPeerRequirements(app: peers.app, clients: wrong),
            endpoint: endpoint, publication: TestPublication()
        )
        try listener.start()
        defer { XCTAssertTrue(listener.stop()) }
        XCTAssertEqual(try makeClient(peers, endpoint: endpoint).status().phase, .unavailable)
        XCTAssertEqual(controller.counts().observations, 0)
        XCTAssertTrue(controller.counts().actions.isEmpty)
    }

    func testInvalidPublisherLeaseRefusesOldFetchedEndpoint() throws {
        let peers = try selfRequirements()
        let controller = LockTestController()
        let endpoint = LockTestBox<NSXPCListenerEndpoint?>(nil)
        let publication = TestPublication()
        let listener = makeListener(controller, peers: peers, endpoint: endpoint, publication: publication)
        try listener.start()
        publication.invalidate()
        defer { XCTAssertTrue(listener.stop()) }
        XCTAssertEqual(try makeClient(peers, endpoint: endpoint).status().phase, .unavailable)
        XCTAssertEqual(controller.counts().observations, 0)
        XCTAssertFalse(listener.isRunning)
    }

    func testExplicitRefreshRepublishesMetadataAfterHelperLossWithoutControllerCalls() throws {
        let peers = try selfRequirements()
        let controller = LockTestController()
        let endpoint = LockTestBox<NSXPCListenerEndpoint?>(nil)
        let publication = LockTestBox(TestPublication())
        let validations = LockTestBox(0)
        let publications = LockTestBox(0)
        let leases = LockTestBox(0)
        let listener = IdleLockListener(
            controller: controller, requirements: { validations.set(validations.get() + 1); return peers },
            acquireLease: { leases.set(leases.get() + 1); return LockTestLease() },
            publish: {
                endpoint.set($0)
                publications.set(publications.get() + 1)
                return publication.get()
            }
        )
        try listener.start()
        defer { XCTAssertTrue(listener.stop()) }
        let originalEndpoint = try XCTUnwrap(endpoint.get())
        try listener.ensureRegistration()
        XCTAssertEqual(validations.get(), 1)
        XCTAssertEqual(publications.get(), 1)
        publication.get().invalidate()
        publication.set(TestPublication())
        XCTAssertFalse(listener.isRunning)
        try listener.ensureRegistration()
        XCTAssertTrue(listener.isRunning)
        XCTAssertEqual(validations.get(), 2)
        XCTAssertEqual(publications.get(), 2)
        XCTAssertEqual(leases.get(), 1)
        XCTAssertTrue(controller.counts().actions.isEmpty)
        XCTAssertEqual(controller.counts().observations, 0)
        XCTAssertEqual(try makeClient(peers, endpoint: LockTestBox(originalEndpoint)).status().phase, .off)
        XCTAssertEqual(try makeClient(peers, endpoint: endpoint).status().phase, .off)
    }

    func testRegistrationFailureStaysVisibleAndExplicitRetryRevalidates() throws {
        let peers = try selfRequirements()
        let controller = LockTestController()
        let publication = TestPublication()
        let fail = LockTestBox(false)
        let validations = LockTestBox(0)
        let listener = IdleLockListener(
            controller: controller, requirements: { validations.set(validations.get() + 1); return peers },
            acquireLease: { LockTestLease() },
            publish: { _ in
                if fail.get() { throw IdleLockClientError.unavailable("Fake helper down") }
                return publication.isValid ? publication : TestPublication()
            }
        )
        try listener.start()
        defer { XCTAssertTrue(listener.stop()) }
        publication.invalidate()
        fail.set(true)
        XCTAssertThrowsError(try listener.ensureRegistration())
        XCTAssertFalse(listener.isRunning)
        fail.set(false)
        try listener.ensureRegistration()
        XCTAssertTrue(listener.isRunning)
        XCTAssertEqual(validations.get(), 3)
        XCTAssertTrue(controller.counts().actions.isEmpty)
        XCTAssertEqual(controller.counts().observations, 0)
    }

    func testChangedClientPinWaitsForWorkThenRebuildsWithoutReleasingSingleton() throws {
        let peers = try selfRequirements()
        let nextClients = try ValidatedCodeRequirement(
            "(\(peers.clients.text)) or (identifier \"dev.hearth.tests.replacement-cli\")"
        )
        let current = LockTestBox(peers)
        let publication = LockTestBox(TestPublication())
        let endpoint = LockTestBox<NSXPCListenerEndpoint?>(nil)
        let leases = LockTestBox(0)
        let controller = LockTestController(pause: true)
        let listener = IdleLockListener(
            controller: controller, requirements: { current.get() },
            acquireLease: { leases.set(leases.get() + 1); return LockTestLease() },
            publish: { endpoint.set($0); return publication.get() }
        )
        try listener.start()
        let client = IdleLockClient(
            requirements: { peers }, fetch: { endpoint.get() },
            launch: { _ in XCTFail("Unexpected launch") }, actionTimeout: 0.15
        )
        defer { controller.release.signal(); _ = listener.stop() }
        XCTAssertThrowsError(try client.perform(IdleLockRequest(action: .on)))
        XCTAssertTrue(listener.isBusy)
        publication.get().invalidate()
        publication.set(TestPublication())
        current.set(LockPeerRequirements(app: peers.app, clients: nextClients))
        XCTAssertThrowsError(try listener.ensureRegistration())
        XCTAssertFalse(listener.stop())
        controller.release.signal()
        for _ in 0..<200 where listener.isBusy { Thread.sleep(forTimeInterval: 0.005) }
        try listener.ensureRegistration()
        XCTAssertTrue(listener.isRunning)
        XCTAssertEqual(leases.get(), 1)
        XCTAssertEqual(controller.counts().actions, [.on])
        XCTAssertEqual(try makeClient(peers, endpoint: endpoint).status().phase, .off)
    }

    private func makeListener(
        _ controller: LockTestController, peers: LockPeerRequirements,
        endpoint: LockTestBox<NSXPCListenerEndpoint?>, publication: TestPublication
    ) -> IdleLockListener {
        IdleLockListener(
            controller: controller, requirements: { peers }, acquireLease: { LockTestLease() },
            publish: { endpoint.set($0); return publication }
        )
    }

    private func makeClient(
        _ peers: LockPeerRequirements, endpoint: LockTestBox<NSXPCListenerEndpoint?>
    ) -> IdleLockClient {
        IdleLockClient(
            requirements: { peers }, fetch: { endpoint.get() },
            launch: { _ in XCTFail("Unexpected launch") }
        )
    }

    private func selfRequirements() throws -> LockPeerRequirements {
        guard getuid() != 0 else { throw XCTSkip("Anonymous peer tests run unprivileged.") }
        var dynamic: SecCode?
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any],
              let hash = fields[kSecCodeInfoUnique as String] as? Data else {
            throw NSError(domain: "LockTestCode", code: 1)
        }
        let cdhash = hash.map { String(format: "%02x", $0) }.joined()
        let requirement = try ValidatedCodeRequirement("cdhash H\"\(cdhash)\"")
        return LockPeerRequirements(app: requirement, clients: requirement)
    }
}
