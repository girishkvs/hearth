import Darwin
import Foundation
import HearthCore
import HearthIPC

protocol LockEndpointPublishingLease: AnyObject, Sendable {
    var isValid: Bool { get }
    func invalidate()
}

extension HelperLockEndpointPublication: LockEndpointPublishingLease {}

@available(macOS 13.0, *)
public final class IdleLockListener: @unchecked Sendable {
    private let lock = NSLock()
    private let controller: any IdleLockControlling
    private let requirements: @Sendable () throws -> LockPeerRequirements
    private let acquireLease: @Sendable () throws -> any LockLifetimeLease
    private let publish: @Sendable (NSXPCListenerEndpoint) throws -> any LockEndpointPublishingLease
    private let capacity: Int
    private var running: RunningLockListener?

    public convenience init(controller: any IdleLockControlling) {
        self.init(
            controller: controller,
            requirements: {
                let identity = LockCodeIdentity()
                let requirements = try identity.requirements()
                try identity.validateCurrentApp(requirements)
                return requirements
            },
            acquireLease: { try LockRuntimeLease() },
            publish: { try HelperClient().publishLockEndpoint($0) }
        )
    }

    init(
        controller: any IdleLockControlling,
        requirements: @escaping @Sendable () throws -> LockPeerRequirements,
        acquireLease: @escaping @Sendable () throws -> any LockLifetimeLease,
        publish: @escaping @Sendable (NSXPCListenerEndpoint) throws -> any LockEndpointPublishingLease,
        capacity: Int = 8
    ) {
        self.controller = controller
        self.requirements = requirements
        self.acquireLease = acquireLease
        self.publish = publish
        self.capacity = max(1, min(capacity, 8))
    }

    public var isBusy: Bool { lock.withLock { running?.worker.isBusy ?? false } }

    public var isRunning: Bool { lock.withLock { running?.publication.isValid ?? false } }

    public func start() throws {
        try lock.withLock {
            guard running == nil else {
                throw IdleLockClientError.unavailable("The native Lock listener is already started.")
            }
            let peers = try requirements()
            running = try makeRunning(peers: peers, lease: acquireLease())
        }
    }

    // Native reopen/explicit refresh may retry this METADATA operation after a
    // helper restart. It never calls the controller or replays a Lock request.
    public func ensureRegistration() throws {
        try lock.withLock {
            guard let running else {
                let peers = try requirements()
                self.running = try makeRunning(peers: peers, lease: acquireLease())
                return
            }
            guard !running.publication.isValid else { return }
            let peers = try requirements()
            if peers.clients.text != running.peers.clients.text {
                guard running.worker.stopIfIdle() else {
                    throw IdleLockClientError.unavailable("Lock enrollment changed while work is running. Wait before refreshing registration.")
                }
                running.invalidate()
                self.running = nil
                // Keep the singleton descriptor through the replacement. An
                // existing NSXPC listener's requirement must never be reset.
                self.running = try makeRunning(peers: peers, lease: running.worker.lifetimeLease)
            } else {
                let publication = try publish(running.listener.endpoint)
                guard publication.isValid else {
                    throw IdleLockClientError.unavailable("Native Lock registration was lost. Use explicit refresh to try registration again.")
                }
                running.publication.invalidate()
                running.publication = publication
                running.delegate.publication = publication
            }
        }
    }

    private func makeRunning(peers: LockPeerRequirements, lease: any LockLifetimeLease) throws -> RunningLockListener {
        let worker = LockRequestWorker(controller: controller, lease: lease, capacity: capacity)
        let delegate = LockListenerDelegate(worker: worker, requirement: peers.clients, capacity: capacity)
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(peers.clients.text)
        listener.delegate = delegate
        listener.activate()
        do {
            let publication = try publish(listener.endpoint)
            guard publication.isValid else {
                throw IdleLockClientError.unavailable("Native Lock registration was lost. Use explicit refresh to try registration again.")
            }
            delegate.publication = publication
            return RunningLockListener(
                listener: listener, delegate: delegate, worker: worker, publication: publication, peers: peers
            )
        } catch {
            listener.invalidate()
            delegate.invalidate()
            throw error
        }
    }

    // Call before committing to app termination. False means keep the app and
    // listener alive, then retry after the accepted work completes.
    @discardableResult
    public func stop() -> Bool {
        lock.withLock {
            guard let running else { return true }
            guard running.worker.stopIfIdle() else { return false }
            running.invalidate()
            self.running = nil
            return true
        }
    }

    deinit { running?.invalidate() }
}

private final class RunningLockListener {
    let listener: NSXPCListener
    let delegate: LockListenerDelegate
    let worker: LockRequestWorker
    var publication: any LockEndpointPublishingLease
    let peers: LockPeerRequirements

    init(
        listener: NSXPCListener, delegate: LockListenerDelegate,
        worker: LockRequestWorker, publication: any LockEndpointPublishingLease, peers: LockPeerRequirements
    ) {
        self.listener = listener
        self.delegate = delegate
        self.worker = worker
        self.publication = publication
        self.peers = peers
    }

    func invalidate() {
        listener.invalidate()
        delegate.invalidate()
        publication.invalidate()
    }
}

