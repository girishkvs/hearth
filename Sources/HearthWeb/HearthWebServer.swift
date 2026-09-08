import CryptoKit
import Darwin
import Foundation
import HearthCore
import NIOCore
import NIOHTTP1
import NIOPosix
import Security

public enum HearthWebError: Error, LocalizedError, Sendable {
    case invalidPort
    case alreadyStarted
    case notStarted
    case randomGeneration
    case missingPage

    public var errorDescription: String? {
        switch self {
        case .invalidPort: "The web port must be from 0 to 65535."
        case .alreadyStarted: "This web server has already been started."
        case .notStarted: "The web server has not been started."
        case .randomGeneration: "Could not create a secure web access token."
        case .missingPage: "The bundled web page is missing or invalid."
        }
    }
}

/// Lifecycle methods block and must not be called on an NIO event loop.
/// The condition protects lifecycle state; each run owns its networking and worker resources.
public final class HearthWebServer: @unchecked Sendable {
    private let service: HearthService
    private let lifecycle = NSCondition()
    private var resources: ServerResources?
    private var hasStarted = false
    private var stopping = false
    private var stopped = false
    private var listenerClosed = false

    public init(service: HearthService) {
        self.service = service
    }

    public func start(port: Int = 0) throws -> URL {
        guard (0...65535).contains(port) else { throw HearthWebError.invalidPort }
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !hasStarted else { throw HearthWebError.alreadyStarted }

        let page = try EmbeddedPage()
        var randomBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes) == errSecSuccess else {
            throw HearthWebError.randomGeneration
        }
        let token = randomBytes.map { String(format: "%02x", $0) }.joined()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let workers = NIOThreadPool(numberOfThreads: 2)
        workers.start()
        let connections = ConnectionRegistry()
        let work = WorkBudget()

        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 32)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 4_096))
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                .childChannelInitializer { channel in
                    guard connections.add(channel) else { return channel.close() }
                    channel.closeFuture.whenComplete { _ in connections.remove(channel) }
                    guard let assignedPort = channel.localAddress?.port else {
                        return channel.close()
                    }
                    let router = RequestRouter(
                        authority: "127.0.0.1:\(assignedPort)",
                        token: token,
                        page: page
                    )
                    return channel.pipeline.configureHTTPServerPipeline(
                        withPipeliningAssistance: false,
                        withErrorHandling: false
                    ).flatMapThrowing {
                        try channel.pipeline.syncOperations.addHandler(RequestByteLimiter(), position: .first)
                    }.flatMap {
                        channel.pipeline.addHandler(RequestHandler(
                            router: router,
                            service: self.service,
                            workers: workers,
                            work: work
                        ))
                    }
                }
            let channel = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
            guard let assignedPort = channel.localAddress?.port,
                  let url = URL(string: "http://127.0.0.1:\(assignedPort)/#\(token)") else {
                try? channel.close().wait()
                throw HearthWebError.notStarted
            }
            resources = ServerResources(channel: channel, group: group, workers: workers, connections: connections)
            hasStarted = true
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                self.lifecycle.lock()
                self.listenerClosed = true
                self.lifecycle.broadcast()
                self.lifecycle.unlock()
            }
            return url
        } catch {
            connections.closeAll()
            try? workers.syncShutdownGracefully()
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    public func wait() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard hasStarted else { throw HearthWebError.notStarted }
        // A future.wait() after event-loop shutdown would enqueue onto a stopped loop.
        while !listenerClosed { lifecycle.wait() }
    }

    public func stop() throws {
        lifecycle.lock()
        while stopping { lifecycle.wait() }
        guard let resources, !stopped else {
            lifecycle.unlock()
            return
        }
        stopping = true
        lifecycle.unlock()

        var shutdownError: (any Error)?
        do { try resources.channel.close().wait() } catch { shutdownError = error }
        resources.connections.closeAll()
        do { try resources.workers.syncShutdownGracefully() } catch { shutdownError = shutdownError ?? error }
        do { try resources.group.syncShutdownGracefully() } catch { shutdownError = shutdownError ?? error }

        lifecycle.lock()
        stopping = false
        stopped = true
        lifecycle.broadcast()
        lifecycle.unlock()
        if let shutdownError { throw shutdownError }
    }
}

