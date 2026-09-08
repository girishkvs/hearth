import Foundation

public struct HelperClient: Sendable {
    public init() {}

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
        changes.map { HelperCommandOutcome(profile: $0.profile, exitCode: 1, message: message, didExecute: false) }
    }

    private func connect() throws -> NSXPCConnection {
        let policy = try ProtectedHelperInstallation().loadPolicy()
        let connection = NSXPCConnection(machServiceName: HelperInstallation.serviceName, options: .privileged)
        connection.remoteObjectInterface = HelperXPCInterface().make()
        connection.setCodeSigningRequirement(policy.helperRequirement.text)
        return connection
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