final class LockRequestWorker: @unchecked Sendable {
    private let controller: any IdleLockControlling
    private let lease: any LockLifetimeLease
    private let queue = DispatchQueue(label: "dev.girishkvs.hearth.lock.operations")
    private let lock = NSLock()
    private let capacity: Int
    private var admitted = 0
    private var stopped = false

    init(controller: any IdleLockControlling, lease: any LockLifetimeLease, capacity: Int = 8) {
        self.controller = controller
        self.lease = lease
        self.capacity = max(1, min(capacity, 8))
    }

    var isBusy: Bool { lock.withLock { admitted != 0 } }
    var lifetimeLease: any LockLifetimeLease { lease }

    func stopIfIdle() -> Bool {
        lock.withLock {
            guard admitted == 0 else { return false }
            stopped = true
            return true
        }
    }

    func submit(_ action: LockWireAction, reply: @escaping @Sendable (Data) -> Void) {
        let codec = LockWireCodec()
        let accepted = lock.withLock {
            guard !stopped, admitted < capacity else { return false }
            admitted += 1
            queue.async { [self] in
                let data: Data
                do {
                    if let request = action.request {
                        data = codec.resultReply(try controller.perform(request), action: action)
                    } else {
                        data = codec.statusReply(try controller.status())
                    }
                } catch {
                    data = codec.failure(
                        action, outcome: action == .status ? "unavailable" : "unknown",
                        message: action == .status ? error.localizedDescription : LockWireCodec.unknownMessage
                    )
                }
                // Client interruption cannot cancel accepted jobs or release the
                // singleton/controller. The core owns its separate journal lease.
                withExtendedLifetime(lease) {
                    reply(data)
                    lock.withLock { admitted -= 1 }
                }
            }
            return true
        }
        if !accepted {
            reply(codec.failure(action, outcome: "rejected", message: "Native Lock is busy or stopping. No work was queued."))
        }
    }
}

final class LockConnectionEndpoint: NSObject, HearthLockXPC, @unchecked Sendable {
    private let worker: LockRequestWorker
    private let lock = NSLock()
    private var used = false
    private var handshaken = false
    private var invalidated = false
    private let canServe: @Sendable () -> Bool

    init(worker: LockRequestWorker, canServe: @escaping @Sendable () -> Bool = { true }) {
        self.worker = worker
        self.canServe = canServe
    }

    func handshake(reply: @escaping @Sendable (Int) -> Void) {
        let accepted = lock.withLock {
            guard !handshaken, !used, !invalidated, canServe() else { return false }
            handshaken = true
            return true
        }
        reply(accepted ? LockWireCodec.version : 0)
    }

    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        let codec = LockWireCodec()
        let action: LockWireAction
        do { action = try codec.decodeRequest(data) } catch {
            // Invalid requests have no trusted action to echo. A writing client
            // will conservatively treat this envelope as completionUnknown.
            reply(codec.failure(.status, outcome: "rejected", message: error.localizedDescription))
            return
        }
        let accepted = lock.withLock {
            guard handshaken, !used, !invalidated, canServe() else { return false }
            used = true
            return true
        }
        guard accepted else {
            reply(codec.failure(action, outcome: "rejected", message: "Lock requires a live registration and one request per connection."))
            return
        }
        worker.submit(action, reply: reply)
    }

    func invalidate() { lock.withLock { invalidated = true } }
}

private final class LockListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let worker: LockRequestWorker
    private let requirement: ValidatedCodeRequirement
    private let capacity: Int
    private let lock = NSLock()
    private var connections: [UUID: NSXPCConnection] = [:]
    private var closed = false
    private var lease: (any LockEndpointPublishingLease)?

    var publication: (any LockEndpointPublishingLease)? {
        get { lock.withLock { lease } }
        set { lock.withLock { lease = newValue } }
    }

    init(worker: LockRequestWorker, requirement: ValidatedCodeRequirement, capacity: Int) {
        self.worker = worker
        self.requirement = requirement
        self.capacity = capacity
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              connection.effectiveUserIdentifier != 0 else { return false }
        let identifier = UUID()
        return lock.withLock {
            guard !closed, lease?.isValid == true, connections.count < capacity else { return false }
            connection.setCodeSigningRequirement(requirement.text)
            connection.exportedInterface = LockXPCInterface().make()
            let endpoint = LockConnectionEndpoint(worker: worker) { [weak self] in
                self?.publication?.isValid == true
            }
            connection.exportedObject = endpoint
            connection.invalidationHandler = { [weak self] in
                endpoint.invalidate()
                _ = self?.lock.withLock { self?.connections.removeValue(forKey: identifier) }
            }
            connection.interruptionHandler = { [weak self] in self?.invalidateConnection(identifier) }
            connections[identifier] = connection
            connection.activate()
            // Idle and abandoned connections cannot retain the cap forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 245) { [weak self] in
                self?.invalidateConnection(identifier)
            }
            return true
        }
    }

    private func invalidateConnection(_ identifier: UUID) {
        let connection = lock.withLock { connections[identifier] }
        connection?.invalidate()
    }

    func invalidate() {
        let old = lock.withLock {
            closed = true
            let old = Array(connections.values)
            connections.removeAll()
            return old
        }
        for connection in old { connection.invalidate() }
    }
}
