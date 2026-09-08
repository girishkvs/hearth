import Darwin
import Foundation
import Security
import XCTest

final class CrossProcessLockBrokerTests: XCTestCase {
    func testAppOnlyPublicationAcrossSignedUnprivilegedProcesses() throws {
        guard getuid() != 0 else { throw XCTSkip("The broker fixture must run unprivileged.") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-lock-cross-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Probe.swift")
        try Data(probeSource.utf8).write(to: source)
        let library = directory.appendingPathComponent("libHearthIPC.a")
        let moduleSources = ["Models", "Wire", "AuthorizationPolicy", "HelperClient"].map {
            root.appendingPathComponent("Sources/HearthIPC/\($0).swift").path
        }
        try checkedRun("/usr/bin/xcrun", [
            "swiftc", "-swift-version", "6", "-parse-as-library", "-enable-testing",
            "-emit-module", "-emit-module-path", directory.appendingPathComponent("HearthIPC.swiftmodule").path,
            "-emit-library", "-static", "-module-name", "HearthIPC",
        ] + moduleSources + ["-o", library.path], timeout: 120)
        for (module, names) in [
            ("HearthCore", ["Models", "IdleLockModels", "StateStore"]),
            ("HearthLockIPC", ["LockWire", "LockIdentity", "IdleLockListener", "IdleLockClient"]),
        ] {
            let sources = names.map { root.appendingPathComponent("Sources/\(module)/\($0).swift").path }
            try checkedRun("/usr/bin/xcrun", [
                "swiftc", "-swift-version", "6", "-parse-as-library", "-enable-testing",
                "-I", directory.path, "-emit-module", "-emit-module-path", directory.appendingPathComponent("\(module).swiftmodule").path,
                "-emit-library", "-static", "-module-name", module,
            ] + sources + ["-o", directory.appendingPathComponent("lib\(module).a").path], timeout: 120)
        }
        let executable = directory.appendingPathComponent("Probe")
        let brokerSources = ["HelperWorker", "LockLease", "MaintenanceLock"].map {
            root.appendingPathComponent("Sources/HearthHelper/\($0).swift").path
        }
        try checkedRun("/usr/bin/xcrun", [
            "swiftc", "-swift-version", "6", "-parse-as-library", "-I", directory.path,
            "-L", directory.path, "-lHearthLockIPC", "-lHearthCore", "-lHearthIPC", source.path,
        ] + brokerSources + ["-o", executable.path], timeout: 120)

        let app = directory.appendingPathComponent("Probe.app")
        let helper = app.appendingPathComponent("Contents/XPCServices/dev.hearth.tests.helper.xpc")
        let cli = app.appendingPathComponent("Contents/XPCServices/dev.hearth.tests.cli.xpc")
        for (bundle, role) in [(helper, "helper"), (cli, "cli"), (app, "app")] {
            let macOS = bundle.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: executable, to: macOS.appendingPathComponent("Probe"))
            var info: [String: Any] = [
                "CFBundleIdentifier": "dev.hearth.tests.\(role)",
                "CFBundleExecutable": "Probe", "CFBundleVersion": "1",
                "CFBundlePackageType": role == "app" ? "APPL" : "XPC!",
            ]
            if role != "app" { info["XPCService"] = ["ServiceType": "Application"] }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            try checkedRun("/usr/bin/codesign", [
                "--force", "--sign", "-", "--options", "runtime", "--identifier", "dev.hearth.tests.\(role)", bundle.path,
            ])
        }
        // Test-only policy is outside the sealed bundle, avoiding recursive hash
        // dependencies. It is never the installed Hearth policy or user state.
        let policy = try ["app": requirement(app), "helper": requirement(helper), "cli": requirement(cli)]
        try PropertyListSerialization.data(fromPropertyList: policy, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("fixture-policy.plist"))
        let output = try checkedRun(app.appendingPathComponent("Contents/MacOS/Probe").path, [], timeout: 45)
        XCTAssertTrue(output.contains("PASS cross-process app-only publication"), output)
        XCTAssertTrue(output.contains("CLI rejected"), output)
        XCTAssertTrue(output.contains("replacement retained"), output)
        XCTAssertTrue(output.contains("peer pins rejected"), output)
        XCTAssertTrue(output.contains("same-connection UID handshake"), output)
    }

    private func requirement(_ bundle: URL) throws -> String {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
              let hash = fields[kSecCodeInfoUnique as String] as? Data else {
            throw NSError(domain: "FixtureSignature", code: 1)
        }
        return "identifier \"\(identifier)\" and cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
    }

