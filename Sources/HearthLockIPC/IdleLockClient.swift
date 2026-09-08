import Darwin
import Foundation
import HearthCore
import HearthIPC

@available(macOS 13.0, *)
public struct IdleLockClient: IdleLockControlling {
    private let requirements: @Sendable () throws -> LockPeerRequirements
    private let fetch: @Sendable () throws -> NSXPCListenerEndpoint?
    private let launch: @Sendable (LockPeerRequirements) throws -> Void
    private let actionTimeout: TimeInterval
    private let statusTimeout: TimeInterval
    private let discoveryAttempts: Int
    private let discoveryDelay: TimeInterval
    private let coordinator = LockClientCoordinator()

    public init() {
        requirements = { try LockCodeIdentity().requirements() }
        fetch = { try HelperClient().lockEndpoint() }
        launch = { try LockCodeIdentity().launchApp($0) }
        actionTimeout = 240
        statusTimeout = 5
        discoveryAttempts = 10
        discoveryDelay = 0.2
    }

    init(
        requirements: @escaping @Sendable () throws -> LockPeerRequirements,
        fetch: @escaping @Sendable () throws -> NSXPCListenerEndpoint?,
        launch: @escaping @Sendable (LockPeerRequirements) throws -> Void,
        actionTimeout: TimeInterval = 3, statusTimeout: TimeInterval = 1,
        discoveryAttempts: Int = 2, discoveryDelay: TimeInterval = 0.01
    ) {
        self.requirements = requirements
        self.fetch = fetch
        self.launch = launch
        self.actionTimeout = actionTimeout
        self.statusTimeout = statusTimeout
        self.discoveryAttempts = max(1, min(discoveryAttempts, 10))
        self.discoveryDelay = discoveryDelay
    }

    public func status() throws -> IdleLockStatus {
        do {
            return try coordinator.run { try observe() }
        } catch {
            let guidance: String
            switch error {
            case IdleLockClientError.incompatible, HelperClientError.incompatible:
                guidance = "A matching Hearth app, CLI and helper update is required. No Lock action was sent."
            case IdleLockClientError.setupRequired, HelperClientError.setupRequired:
                guidance = "Run 'hearth setup' for explicit helper installation or repair instructions."
            default:
                guidance = "Open the installed Hearth app and inspect its Lock configuration."
            }
            return IdleLockStatus(
                phase: .unavailable,
                message: "\(error.localizedDescription) \(guidance)"
            )
        }
    }

    public func perform(_ request: IdleLockRequest) throws -> IdleLockResult {
        try coordinator.run {
            let peers = try requirements()
            let connection = try discover(peers)
            defer { connection.invalidate() }
            let action: LockWireAction = request.action == .on ? .on : .restore
            let data = try call(connection, action: action)
            return try decodeActionReply(data, action: action)
        }
    }

    func decodeActionReply(_ data: Data, action: LockWireAction) throws -> IdleLockResult {
        do {
            guard case .result(let result) = try LockWireCodec().decodeReply(data, action: action) else {
                throw IdleLockClientError.completionUnknown(LockWireCodec.unknownMessage)
            }
            return result
        } catch IdleLockClientError.rejected(let message) {
            // This exact validated envelope is reserved for admission refusal.
            throw IdleLockClientError.rejected(message)
        } catch {
            throw IdleLockClientError.completionUnknown(LockWireCodec.unknownMessage)
        }
    }

    private func observe() throws -> IdleLockStatus {
        let peers = try requirements()
        guard let endpoint = try fetch() else {
            throw IdleLockClientError.unavailable("Native Hearth Lock is not running.")
        }
        let connection = try verifiedConnection(endpoint, peers: peers)
        defer { connection.invalidate() }
        let data = try call(connection, action: .status)
        guard case .status(let status) = try LockWireCodec().decodeReply(data, action: .status) else {
            throw IdleLockClientError.incompatible("Native Lock returned an incompatible status.")
        }
        return status
    }

