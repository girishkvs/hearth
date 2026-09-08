import Darwin
import Foundation
import HearthIPC

protocol IdleSleepBackend: Sendable {
    func readMinutes(
        profile: HelperPowerProfile, setting: HelperPowerSetting, lease: FileHandle, maintenance: FileHandle
    ) throws -> Int
    func write(_ change: IdleSleepChange, lease: FileHandle, maintenance: FileHandle) -> HelperCommandOutcome
}

final class HelperWorker: @unchecked Sendable {
    private let backend: any IdleSleepBackend
    private let maintenance: any MaintenanceLockProviding
    private let queue = DispatchQueue(label: "dev.girishkvs.hearth.helper.writes")
    private let lock = NSLock()
    private var admitted = 0
    private let capacity: Int

    init(backend: any IdleSleepBackend, maintenance: any MaintenanceLockProviding, capacity: Int = 8) {
        self.backend = backend
        self.maintenance = maintenance
        self.capacity = max(1, min(capacity, 8))
    }

    func checkAvailability() throws {
        let lease = try maintenance.acquire()
        withExtendedLifetime(lease) {}
    }

    func submit(
        _ changes: [IdleSleepChange],
        lease handle: FileHandle,
        callerUID: uid_t,
        completion: @escaping @Sendable ([HelperCommandOutcome]) -> Void
    ) throws {
        try HelperWireCodec().validate(changes)
        let lease = try LockLease(transferring: handle, callerUID: callerUID)
        let operation = try maintenance.acquire()
        let accepted = lock.withLock {
            guard admitted < capacity else { return false }
            admitted += 1
            return true
        }
        guard accepted else { throw HelperClientError.unavailable("Hearth helper is busy. This batch was not queued.") }
        queue.async { [self, lease, operation] in
            let outcomes = execute(changes, lease: lease, operation: operation)
            // Complete all commands before releasing our lease, including on connection loss.
            withExtendedLifetime((lease, operation)) {
                lock.withLock { admitted -= 1 }
                completion(outcomes)
            }
        }
    }

    private func execute(
        _ changes: [IdleSleepChange], lease: LockLease, operation: MaintenanceLease
    ) -> [HelperCommandOutcome] {
        changes.map { change in
            do {
                let actual = try backend.readMinutes(
                    profile: change.profile, setting: change.setting, lease: lease.handle, maintenance: operation.handle
                )
                guard actual == change.expectedMinutes else {
                    return HelperCommandOutcome(
                        profile: change.profile, exitCode: 75,
                        message: "External change preserved: expected \(change.expectedMinutes) minutes, found \(actual).",
                        didExecute: false, setting: change.setting
                    )
                }
                return backend.write(change, lease: lease.handle, maintenance: operation.handle)
            } catch {
                return HelperCommandOutcome(
                    profile: change.profile, exitCode: 1, message: error.localizedDescription,
                    didExecute: false, setting: change.setting
                )
            }
        }
    }
}

final class HelperEndpoint: NSObject, HearthHelperXPC, @unchecked Sendable {
    private let worker: HelperWorker
    private let callerUID: uid_t
    private let lock = NSLock()
    private var applying = false
    private let broker: LockEndpointBroker
    private let publisher: NSXPCListenerEndpoint?
    private var invalidated = false

    init(
        worker: HelperWorker, callerUID: uid_t, broker: LockEndpointBroker = LockEndpointBroker(),
        publisher: NSXPCListenerEndpoint? = nil
    ) {
        self.worker = worker
        self.callerUID = callerUID
        self.broker = broker
        self.publisher = publisher
    }

