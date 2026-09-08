import Foundation

public struct HelperClient: Sendable {
    private let connectionFactory: @Sendable () throws -> NSXPCConnection
    private let publisherConnectionFactory: @Sendable (NSXPCListenerEndpoint) throws -> NSXPCConnection

    public init() {
        connectionFactory = {
            let policy = try ProtectedHelperInstallation().loadPolicy()
            let connection = NSXPCConnection(machServiceName: HelperInstallation.serviceName, options: .privileged)
            connection.remoteObjectInterface = HelperXPCInterface().make()
            connection.setCodeSigningRequirement(policy.helperRequirement.text)
            return connection
        }
        publisherConnectionFactory = { endpoint in
            let policy = try ProtectedHelperInstallation().loadPolicy()
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = LockPublisherXPCInterface().make()
            connection.setCodeSigningRequirement(policy.helperRequirement.text)
            return connection
        }
    }

    init(
        connectionFactory: @escaping @Sendable () throws -> NSXPCConnection,
        publisherConnectionFactory: @escaping @Sendable (NSXPCListenerEndpoint) throws -> NSXPCConnection = { _ in
            throw HelperClientError.unavailable("No publisher factory configured for this test client.")
        }
    ) {
        self.connectionFactory = connectionFactory
        self.publisherConnectionFactory = publisherConnectionFactory
    }

    public func publishLockEndpoint(_ endpoint: NSXPCListenerEndpoint) throws -> HelperLockEndpointPublication {
        guard let publisher = try brokerEndpoint(publishing: true) else {
            throw HelperClientError.unavailable("The installed helper has no Lock publisher. Run explicit setup/repair.")
        }
        let connection = try publisherConnectionFactory(publisher)
        let publication = HelperLockEndpointPublication(connection: connection)
        let waiter = BrokerReply<Bool>()
        let failure = HelperClientError.unavailable("Lock endpoint publication failed. Open Hearth or run explicit setup/repair.")
        connection.invalidationHandler = { [weak publication] in
            publication?.markInvalid()
            waiter.complete(.failure(failure))
        }
        connection.interruptionHandler = { [weak publication] in
            publication?.invalidate()
            waiter.complete(.failure(failure))
        }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            waiter.complete(.failure(failure))
        }) as? any HearthLockPublisherXPC else {
            publication.invalidate()
            throw failure
        }
        proxy.publishLockEndpoint(endpoint) { waiter.complete(.success($0)) }
        do {
            guard try waiter.wait(failure: failure) else { throw failure }
            return publication
        } catch {
            publication.invalidate()
            throw error
        }
    }

    public func lockEndpoint() throws -> NSXPCListenerEndpoint? {
        try brokerEndpoint(publishing: false)
    }

    private func brokerEndpoint(publishing: Bool) throws -> NSXPCListenerEndpoint? {
        let connection = try connect()
        defer { connection.invalidate() }
        let waiter = BrokerReply<NSXPCListenerEndpoint?>()
        let failure = HelperClientError.unavailable("Hearth Lock rendezvous is unavailable. Open Hearth or run explicit setup/repair.")
        connection.invalidationHandler = { waiter.complete(.failure(failure)) }
        connection.interruptionHandler = { waiter.complete(.failure(failure)) }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            waiter.complete(.failure(failure))
        }) as? any HearthHelperXPC else { throw failure }
        if publishing {
            proxy.publisherEndpoint { waiter.complete(.success($0)) }
        } else {
            proxy.lockEndpoint { waiter.complete(.success($0)) }
        }
        return try waiter.wait(failure: failure)
    }

    public func availability() -> HelperConnectionStatus {
        do {
            let connection = try connect()
            defer { connection.invalidate() }
            let data = try call(connection, writing: false) { proxy, reply in
                proxy.availability(HelperWireCodec().availabilityRequest(), reply: reply)
            }
            return try HelperWireCodec().decodeStatusReply(data)
        } catch let error as HelperClientError {
            let state: HelperConnectionState
            switch error {
            case .setupRequired: state = .setupRequired
            case .incompatible: state = .incompatible
            case .unavailable, .rejected, .completionUnknown: state = .unavailable
            }
            return HelperConnectionStatus(state: state, message: error.localizedDescription)
        } catch {
            return HelperConnectionStatus(state: .unavailable, message: "Hearth helper is unavailable: \(error.localizedDescription)")
        }
    }

    public func apply(_ changes: [IdleSleepChange], lease: FileHandle) throws -> [HelperCommandOutcome] {
        let codec = HelperWireCodec()
        let request: Data
        do {
            request = try codec.applyRequest(changes)
        } catch {
            throw HelperClientError.rejected(error.localizedDescription)
        }
        let connection: NSXPCConnection
        do {
            connection = try connect()
        } catch {
            // No connection was activated and no RPC was sent.
            return rejectedOutcomes(changes, message: error.localizedDescription)
        }
        defer { connection.invalidate() }
        let data = try call(connection, writing: true) { proxy, reply in
            proxy.apply(request, lease: lease, reply: reply)
        }
        return try decodeApplyResponse(data, changes: changes)
    }

    func decodeApplyResponse(_ data: Data, changes: [IdleSleepChange]) throws -> [HelperCommandOutcome] {
        // A received, valid failure envelope means the helper rejected the batch before execution.
        // A malformed reply cannot prove whether a write happened.
        do {
            return try HelperWireCodec().decodeApplyReply(data, changes: changes)
        } catch let error as HelperClientError {
            if case .rejected(let message) = error {
                return rejectedOutcomes(changes, message: message)
            }
            throw HelperClientError.completionUnknown(
                "Helper reply could not confirm completion. Pending restore information must be retained. \(error.localizedDescription)"
            )
        } catch {
            throw HelperClientError.completionUnknown(
                "Helper reply was malformed. Pending restore information must be retained; do not retry automatically."
            )
        }
    }

    private func rejectedOutcomes(_ changes: [IdleSleepChange], message: String) -> [HelperCommandOutcome] {
        changes.map {
            HelperCommandOutcome(
                profile: $0.profile, exitCode: 1, message: message, didExecute: false, setting: $0.setting
            )
        }
    }

    private func connect() throws -> NSXPCConnection {
        try connectionFactory()
    }

    private func call(
        _ connection: NSXPCConnection,
        writing: Bool,
        send: (any HearthHelperXPC, @escaping @Sendable (Data) -> Void) -> Void
    ) throws -> Data {
        let result = ReplyWaiter()
        let unavailable: HelperClientError = writing
            ? .completionUnknown("Connection lost before write completion was confirmed. Do not retry automatically; pending restore information must be retained.")
            : .unavailable("Hearth helper did not answer. Run explicit setup/repair if this persists.")
        connection.interruptionHandler = { result.complete(.failure(unavailable)) }
        connection.invalidationHandler = { result.complete(.failure(unavailable)) }
        connection.activate()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            result.complete(.failure(unavailable))
        }) as? any HearthHelperXPC else { throw unavailable }
        send(proxy) { data in result.complete(.success(data)) }
        return try result.wait(seconds: writing ? 35 : 3, failure: unavailable)
    }
}