    private func discover(_ peers: LockPeerRequirements) throws -> NSXPCConnection {
        if let connection = try liveConnection(peers) { return connection }
        // Launch/discovery is allowed only before sending the explicit action.
        // A stale/hostile endpoint or lost action reply never triggers a resend.
        try launch(peers)
        for attempt in 0..<discoveryAttempts {
            if let connection = try liveConnection(peers) { return connection }
            if attempt + 1 < discoveryAttempts { Thread.sleep(forTimeInterval: discoveryDelay) }
        }
        throw IdleLockClientError.unavailable("Hearth opened but its Lock service is unavailable. Inspect the native app's error before another explicit action.")
    }

    private func liveConnection(_ peers: LockPeerRequirements) throws -> NSXPCConnection? {
        guard let endpoint = try fetch() else { return nil }
        do {
            return try verifiedConnection(endpoint, peers: peers)
        } catch IdleLockClientError.unavailable {
            return nil
        }
    }

    private func verifiedConnection(_ endpoint: NSXPCListenerEndpoint, peers: LockPeerRequirements) throws -> NSXPCConnection {
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = LockXPCInterface().make()
        connection.setCodeSigningRequirement(peers.app.text)
        let waiter = LockReplyWaiter<Int>()
        let failure = IdleLockClientError.unavailable("Native Hearth Lock identity could not be established. No Lock action was sent.")
        connection.interruptionHandler = { waiter.complete(.failure(failure)) }
        connection.invalidationHandler = { waiter.complete(.failure(failure)) }
        connection.activate()
        do {
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                waiter.complete(.failure(failure))
            }) as? any HearthLockXPC else { throw failure }
            proxy.handshake { waiter.complete(.success($0)) }
            guard try waiter.wait(seconds: statusTimeout, failure: failure) == LockWireCodec.version else {
                throw IdleLockClientError.incompatible("Native Lock protocol is incompatible; a matching Hearth update is required. No Lock action was sent.")
            }
            // Kernel attributes are established by the first response. The
            // connection identity cannot change; use THIS connection for work.
            guard getuid() != 0,
                  geteuid() == getuid(),
                  connection.effectiveUserIdentifier == getuid() else {
                throw IdleLockClientError.rejected("Native Lock belongs to another user. No Lock action was sent.")
            }
            return connection
        } catch {
            connection.invalidate()
            throw error
        }
    }

    private func call(_ connection: NSXPCConnection, action: LockWireAction) throws -> Data {
        let waiter = LockReplyWaiter<Data>()
        let failure: IdleLockClientError = action == .status
            ? .unavailable("Native Hearth Lock did not answer.")
            : .completionUnknown(LockWireCodec.unknownMessage)
        connection.interruptionHandler = { waiter.complete(.failure(failure)) }
        connection.invalidationHandler = { waiter.complete(.failure(failure)) }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            waiter.complete(.failure(failure))
        }) as? any HearthLockXPC else { throw failure }
        proxy.request(LockWireCodec().request(action)) { waiter.complete(.success($0)) }
        return try waiter.wait(seconds: action == .status ? statusTimeout : actionTimeout, failure: failure)
    }
}

// No main-queue dispatch or synchronousRemoteObjectProxy: callers may enter from
// the CLI main thread, an HTTP worker, or AppKit. NSWorkspace and XPC callbacks
// both finish on background queues while that caller waits.
private final class LockClientCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = 0

    func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) throws -> Value {
        let accepted = lock.withLock {
            guard admitted < 8 else { return false }
            admitted += 1
            return true
        }
        guard accepted else { throw IdleLockClientError.rejected("Too many local Lock calls. No request was sent.") }
        defer { lock.withLock { admitted -= 1 } }
        let waiter = LockReplyWaiter<Value>()
        DispatchQueue.global(qos: .userInitiated).async {
            waiter.complete(Result { try body() })
        }
        return try waiter.wait()
    }
}

final class LockReplyWaiter<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, any Error>?

    func complete(_ value: Result<Value, any Error>) {
        lock.withLock {
            guard result == nil else { return }
            result = value
            semaphore.signal()
        }
    }

    func wait(seconds: TimeInterval, failure: IdleLockClientError) throws -> Value {
        guard semaphore.wait(timeout: .now() + seconds) == .success else { throw failure }
        return try lock.withLock { try result!.get() }
    }

    func wait() throws -> Value {
        semaphore.wait()
        return try lock.withLock { try result!.get() }
    }
}