private struct ServerResources {
    let channel: any Channel
    let group: MultiThreadedEventLoopGroup
    let workers: NIOThreadPool
    let connections: ConnectionRegistry
}

// The lock protects all access to the connection collection and closed flag.
private final class ConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: any Channel] = [:]
    private var closed = false

    func add(_ channel: any Channel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, channels.count < 32 else { return false }
        channels[ObjectIdentifier(channel)] = channel
        return true
    }

    func remove(_ channel: any Channel) {
        lock.lock()
        defer { lock.unlock() }
        channels.removeValue(forKey: ObjectIdentifier(channel))
    }

    func closeAll() {
        lock.lock()
        closed = true
        let active = Array(channels.values)
        lock.unlock()
        for channel in active { try? channel.close().wait() }
    }
}

// Bound queued and running blocking core calls across all connections.
// The lock protects the count; it is never held while invoking core code.
private final class WorkBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < 4 else { return false }
        count += 1
        return true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        count -= 1
    }
}

struct EmbeddedPage: Sendable {
    let data: Data
    let policy: String

    init(executableURL: URL? = nil) throws {
        let runningExecutable = try executableURL ?? ExecutableLocation().url()
        let executable = runningExecutable.resolvingSymlinksInPath()
        let executableDirectory = executable.deletingLastPathComponent()
        let contents = executableDirectory.deletingLastPathComponent()
        let packagedBundleURL = contents.appendingPathComponent("Resources/Hearth_HearthWeb.bundle", isDirectory: true)
        let isPackagedExecutable = executableDirectory.lastPathComponent == "MacOS" &&
            contents.lastPathComponent == "Contents" &&
            contents.deletingLastPathComponent().pathExtension == "app"
        let url: URL?
        if let packagedBundle = Bundle(url: packagedBundleURL) {
            url = packagedBundle.url(forResource: "index", withExtension: "html")
        } else if isPackagedExecutable {
            // Do not let SwiftPM's development fallback hide an incomplete installed app.
            throw HearthWebError.missingPage
        } else {
            url = Bundle.module.url(forResource: "index", withExtension: "html")
        }
        guard let url, let html = try? String(contentsOf: url, encoding: .utf8) else {
            throw HearthWebError.missingPage
        }
        data = Data(html.utf8)
        guard let style = html.range(of: "<style>"),
              let styleEnd = html.range(of: "</style>", range: style.upperBound..<html.endIndex),
              let script = html.range(of: "<script>"),
              let scriptEnd = html.range(of: "</script>", range: script.upperBound..<html.endIndex) else {
            throw HearthWebError.missingPage
        }
        let styleHash = Data(SHA256.hash(data: Data(html[style.upperBound..<styleEnd.lowerBound].utf8))).base64EncodedString()
        let scriptHash = Data(SHA256.hash(data: Data(html[script.upperBound..<scriptEnd.lowerBound].utf8))).base64EncodedString()
        policy = "default-src 'none'; script-src 'sha256-\(scriptHash)'; style-src 'sha256-\(styleHash)'; " +
            "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'"
    }
}

private struct ExecutableLocation {
    func url() throws -> URL {
        // argv[0] may only be "hearth" when launched from PATH.
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else {
            throw HearthWebError.missingPage
        }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }
}

struct WebResponse: Sendable {
    let code: Int
    let body: Data
    let contentType: String

    init(code: Int, message: String) {
        do {
            self.body = try JSONEncoder().encode(["error": message])
            self.code = code
        } catch {
            self.code = 500
            self.body = Data(#"{"error":"Could not encode the error response."}"#.utf8)
            FileHandle.standardError.write(Data("Hearth web: response encoding failed: \(error.localizedDescription)\n".utf8))
        }
        self.contentType = "application/json; charset=utf-8"
    }

    init(code: Int = 200, body: Data, contentType: String = "application/json; charset=utf-8") {
        self.code = code
        self.body = body
        self.contentType = contentType
    }
}

enum WebRoute: Sendable {
    case page
    case status
    case power
}

struct RequestRouter: Sendable {
    let authority: String
    let token: String
    let page: EmbeddedPage
    let maximumBodyBytes = 4_096
    let maximumHeaderBytes = 8_192