    @discardableResult
    private func checkedRun(_ executable: String, _ arguments: [String], timeout: Double = 15) throws -> String {
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
        guard process.terminationStatus == 0 else {
            XCTFail("\(executable): \(process.terminationStatus)\n\(output)")
            throw NSError(domain: "CrossProcessFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }

    // This harness compiles the ACTUAL production broker, publication client,
    // interfaces and connection limits. Only the backend/maintenance and marker
    // endpoints are fakes. Its two embedded XPC services live solely in the
    // temporary app and are explicitly terminated by their kernel-reported PIDs.
    private var probeSource: String {
        #"""
        import Darwin
        import Foundation
        @testable import HearthIPC
        import HearthCore
        @testable import HearthLockIPC

        final class Value<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var value: T
            init(_ value: T) { self.value = value }
            func set(_ value: T) { lock.withLock { self.value = value } }
            func get() -> T { lock.withLock { value } }
        }

        struct ForbiddenBackend: IdleSleepBackend {
            func readMinutes(profile: HelperPowerProfile, setting: HelperPowerSetting, lease: FileHandle, maintenance: FileHandle) throws -> Int {
                exit(90)
            }
            func write(_ change: IdleSleepChange, lease: FileHandle, maintenance: FileHandle) -> HelperCommandOutcome { exit(91) }
        }
        struct ForbiddenMaintenance: MaintenanceLockProviding {
            func acquire() throws -> MaintenanceLease { exit(92) }
        }
        final class FixtureLease: LockLifetimeLease, @unchecked Sendable {}
        final class FixtureController: IdleLockControlling, @unchecked Sendable {
            let actions = Value(0)
            let observations = Value(0)
            func status() throws -> IdleLockStatus {
                observations.set(observations.get() + 1)
                return IdleLockStatus(phase: .off, message: "fake")
            }
            func perform(_ request: IdleLockRequest) throws -> IdleLockResult {
                actions.set(actions.get() + 1)
                return IdleLockResult(succeeded: true, message: "fake", status: IdleLockStatus(phase: .off, message: "fake"))
            }
        }

        @objc protocol MarkerXPC {
            func marker(reply: @escaping @Sendable (Int) -> Void)
        }
        final class Marker: NSObject, MarkerXPC {
            let value: Int
            init(_ value: Int) { self.value = value }
            func marker(reply: @escaping @Sendable (Int) -> Void) { reply(value) }
        }
        final class MarkerDelegate: NSObject, NSXPCListenerDelegate {
            let requirement: String
            let value: Int
            init(_ requirement: String, _ value: Int) { self.requirement = requirement; self.value = value }
            func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                guard connection.effectiveUserIdentifier == getuid(), getuid() != 0 else { return false }
                connection.setCodeSigningRequirement(requirement)
                connection.exportedInterface = NSXPCInterface(with: MarkerXPC.self)
                connection.exportedObject = Marker(value)
                connection.activate()
                return true
            }
        }

        @objc protocol AttackXPC {
            func tryPublication(_ publisher: NSXPCListenerEndpoint, reply: @escaping @Sendable (Bool) -> Void)
            func performLock(_ native: NSXPCListenerEndpoint, reply: @escaping @Sendable (Bool) -> Void)
        }
        final class Attack: NSObject, AttackXPC {
            let policy: [String: String]
            init(_ policy: [String: String]) { self.policy = policy }
            func tryPublication(_ publisher: NSXPCListenerEndpoint, reply: @escaping @Sendable (Bool) -> Void) {
                let connection = NSXPCConnection(listenerEndpoint: publisher)
                connection.setCodeSigningRequirement(policy["helper"]!)
                connection.remoteObjectInterface = LockPublisherXPCInterface().make()
                let done = DispatchSemaphore(value: 0)
                let accepted = Value(false)
                connection.invalidationHandler = { done.signal() }
                connection.activate()
                defer { connection.invalidate() }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! any HearthLockPublisherXPC
                let fake = NSXPCListener.anonymous()
                defer { fake.invalidate() }
                proxy.publishLockEndpoint(fake.endpoint) { accepted.set($0); done.signal() }
                let completed = done.wait(timeout: .now() + 5) == .success
                reply(completed && !accepted.get())
            }
            func performLock(_ native: NSXPCListenerEndpoint, reply: @escaping @Sendable (Bool) -> Void) {
                do {
                    let peers = LockPeerRequirements(
                        app: try ValidatedCodeRequirement(policy["app"]!),
                        clients: try ValidatedCodeRequirement("(\(policy["app"]!)) or (\(policy["cli"]!))")
                    )
                    let client = IdleLockClient(
                        requirements: { peers }, fetch: { native },
                        launch: { _ in throw IdleLockClientError.unavailable("No installed launch in fixture") }
                    )
                    reply(try client.perform(IdleLockRequest(action: .on)).succeeded)
                } catch { reply(false) }
            }
        }
        final class AttackDelegate: NSObject, NSXPCListenerDelegate {
            let policy: [String: String]
            init(_ policy: [String: String]) { self.policy = policy }
            func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
                guard connection.effectiveUserIdentifier == getuid(), getuid() != 0 else { return false }
                connection.setCodeSigningRequirement(policy["app"]!)
                connection.exportedInterface = NSXPCInterface(with: AttackXPC.self)
                connection.exportedObject = Attack(policy)
                connection.activate()
                return true
            }
        }

        @main struct Probe {
            static func main() {
                do { try Probe().run() }
                catch {
                    print("FAIL \(error)")
                    exit(1)
                }
            }
            func run() throws {
                guard getuid() != 0, getuid() == geteuid() else { exit(10) }
                let role = Bundle.main.bundleIdentifier!.split(separator: ".").last!
                var parent = Bundle.main.bundleURL.deletingLastPathComponent()
                if role != "app" {
                    for _ in 0..<3 { parent.deleteLastPathComponent() }
                }
                let policy = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: parent.appendingPathComponent("fixture-policy.plist")), format: nil
                ) as! [String: String]
                if role == "helper" {
                    let worker = HelperWorker(backend: ForbiddenBackend(), maintenance: ForbiddenMaintenance())
                    let mixed = try ValidatedCodeRequirement("(\(policy["app"]!)) or (\(policy["cli"]!))")
                    let delegate = HelperListenerDelegate(
                        worker: worker, requirement: mixed,
                        appRequirement: try ValidatedCodeRequirement(policy["app"]!)
                    )
                    let listener = NSXPCListener.service()
                    listener.delegate = delegate
                    withExtendedLifetime(delegate) { listener.resume(); RunLoop.current.run() }
                    return
                }
                if role == "cli" {
                    let delegate = AttackDelegate(policy)
                    let listener = NSXPCListener.service()
                    listener.delegate = delegate
                    withExtendedLifetime(delegate) { listener.resume(); RunLoop.current.run() }
                    return
                }
                try host(policy)
            }

