import Darwin
import Foundation
import HearthIPC

protocol IdleSleepBackend: Sendable {
    func readMinutes(profile: String, lease: FileHandle, maintenance: FileHandle) throws -> Int
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
                    profile: change.profile, lease: lease.handle, maintenance: operation.handle
                )
                guard actual == change.expectedMinutes else {
                    return HelperCommandOutcome(
                        profile: change.profile, exitCode: 75,
                        message: "External change preserved: expected \(change.expectedMinutes) minutes, found \(actual).",
                        didExecute: false
                    )
                }
                return backend.write(change, lease: lease.handle, maintenance: operation.handle)
            } catch {
                return HelperCommandOutcome(
                    profile: change.profile, exitCode: 1, message: error.localizedDescription, didExecute: false
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

    init(worker: HelperWorker, callerUID: uid_t) {
        self.worker = worker
        self.callerUID = callerUID
    }

    func availability(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let codec = HelperWireCodec()
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

    init(worker: HelperWorker, requirement: ValidatedCodeRequirement) {
        self.worker = worker
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // This is kernel-supplied identity, not a UID field supplied by the caller.
        // Capability is available to nonroot local users who can execute a pinned
        // hardened binary. This is not per-user enrollment or client-path authorization.
        let uid = connection.effectiveUserIdentifier
        guard uid != 0 else { return false }
        let identifier = UUID()
        let accepted = lock.withLock {
            guard connections.count < 32 else { return false }
            connections[identifier] = connection
            return true
        }
        guard accepted else { return false }
        connection.setCodeSigningRequirement(requirement.text)
        connection.exportedInterface = HelperXPCInterface().make()
        connection.exportedObject = HelperEndpoint(worker: worker, callerUID: uid)
        connection.invalidationHandler = { [weak self] in
            _ = self?.lock.withLock { self?.connections.removeValue(forKey: identifier) }
        }
        connection.activate()
        return true
    }
}