    func publisherEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) {
        reply(lock.withLock { !invalidated && callerUID != 0 ? publisher : nil })
    }

    func lockEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) {
        let endpoint = lock.withLock {
            invalidated ? nil : broker.endpoint(uid: callerUID)
        }
        reply(endpoint)
    }

    func invalidateRegistration() {
        lock.withLock { invalidated = true }
    }

    func availability(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let codec = HelperWireCodec()
        if let refusal = codec.legacyIncompatibilityReply(to: request, applying: false) {
            reply(refusal)
            return
        }
        do {
            guard callerUID != 0 else { throw HelperClientError.unavailable("Run Hearth as a normal local user, not root.") }
            try codec.decodeAvailabilityRequest(request)
            try worker.checkAvailability()
            reply(codec.statusReply(HelperConnectionStatus(state: .ready, message: "Hearth helper is ready.")))
        } catch HelperClientError.incompatible(let message) {
            reply(codec.statusReply(HelperConnectionStatus(state: .incompatible, message: message)))
        } catch {
            reply(codec.statusReply(HelperConnectionStatus(state: .unavailable, message: error.localizedDescription)))
        }
    }

    func apply(_ request: Data, lease: FileHandle, reply: @escaping @Sendable (Data) -> Void) {
        let codec = HelperWireCodec()
        if let refusal = codec.legacyIncompatibilityReply(to: request, applying: true) {
            reply(refusal)
            return
        }
        do {
            let changes = try codec.decodeApplyRequest(request)
            let accepted = lock.withLock {
                guard !applying else { return false }
                applying = true
                return true
            }
            guard accepted else { throw HelperClientError.unavailable("A batch is already running on this connection.") }
            do {
                try worker.submit(changes, lease: lease, callerUID: callerUID) { [self] outcomes in
                    lock.withLock { applying = false }
                    reply(codec.applyReply(outcomes))
                }
            } catch {
                lock.withLock { applying = false }
                throw error
            }
        } catch HelperClientError.incompatible(let message) {
            reply(codec.applyReply([], failure: HelperConnectionStatus(state: .incompatible, message: message)))
        } catch {
            reply(codec.applyReply([], failure: HelperConnectionStatus(state: .unavailable, message: error.localizedDescription)))
        }
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let worker: HelperWorker
    private let requirement: ValidatedCodeRequirement
    private let lock = NSLock()
    private var connections: [UUID: NSXPCConnection] = [:]
    private let broker = LockEndpointBroker()
    private let connectionLimit = HelperConnectionLimit()
    private let publisherService: LockPublisherService?

    init(
        worker: HelperWorker, requirement: ValidatedCodeRequirement,
        appRequirement: ValidatedCodeRequirement? = nil
    ) {
        self.worker = worker
        self.requirement = requirement
        if let appRequirement {
            publisherService = LockPublisherService(broker: broker, requirement: appRequirement, connectionLimit: connectionLimit)
        } else {
            publisherService = nil
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // This is kernel-supplied identity, not a UID field supplied by the caller.
        // Capability is available to nonroot local users who can execute a pinned
        // hardened binary. This is not per-user enrollment or client-path authorization.
        let uid = connection.effectiveUserIdentifier
        guard uid != 0 else { return false }
        let identifier = UUID()
        let accepted = lock.withLock {
            guard connectionLimit.admit(identifier) else { return false }
            connections[identifier] = connection
            return true
        }
        guard accepted else { return false }
        connection.setCodeSigningRequirement(requirement.text)
        connection.exportedInterface = HelperXPCInterface().make()
        let endpoint = HelperEndpoint(
            worker: worker, callerUID: uid, broker: broker, publisher: publisherService?.endpoint
        )
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak self, connectionLimit] in
            endpoint.invalidateRegistration()
            connectionLimit.remove(identifier)
            _ = self?.lock.withLock { self?.connections.removeValue(forKey: identifier) }
        }
        connection.activate()
        return true
    }
}

// Publication is not a method on the mixed app/CLI connection. Handing out this
// endpoint grants no publishing role: BOTH listener and accepted connection pin
// the exact enrolled app before activation, with no post-activation narrowing.
private final class LockPublisherService {
    private let listener: NSXPCListener
    private let delegate: LockPublisherDelegate
    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    init(broker: LockEndpointBroker, requirement: ValidatedCodeRequirement, connectionLimit: HelperConnectionLimit) {
        delegate = LockPublisherDelegate(broker: broker, requirement: requirement, connectionLimit: connectionLimit)
        listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(requirement.text)
        listener.delegate = delegate
        listener.activate()
    }

