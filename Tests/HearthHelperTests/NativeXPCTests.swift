import Darwin
import Foundation
import XCTest

final class NativeXPCTests: XCTestCase {
    func testHardenedAdHocNativePeerRequirementsAndFileHandleTransfer() throws {
        guard getuid() != 0 else { throw XCTSkip("The native peer probe must run unprivileged.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-native-xpc-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Probe.swift")
        let executable = directory.appendingPathComponent("Probe")
        try Data(probeSource.utf8).write(to: source)
        let compiled = try run("/usr/bin/xcrun", [
            "swiftc", "-swift-version", "6", "-parse-as-library", source.path, "-o", executable.path,
        ], timeout: 90)
        XCTAssertEqual(compiled.code, 0, compiled.output)
        guard compiled.code == 0 else { return }
        let signed = try run("/usr/bin/codesign", [
            "--force", "--sign", "-", "--options", "runtime", "--identifier", "dev.girishkvs.hearth.tests.peer", executable.path,
        ])
        XCTAssertEqual(signed.code, 0, signed.output)
        guard signed.code == 0 else { return }
        for mode in ["match", "listener-mismatch", "connection-mismatch", "client-mismatch"] {
            let result = try run(executable.path, [mode], timeout: 15)
            XCTAssertEqual(result.code, 0, "\(mode): \(result.output)")
            XCTAssertTrue(result.output.contains("PASS \(mode)"), result.output)
        }
    }

    private func run(_ executable: String, _ arguments: [String], timeout: Double = 15) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                finished.wait()
            }
        }
        process.waitUntilExit()
        try? pipe.fileHandleForWriting.close()
        let output = String(decoding: try pipe.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        try? pipe.fileHandleForReading.close()
        return (process.terminationStatus, output)
    }

    // Compiled and ad-hoc hardened in a test-owned temporary directory. This standalone
    // fixture never links the production helper or reads/writes power settings.
    private var probeSource: String {
        #"""
        import Darwin
        import Foundation
        import Security

        @objc protocol ProbeProtocol {
            func check(_ request: Data, lease: FileHandle, reply: @escaping @Sendable (Data) -> Void)
        }

        final class State: @unchecked Sendable {
            private let lock = NSLock()
            private var descriptor: Int32 = -1
            private var received = false
            private var replied = false
            func retain(_ descriptor: Int32) { lock.withLock { self.descriptor = descriptor; received = true } }
            func markReply() { lock.withLock { replied = true } }
            func didReceive() -> Bool { lock.withLock { received } }
            func didReply() -> Bool { lock.withLock { replied } }
            func release() {
                lock.withLock {
                    if descriptor >= 0 { close(descriptor); descriptor = -1 }
                }
            }
        }

        final class Endpoint: NSObject, ProbeProtocol, @unchecked Sendable {
            let state: State
            init(_ state: State) { self.state = state }
            func check(_ request: Data, lease: FileHandle, reply: @escaping @Sendable (Data) -> Void) {
                let fd = fcntl(lease.fileDescriptor, F_DUPFD_CLOEXEC, 3)
                var info = stat()
                guard request == Data("probe".utf8), fd >= 0,
                      fstat(fd, &info) == 0,
                      info.st_uid == getuid(),
                      info.st_mode & S_IFMT == S_IFREG,
                      info.st_mode & 0o777 == 0o600 else {
                    if fd >= 0 { close(fd) }
                    reply(Data("invalid".utf8))
                    return
                }
                state.retain(fd)
                try? lease.close()
                reply(Data("accepted".utf8))
            }
        }

        final class Delegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
            let requirement: String
            let state: State
            init(_ requirement: String, _ state: State) { self.requirement = requirement; self.state = state }
            func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                guard connection.effectiveUserIdentifier == getuid(),
                      connection.effectiveUserIdentifier != 0 else { return false }
                connection.setCodeSigningRequirement(requirement)
                connection.exportedInterface = NSXPCInterface(with: ProbeProtocol.self)
                connection.exportedObject = Endpoint(state)
                connection.activate()
                return true
            }
        }

        @main struct Probe {
            static func main() throws {
                try Probe().run()
            }
            func run() throws {
                guard getuid() != 0, CommandLine.arguments.count == 2 else { exit(10) }
                let mode = CommandLine.arguments[1]
                var dynamic: SecCode?
                var code: SecStaticCode?
                var info: CFDictionary?
                guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
                      SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code,
                      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                      let fields = info as? [String: Any],
                      let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
                      let hash = fields[kSecCodeInfoUnique as String] as? Data,
                      let flags = fields[kSecCodeInfoFlags as String] as? NSNumber,
                      flags.uint32Value & 0x10000 != 0,
                      flags.uint32Value & 0x2 != 0 else { exit(11) }
                let cdhash = hash.map { String(format: "%02x", $0) }.joined()
                let matching = "identifier \"\(identifier)\" and cdhash H\"\(cdhash)\""
                let mismatched = "identifier \"\(identifier)\" and cdhash H\"\(String(repeating: "0", count: 40))\""
                for text in [matching, mismatched] {
                    var requirement: SecRequirement?
                    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { exit(12) }
                }
                let state = State()
                let delegate = Delegate(mode == "connection-mismatch" ? mismatched : matching, state)
                let listener = NSXPCListener.anonymous()
                listener.setConnectionCodeSigningRequirement(mode == "listener-mismatch" ? mismatched : matching)
                listener.delegate = delegate
                listener.activate()
                let client = NSXPCConnection(listenerEndpoint: listener.endpoint)
                client.remoteObjectInterface = NSXPCInterface(with: ProbeProtocol.self)
                client.setCodeSigningRequirement(mode == "client-mismatch" ? mismatched : matching)
                let done = DispatchSemaphore(value: 0)
                client.invalidationHandler = { done.signal() }
                client.activate()
                let proxy = client.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! ProbeProtocol
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-native-lease-\(UUID())").path
                let fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
                guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { exit(13) }
                defer { unlink(path) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                proxy.check(Data("probe".utf8), lease: handle) { data in
                    if data == Data("accepted".utf8) { state.markReply() }
                    done.signal()
                }
                guard done.wait(timeout: .now() + 5) == .success else { exit(14) }
                try handle.close()
                if mode == "match" {
                    guard state.didReceive(), state.didReply() else { exit(15) }
                    let observer = open(path, O_RDWR | O_CLOEXEC)
                    guard observer >= 0, flock(observer, LOCK_EX | LOCK_NB) == -1, errno == EWOULDBLOCK else { exit(16) }
                    state.release()
                    guard flock(observer, LOCK_EX | LOCK_NB) == 0 else { exit(17) }
                    close(observer)
                } else {
                    guard !state.didReply() else { exit(18) }
                    if mode != "client-mismatch", state.didReceive() { exit(19) }
                    state.release()
                }
                client.invalidate()
                listener.invalidate()
                withExtendedLifetime(delegate) {}
                print("PASS \(mode): native hardened ad-hoc requirements; lease transfer checked on match")
            }
        }
        """#
    }
}