    func validate(_ head: HTTPRequestHead) -> Result<WebRoute, RouteFailure> {
        guard head.version == .http1_1 else {
            return .failure(RouteFailure(code: 400, message: "HTTP/1.1 is required."))
        }
        let headerBytes = head.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 }
        guard headerBytes <= maximumHeaderBytes, head.uri.utf8.count <= 256 else {
            return .failure(RouteFailure(code: 431, message: "Request headers are too large."))
        }
        guard head.headers["host"] == [authority] else {
            return .failure(RouteFailure(code: 403, message: "Host does not match this server."))
        }
        let origins = head.headers["origin"]
        guard origins.isEmpty || origins == ["http://\(authority)"] else {
            return .failure(RouteFailure(code: 403, message: "Origin does not match this server."))
        }
        let fetchSites = head.headers["sec-fetch-site"]
        guard fetchSites.isEmpty || fetchSites == ["same-origin"] || fetchSites == ["none"] else {
            return .failure(RouteFailure(code: 403, message: "Cross-origin access is not allowed."))
        }
        guard head.headers["expect"].isEmpty,
              head.headers["upgrade"].isEmpty else {
            return .failure(RouteFailure(code: 400, message: "Expect and Upgrade are not supported."))
        }
        if let length = head.headers.first(name: "content-length") {
            guard let count = Int(length), count <= maximumBodyBytes else {
                return .failure(RouteFailure(code: 413, message: "Request body is too large."))
            }
        }
        if head.uri == "/" {
            guard head.method == .GET else {
                return .failure(RouteFailure(code: 405, message: "Use GET for this route."))
            }
            return .success(.page)
        }
        guard head.uri == "/api/status" || head.uri == "/api/power" else {
            return .failure(RouteFailure(code: 404, message: "Route not found."))
        }
        guard authenticated(head.headers["authorization"]) else {
            return .failure(RouteFailure(code: 401, message: "A valid bearer token is required. Reopen the launch URL."))
        }
        if head.uri == "/api/status" {
            guard head.method == .GET else {
                return .failure(RouteFailure(code: 405, message: "Use GET for status."))
            }
            return .success(.status)
        }
        guard head.method == .POST else {
            return .failure(RouteFailure(code: 405, message: "Use POST for power changes."))
        }
        guard origins == ["http://\(authority)"] else {
            return .failure(RouteFailure(code: 403, message: "Power changes require the matching Origin header."))
        }
        guard head.headers["content-type"].count == 1,
              let contentType = head.headers.first(name: "content-type"),
              contentType.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
            return .failure(RouteFailure(code: 415, message: "Use application/json for power changes."))
        }
        return .success(.power)
    }

    func decodePower(_ body: Data) throws -> PowerRequest {
        let request = try JSONDecoder().decode(PowerBody.self, from: body)
        return try PowerRequest(action: request.action, target: request.target, minutes: request.minutes)
    }

    private func authenticated(_ values: [String]) -> Bool {
        guard values.count == 1 else { return false }
        let received = Array(values[0].utf8)
        let expected = Array("Bearer \(token)".utf8)
        guard received.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= received[index] ^ expected[index] }
        return difference == 0
    }
}

struct RouteFailure: Error {
    let code: Int
    let message: String
}

private struct PowerBody: Decodable {
    let action: PowerAction
    let target: PowerTarget
    let minutes: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Field.self)
        let names = Set(container.allKeys.map(\.stringValue))
        guard names.isSubset(of: ["action", "target", "minutes"]),
              names.contains("action"),
              names.contains("target") else {
            throw HearthError.invalidInput("Provide action and target, with minutes only for sleep. Unknown fields are not allowed.")
        }
        action = try container.decode(PowerAction.self, forKey: Field("action"))
        target = try container.decode(PowerTarget.self, forKey: Field("target"))
        if names.contains("minutes") {
            minutes = try container.decode(Int.self, forKey: Field("minutes"))
        } else {
            minutes = nil
        }
    }

    private struct Field: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
}

// This runs before HTTP decoding, so chunk extensions, partial headers, and trailers
// cannot bypass the decoded header/body bounds.
private final class RequestByteLimiter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var remaining = 16_384
    private var rejected = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !rejected else { return }
        let count = unwrapInboundIn(data).readableBytes
        guard count <= remaining else {
            rejected = true
            context.fireErrorCaught(RouteFailure(code: 413, message: "Total request bytes exceed the limit."))
            return
        }
        remaining -= count
        context.fireChannelRead(data)
    }
}