    deinit { listener.invalidate(); delegate.invalidate() }
}

private final class LockPublisherDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let broker: LockEndpointBroker
    private let requirement: ValidatedCodeRequirement
    private let connectionLimit: HelperConnectionLimit
    private let lock = NSLock()
    private var connections: [UUID: NSXPCConnection] = [:]

    init(broker: LockEndpointBroker, requirement: ValidatedCodeRequirement, connectionLimit: HelperConnectionLimit) {
        self.broker = broker
        self.requirement = requirement
        self.connectionLimit = connectionLimit
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard uid != 0 else { return false }
        let id = UUID()
        guard connectionLimit.admit(id) else { return false }
        connection.setCodeSigningRequirement(requirement.text)
        connection.exportedInterface = LockPublisherXPCInterface().make()
        let endpoint = LockPublisherEndpoint(broker: broker, callerUID: uid)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak self, connectionLimit] in
            endpoint.invalidateRegistration()
            connectionLimit.remove(id)
            _ = self?.lock.withLock { self?.connections.removeValue(forKey: id) }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        lock.withLock { connections[id] = connection }
        connection.activate()
        return true
    }

    func invalidate() {
        let old = lock.withLock {
            let old = Array(connections.values)
            connections.removeAll()
            return old
        }
        for connection in old { connection.invalidate() }
    }
}

final class LockPublisherEndpoint: NSObject, HearthLockPublisherXPC, @unchecked Sendable {
    private let lock = NSLock()
    private let broker: LockEndpointBroker
    private let callerUID: uid_t
    private let registration = UUID()
    private var invalidated = false
    private var published = false

    init(broker: LockEndpointBroker, callerUID: uid_t) {
        self.broker = broker
        self.callerUID = callerUID
    }

    func publishLockEndpoint(_ endpoint: NSXPCListenerEndpoint, reply: @escaping @Sendable (Bool) -> Void) {
        let accepted = lock.withLock {
            guard !invalidated, !published else { return false }
            published = broker.publish(endpoint, uid: callerUID, registration: registration)
            return published
        }
        reply(accepted)
    }

    func invalidateRegistration() {
        lock.withLock {
            invalidated = true
            broker.remove(uid: callerUID, registration: registration)
        }
    }
}

private final class HelperConnectionLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var connections = Set<UUID>()

    func admit(_ id: UUID) -> Bool {
        lock.withLock {
            guard connections.count < 32 else { return false }
            return connections.insert(id).inserted
        }
    }

    func remove(_ id: UUID) { _ = lock.withLock { connections.remove(id) } }
}

// Routing only. The UID comes from the accepted connection, never from an RPC
// argument. Fetching an endpoint conveys no server trust: clients separately pin
// the native app's exact code hash on their direct connection.
final class LockEndpointBroker: @unchecked Sendable {
    private struct Entry {
        let registration: UUID
        let endpoint: NSXPCListenerEndpoint
    }

    private let lock = NSLock()
    private var entries: [uid_t: Entry] = [:]
    private let capacity: Int

    init(capacity: Int = 32) { self.capacity = max(1, min(capacity, 32)) }

    func publish(_ endpoint: NSXPCListenerEndpoint, uid: uid_t, registration: UUID) -> Bool {
        lock.withLock {
            guard uid != 0,
                  entries[uid] != nil || entries.count < capacity else { return false }
            entries[uid] = Entry(registration: registration, endpoint: endpoint)
            return true
        }
    }

    func endpoint(uid: uid_t) -> NSXPCListenerEndpoint? {
        lock.withLock { uid == 0 ? nil : entries[uid]?.endpoint }
    }

    func remove(uid: uid_t, registration: UUID) {
        lock.withLock {
            guard entries[uid]?.registration == registration else { return }
            entries.removeValue(forKey: uid)
        }
    }
}