            func host(_ policy: [String: String]) throws {
                let helper = policy["helper"]!
                let app = policy["app"]!
                let cli = policy["cli"]!
                let client = HelperClient(connectionFactory: {
                    let connection = NSXPCConnection(serviceName: "dev.hearth.tests.helper")
                    connection.remoteObjectInterface = HelperXPCInterface().make()
                    connection.setCodeSigningRequirement(helper)
                    return connection
                }, publisherConnectionFactory: { endpoint in
                    let connection = NSXPCConnection(listenerEndpoint: endpoint)
                    connection.remoteObjectInterface = LockPublisherXPCInterface().make()
                    connection.setCodeSigningRequirement(helper)
                    return connection
                })
                let bootstrap = NSXPCConnection(serviceName: "dev.hearth.tests.helper")
                bootstrap.remoteObjectInterface = HelperXPCInterface().make()
                bootstrap.setCodeSigningRequirement(helper)
                bootstrap.activate()
                let response = Value<NSXPCListenerEndpoint?>(nil)
                let received = DispatchSemaphore(value: 0)
                let broker = bootstrap.remoteObjectProxyWithErrorHandler { _ in received.signal() } as! any HearthHelperXPC
                broker.publisherEndpoint { response.set($0); received.signal() }
                let bootstrapped = received.wait(timeout: .now() + 8) == .success
                let helperPID = bootstrap.processIdentifier
                defer {
                    bootstrap.invalidate()
                    if helperPID > 0, helperPID != getpid() { _ = Darwin.kill(helperPID, SIGTERM) }
                }
                guard bootstrapped, let publisher = response.get() else { throw failure(20) }
                guard helperPID > 0, helperPID != getpid() else { throw failure(21) }

                let first = NSXPCListener.anonymous()
                let second = NSXPCListener.anonymous()
                let firstDelegate = MarkerDelegate("(\(app)) or (\(cli))", 1)
                let secondDelegate = MarkerDelegate("(\(app)) or (\(cli))", 2)
                first.delegate = firstDelegate; second.delegate = secondDelegate
                first.setConnectionCodeSigningRequirement(firstDelegate.requirement)
                second.setConnectionCodeSigningRequirement(secondDelegate.requirement)
                first.activate(); second.activate()
                defer {
                    first.invalidate(); second.invalidate()
                    withExtendedLifetime((firstDelegate, secondDelegate)) {}
                }
                let old = try client.publishLockEndpoint(first.endpoint)
                guard marker(try client.lockEndpoint(), requirement: app) == 1 else { throw failure(22) }
                let new = try client.publishLockEndpoint(second.endpoint)
                old.invalidate()
                Thread.sleep(forTimeInterval: 0.1)
                guard marker(try client.lockEndpoint(), requirement: app) == 2 else { throw failure(23) }

                let attacker = NSXPCConnection(serviceName: "dev.hearth.tests.cli")
                attacker.remoteObjectInterface = NSXPCInterface(with: AttackXPC.self)
                attacker.setCodeSigningRequirement(cli)
                attacker.activate()
                let attackDone = DispatchSemaphore(value: 0)
                let rejected = Value(false)
                let attack = attacker.remoteObjectProxyWithErrorHandler { _ in attackDone.signal() } as! any AttackXPC
                attack.tryPublication(publisher) { rejected.set($0); attackDone.signal() }
                let attacked = attackDone.wait(timeout: .now() + 8) == .success
                let cliPID = attacker.processIdentifier
                defer {
                    attacker.invalidate()
                    if cliPID > 0, cliPID != getpid(), cliPID != helperPID { _ = Darwin.kill(cliPID, SIGTERM) }
                }
                guard attacked, rejected.get() else { throw failure(24) }
                guard cliPID > 0, cliPID != getpid(), cliPID != helperPID else { throw failure(25) }
                guard marker(try client.lockEndpoint(), requirement: app) == 2 else { throw failure(26) }
                guard marker(try client.lockEndpoint(), requirement: cli) == nil else { throw failure(27) }

                let wrong = HelperClient(connectionFactory: {
                    let connection = NSXPCConnection(serviceName: "dev.hearth.tests.helper")
                    connection.remoteObjectInterface = HelperXPCInterface().make()
                    connection.setCodeSigningRequirement(helper)
                    return connection
                }, publisherConnectionFactory: { endpoint in
                    let connection = NSXPCConnection(listenerEndpoint: endpoint)
                    connection.remoteObjectInterface = LockPublisherXPCInterface().make()
                    connection.setCodeSigningRequirement(cli)
                    return connection
                })
                var acceptedWrongPeer = false
                do {
                    let unexpected = try wrong.publishLockEndpoint(first.endpoint)
                    unexpected.invalidate()
                    acceptedWrongPeer = true
                } catch {}
                guard !acceptedWrongPeer else { throw failure(28) }
                new.invalidate()
                var endpoint: NSXPCListenerEndpoint?
                for _ in 0..<50 {
                    endpoint = try client.lockEndpoint()
                    if endpoint == nil { break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                guard endpoint == nil else { throw failure(29) }
                let peers = LockPeerRequirements(
                    app: try ValidatedCodeRequirement(app),
                    clients: try ValidatedCodeRequirement("(\(app)) or (\(cli))")
                )
                let controller = FixtureController()
                let native = IdleLockListener(
                    controller: controller, requirements: { peers }, acquireLease: { FixtureLease() },
                    publish: { try client.publishLockEndpoint($0) }
                )
                try native.start()
                defer { _ = native.stop() }
                guard let nativeEndpoint = try client.lockEndpoint() else { throw failure(30) }
                let actionDone = DispatchSemaphore(value: 0)
                let succeeded = Value(false)
                attack.performLock(nativeEndpoint) { succeeded.set($0); actionDone.signal() }
                guard actionDone.wait(timeout: .now() + 8) == .success, succeeded.get(),
                      controller.actions.get() == 1, controller.observations.get() == 0 else { throw failure(31) }
                print("PASS cross-process app-only publication: app \(getpid()), helper \(helperPID), CLI \(cliPID); CLI rejected; replacement retained; peer pins rejected; invalidation removed; same-connection UID handshake; no power work")
            }

            func marker(_ endpoint: NSXPCListenerEndpoint?, requirement: String) -> Int? {
                guard let endpoint else { return nil }
                let connection = NSXPCConnection(listenerEndpoint: endpoint)
                connection.setCodeSigningRequirement(requirement)
                connection.remoteObjectInterface = NSXPCInterface(with: MarkerXPC.self)
                let done = DispatchSemaphore(value: 0)
                let value = Value<Int?>(nil)
                connection.invalidationHandler = { done.signal() }
                connection.activate()
                defer { connection.invalidate() }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! any MarkerXPC
                proxy.marker { value.set($0); done.signal() }
                guard done.wait(timeout: .now() + 3) == .success else { return nil }
                return value.get()
            }

            func failure(_ code: Int) -> NSError { NSError(domain: "BrokerProbe", code: code) }
        }
        """#
    }
}