// NIO confines this handler's mutable state, including completion callbacks, to its channel event loop.
// Only Sendable service/request values enter the worker pool.
private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: RequestRouter
    private let service: HearthService
    private let workers: NIOThreadPool
    private let work: WorkBudget
    private var context: ChannelHandlerContext?
    private var route: WebRoute?
    private var body = Data()
    private var finished = false
    private var timeout: Scheduled<Void>?

    init(router: RequestRouter, service: HearthService, workers: NIOThreadPool, work: WorkBudget) {
        self.router = router
        self.service = service
        self.workers = workers
        self.work = work
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        timeout = context.eventLoop.scheduleTask(in: .seconds(15)) { [weak self] in
            self?.respond(WebResponse(code: 408, message: "Request timed out."))
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else {
            // Never queue pipelined requests, including those already decoded from the same read.
            context.close(promise: nil)
            return
        }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard route == nil else {
                respond(WebResponse(code: 400, message: "Pipelining is not supported."))
                return
            }
            switch router.validate(head) {
            case .success(let route): self.route = route
            case .failure(let failure): respond(WebResponse(code: failure.code, message: failure.message))
            }
        case .body(let bytes):
            guard route != nil else {
                respond(WebResponse(code: 400, message: "Missing request headers."))
                return
            }
            guard bytes.readableBytes <= router.maximumBodyBytes - body.count else {
                respond(WebResponse(code: 413, message: "Request body is too large."))
                return
            }
            guard case .power = route else {
                respond(WebResponse(code: 400, message: "GET requests must not have a body."))
                return
            }
            body.append(contentsOf: bytes.readableBytesView)
        case .end(let trailers):
            guard trailers == nil else {
                respond(WebResponse(code: 400, message: "Request trailers are not supported."))
                return
            }
            finishRequest()
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if !finished { context.read() }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if let failure = error as? RouteFailure {
            respond(WebResponse(code: failure.code, message: failure.message))
        } else {
            respond(WebResponse(code: 400, message: "Malformed HTTP request."))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finished = true
        timeout?.cancel()
        self.context = nil
    }

    private func finishRequest() {
        guard let context, let route else {
            respond(WebResponse(code: 400, message: "Missing request headers."))
            return
        }
        timeout?.cancel()
        if case .page = route {
            respond(WebResponse(body: router.page.data, contentType: "text/html; charset=utf-8"))
            return
        }
        let request: PowerRequest?
        do {
            request = try route == .power ? router.decodePower(body) : nil
        } catch {
            respond(WebResponse(code: 400, message: "Invalid power request. Use action on, restore, or sleep; target both, battery, or adapter; and integer minutes from 1 to \(Int32.max) only for sleep. Unknown fields are not allowed."))
            return
        }
        guard work.acquire() else {
            respond(WebResponse(code: 503, message: "Hearth is busy. Wait for the current operation, then retry."))
            return
        }
        finished = true
        let service = self.service
        let work = self.work
        workers.runIfActive(eventLoop: context.eventLoop) {
            defer { work.release() }
            let encoder = JSONEncoder()
            if let request {
                let result = try service.perform(request)
                return WebResponse(code: result.succeeded ? 200 : 409, body: try encoder.encode(result))
            }
            return WebResponse(body: try encoder.encode(service.status()))
        }.whenComplete { [weak self] result in
            switch result {
            case .success(let response): self?.respond(response)
            case .failure(let error):
                let code: Int
                if case HearthError.busy = error { code = 409 } else { code = 500 }
                self?.respond(WebResponse(code: code, message: error.localizedDescription))
            }
        }
    }

    private func respond(_ response: WebResponse) {
        guard let context else { return }
        finished = true
        timeout?.cancel()
        let headers = HTTPHeaders([
            ("content-type", response.contentType),
            ("content-length", String(response.body.count)),
            ("connection", "close"),
            ("cache-control", "no-store"),
            ("pragma", "no-cache"),
            ("content-security-policy", router.page.policy),
            ("x-content-type-options", "nosniff"),
            ("x-frame-options", "DENY"),
            ("referrer-policy", "no-referrer"),
            ("cross-origin-resource-policy", "same-origin"),
            ("permissions-policy", "camera=(), microphone=(), geolocation=()"),
        ])
        let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: response.code), headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