public final class HelperLockEndpointPublication: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    init(connection: NSXPCConnection) { self.connection = connection }

    public var isValid: Bool { lock.withLock { connection != nil } }

    public func invalidate() {
        let previous = lock.withLock {
            let previous = connection
            connection = nil
            return previous
        }
        previous?.invalidate()
    }

    fileprivate func markInvalid() { lock.withLock { connection = nil } }

    deinit { connection?.invalidate() }
}

// Endpoints are Foundation XPC values; the lock owns every result access.
private final class BrokerReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, HelperClientError>?

    func complete(_ value: Result<Value, HelperClientError>) {
        lock.withLock {
            guard result == nil else { return }
            result = value
            semaphore.signal()
        }
    }

    func wait(failure: HelperClientError) throws -> Value {
        guard semaphore.wait(timeout: .now() + 3) == .success else { throw failure }
        return try lock.withLock { try result!.get() }
    }
}

private final class ReplyWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Data, HelperClientError>?

    func complete(_ value: Result<Data, HelperClientError>) {
        lock.withLock {
            guard result == nil else { return }
            result = value
            semaphore.signal()
        }
    }

    func wait(seconds: Int, failure: HelperClientError) throws -> Data {
        guard semaphore.wait(timeout: .now() + .seconds(seconds)) == .success else { throw failure }
        return try lock.withLock { try result!.get() }
    }
}
