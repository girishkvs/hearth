import CoreFoundation
import Darwin
import Foundation

final class FakeHost: Host {
    var wrongOwners: Set<String> = []
    var acls: Set<String> = []
    var registered = false
    var serviceFailure = false
    var bootstrapFailure = false
    var badSignature = false
    var universal = false
    var injectedEntitlements = false
    var entitlementOverrides: [String: CommandResult] = [:]
    var candidateHashOnly = false
    var adminDirectories: Set<String> = []
    var copyObserver: ((String) throws -> Void)?
    var ownershipObserver: (() throws -> Void)?
    var serviceObserver: ((String) throws -> Void)?
    var verificationObserver: (() throws -> Void)?
    var creationObserver: ((Int32, String, stat) throws -> Void)?
    var ownershipFailure = false
    var inheritedGroupPaths: Set<String> = []
    var nativeInheritedGroup: gid_t = 80
    var descriptorOwners: [String: (uid_t, gid_t)] = [:]
    var descriptorOwnershipChanges: [String] = []
    var commands: [(String, [String])] = []

    override func ownership(_ path: String, _ metadata: stat) -> (uid_t, gid_t) {
        if wrongOwners.contains(path) { return (501, 20) }
        if let changed = descriptorOwners[nodeID(metadata)] { return changed }
        if inheritedGroupPaths.contains(path) {
            return (0, metadata.st_gid == nativeInheritedGroup ? 80 : metadata.st_gid)
        }
        return (0, adminDirectories.contains(path) ? 80 : 0)
    }

    func nodeID(_ info: stat) -> String { "\(info.st_dev):\(info.st_ino)" }

    override func createDirectory(_ name: String, parent: Int32, mode: mode_t) throws -> stat {
        let made = try super.createDirectory(name, parent: parent, mode: mode)
        try creationObserver?(parent, name, made)
        return made
    }

    override func setOwnership(_ descriptor: Int32, uid: uid_t, gid: gid_t) throws {
        if ownershipFailure { throw InstallFailure.refused("Fake fchown failure") }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw InstallFailure.refused("Missing test descriptor") }
        let id = nodeID(info)
        // Exercise the real descriptor syscall without requiring root. Logical root
        // ownership changes only after production explicitly requests fchown.
        try super.setOwnership(descriptor, uid: getuid(), gid: getgid())
        descriptorOwners[id] = (uid == uid_t.max ? 0 : uid, gid)
        descriptorOwnershipChanges.append(id)
    }

    override func hasACL(_ path: String) throws -> Bool {
        if acls.contains(path) { return true }
        return try super.hasACL(path)
    }

    override func run(_ executable: String, _ arguments: [String], standardOutputOnly: Bool = false) throws -> CommandResult {
        commands.append((executable, arguments))
        if executable == "/usr/bin/lipo" { return CommandResult(status: 0, output: universal ? "arm64 x86_64\n" : "arm64\n") }
        if executable == "/usr/bin/codesign" {
            if arguments.contains("--verify") { try verificationObserver?() }
            if badSignature && arguments.contains("--verify") { return CommandResult(status: 1, output: "invalid signature") }
            if arguments.contains("--entitlements") {
                let path = arguments.last!
                guard arguments.contains("--xml") else {
                    return CommandResult(status: 0, output: "[Dict] {\n\t[key] com.apple.security.automation.apple-events\n\t[value] [Bool] true\n}\n")
                }
                let diagnostic = standardOutputOnly ? "" : "Executable=\(path)\n"
                if let result = entitlementOverrides[path] {
                    return CommandResult(status: result.status, output: diagnostic + result.output)
                }
                var values: [String: Bool] = [:]
                if injectedEntitlements {
                    values["com.apple.security.get-task-allow"] = true
                } else if path.hasSuffix("/HearthApp") {
                    let contents = try Data(contentsOf: URL(fileURLWithPath: path))
                    if contents == Data("fake signed Automation release binary".utf8) {
                        values["com.apple.security.automation.apple-events"] = true
                    }
                }
                // Empty-entitlement signatures can yield no data rather than <dict/>.
                if values.isEmpty { return CommandResult(status: 0, output: diagnostic) }
                let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
                return CommandResult(status: 0, output: diagnostic + String(decoding: data, as: UTF8.self))
            }
            if arguments.contains("--verbose=4") {
                let path = arguments.last!
                let identifier = path.hasSuffix("/hearth") ? "dev.girishkvs.hearth.cli" :
                    path.hasSuffix("/HearthApp") ? "dev.girishkvs.hearth" :
                    path.hasSuffix("/installer-tool") ? "dev.girishkvs.hearth.installer" : "dev.girishkvs.hearth.helper"
                let hash = candidateHashOnly ? "CandidateCDHashFull=" + String(repeating: "a", count: 64) :
                    "CDHash=" + String(repeating: "a", count: 40)
                return CommandResult(status: 0, output: "Identifier=\(identifier)\nCodeDirectory v=20500 flags=0x10002(adhoc,runtime)\n\(hash)\n")
            }
            return CommandResult(status: 0, output: "")
        }
        if executable == "/bin/launchctl" {
            if serviceFailure { return CommandResult(status: 1, output: "Permission denied") }
            if arguments.first == "bootstrap" {
                try serviceObserver?("bootstrap")
                if bootstrapFailure { return CommandResult(status: 5, output: "Input/output error") }
                registered = true
                return CommandResult(status: 0, output: "")
            }
            if arguments.first == "bootout" {
                try serviceObserver?("bootout")
                registered = false
                return CommandResult(status: 0, output: "")
            }
            return registered ? CommandResult(status: 0, output: "service = {}\n") :
                CommandResult(status: 113, output: "Could not find service \"dev.girishkvs.hearth.helper\" in domain for system\n")
        }
        if executable == "/usr/sbin/pkgutil" { return CommandResult(status: 0, output: "Forgot package") }
        if executable == "/usr/bin/ditto" {
            let source = arguments[arguments.count - 2]
            let destination = arguments.last!
            guard source.contains("/hearth-fake-"),
                  destination.contains("/hearth-fake-") else { throw InstallFailure.refused("Test copy escaped fake filesystem") }
            try copyObserver?(destination)
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            return CommandResult(status: 0, output: "")
        }
        if executable == "/usr/sbin/chown" {
            guard Array(arguments.prefix(4)) == ["-h", "-R", "-P", "0:0"],
                  arguments.last!.contains("/hearth-fake-") else { throw InstallFailure.refused("Unsafe test ownership command") }
            try ownershipObserver?()
            return CommandResult(status: 0, output: "")
        }
        throw InstallFailure.refused("Test blocked unexpected external execution: \(executable) \(arguments)")
    }
}

final class InstallerTests {
    let files = FileManager.default
    var passed = 0
    var temporary = URL(fileURLWithPath: "/")
    var repository = ""

    func assert(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw InstallFailure.refused("TEST FAILED: \(label)") }
        passed += 1
        print("PASS: \(label)")
    }

    func refused(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { passed += 1; print("PASS: \(label)"); return }
        throw InstallFailure.refused("TEST FAILED (accepted): \(label)")
    }

    func write(_ data: Data, _ path: String, mode: Int = 0o644) throws {
        try files.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o755])
        try data.write(to: URL(fileURLWithPath: path))
        try files.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func plist<T: Encodable>(_ value: T, _ path: String) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try write(encoder.encode(value), path)
    }

    func fixture(_ name: String) throws -> (Validator, FakeHost) {
        let root = temporary.appendingPathComponent(name).path
        let host = FakeHost()
        let validator = Validator(root: root, host: host)
        host.adminDirectories = [validator.path("/Applications"), validator.path("/Library/Application Support")]
        for item in ["/", "/Applications", "/Library", "/Library/Application Support", "/usr/local/bin",
                     "/private/var/db/receipts", "/Library/PrivilegedHelperTools", "/Library/LaunchDaemons",
                     validator.support] {
            try files.createDirectory(atPath: validator.path(item), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o755])
        }
        try files.setAttributes([.posixPermissions: 0o775], ofItemAtPath: validator.path("/Applications"))
        try files.createSymbolicLink(atPath: validator.path("/var"), withDestinationPath: "private/var")
        return (validator, host)
    }

    func payload(_ validator: Validator, protocolVersion: Int = 2, appAutomation: Bool = false) throws {
        for relative in ["/Contents/MacOS/HearthApp", "/Contents/MacOS/hearth"] {
            let legacyApp = relative.hasSuffix("/HearthApp") && appAutomation
            let contents = legacyApp ? "fake signed Automation release binary" : "fake signed release binary"
            try write(Data(contents.utf8), validator.path(validator.app + relative), mode: 0o755)
        }
        try write(Data("sealed web resource".utf8), validator.path(validator.app + "/Contents/Resources/web.html"))
        try write(Data("fake helper".utf8), validator.path(validator.helper), mode: 0o755)
        try files.copyItem(atPath: repository + "/Packaging/dev.girishkvs.hearth.helper.plist", toPath: validator.path(validator.daemon))
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: validator.path(validator.daemon))
        try files.createSymbolicLink(atPath: validator.path(validator.link), withDestinationPath: validator.app + "/Contents/MacOS/hearth")
        let hash = String(repeating: "a", count: 40)
        try plist(Authorization(FormatVersion: 1, ProtocolVersion: protocolVersion, AppCodeHash: hash, CLICodeHash: hash,
                                HelperCodeHash: hash, BuildIdentifier: "test-build"), validator.path(validator.policy))
        try plist(validator.inventory(build: "test-build", enforceOwnership: false), validator.path(validator.receipt))
    }

    func appleReceipt(_ validator: Validator) throws {
        for identifier in validator.packageIDs() {
            let receipt = validator.path("/private/var/db/receipts/\(identifier)")
            let data = try PropertyListSerialization.data(fromPropertyList: ["PackageIdentifier": identifier], format: .xml, options: 0)
            try write(data, receipt + ".plist")
            try write(Data("fake BOM".utf8), receipt + ".bom")
        }
    }

    func extractionFor(_ validator: Validator, name: String) throws -> URL {
        let extraction = temporary.appendingPathComponent(name)
        try files.createDirectory(at: extraction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let payload = extraction.appendingPathComponent("payload").path
        for target in validator.payloadRoots() + [validator.receipt] {
            let destination = payload + target
            try files.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try files.copyItem(atPath: validator.path(target), toPath: destination)
        }
        try files.copyItem(atPath: validator.path(validator.receipt), toPath: extraction.appendingPathComponent("payload-receipt.plist").path)
        return extraction
    }

    func assertExclusiveLeaseHeld(_ lock: String, phase: String) throws {
        let descriptor = open(lock, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw InstallFailure.refused("Cannot inspect test lease") }
        let acquired = flock(descriptor, LOCK_SH | LOCK_NB) == 0
        close(descriptor)
        try assert(!acquired, "same exclusive maintenance lease is held during \(phase)")
    }

    func entitlementXML(_ values: Any) throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    func testAutomationEntitlements() throws {
        let key = "com.apple.security.automation.apple-events"
        try assert(!files.fileExists(atPath: repository + "/Packaging/AppEntitlements.plist"),
                   "obsolete app Automation signing input is removed")
        let emptyEntitlements = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: repository + "/Packaging/EmptyEntitlements.plist")),
            format: nil) as? [String: Any]
        try assert(emptyEntitlements?.isEmpty == true, "CLI and helper signing input remains empty")
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: repository + "/Packaging/Info.plist")),
            format: nil) as? [String: Any]
        try assert(info?["NSAppleEventsUsageDescription"] == nil, "current app has no Apple Events usage description")

        let (target, host) = try fixture("app-entitlements")
        try payload(target)
        let app = target.path(target.app + "/Contents/MacOS/HearthApp")
        try target.validateSignatures()
        try assert(true, "new app, CLI and helper have no entitlements")
        try assert(target.preflight() != nil, "new empty-entitlement app verifies for installed maintenance")
        let emptyXML = try entitlementXML([String: Bool]())
        for output in ["", " \n\t", emptyXML] {
            host.entitlementOverrides[app] = CommandResult(status: 0, output: output)
            try target.validateSignatures()
            try assert(target.preflight() != nil, "fully verified legacy app can have no entitlements during maintenance")
        }
        host.badSignature = true
        try refused("legacy empty app still requires its full signature") { _ = try target.preflight() }
        host.badSignature = false
        host.entitlementOverrides.removeAll()

        let invalid: [(String, Any)] = [
            ("false", [key: false]),
            ("string", [key: "true"]),
            ("integer one", [key: 1]),
            ("real one", [key: 1.0]),
            ("array value", [key: [true]]),
            ("additional key", [key: true, "com.apple.security.get-task-allow": true]),
            ("unrelated grant", ["com.apple.security.cs.disable-library-validation": true]),
            ("array root", [key])
        ]
        for (label, values) in invalid {
            host.entitlementOverrides[app] = CommandResult(status: 0, output: try entitlementXML(values))
            try refused("new app rejects \(label) entitlement property list") { try target.validateSignatures() }
            try refused("installed app rejects \(label) entitlement property list") { _ = try target.preflight() }
        }
        for output in ["not a property list", "<plist><dict>", "Executable=\(app)\n", "[Dict] {}"] {
            host.entitlementOverrides[app] = CommandResult(status: 0, output: output)
            try refused("malformed/diagnostic/abstract entitlement output is not an empty grant") {
                _ = try target.preflight()
            }
        }
        host.entitlementOverrides[app] = CommandResult(status: 1, output: "")
        try refused("failed codesign entitlement extraction is not accepted as empty") { _ = try target.preflight() }
        host.entitlementOverrides.removeAll()
        let automationXML = try entitlementXML([key: true])
        host.entitlementOverrides[app] = CommandResult(status: 0, output: automationXML)
        try refused("new app cannot carry obsolete Automation grant") { try target.validateSignatures() }
        try assert(target.preflight() != nil, "verified installed legacy Automation app remains eligible for update/removal")
        host.entitlementOverrides.removeAll()
        for relative in [target.app + "/Contents/MacOS/hearth", target.helper] {
            let path = target.path(relative)
            host.entitlementOverrides[path] = CommandResult(status: 0, output: emptyXML)
            try target.validateSignatures()
            try assert(true, "CLI/helper also accept a valid empty entitlement dictionary: \(relative)")
            host.entitlementOverrides[path] = CommandResult(status: 0, output: automationXML)
            try refused("new CLI/helper cannot carry the app Automation grant: \(relative)") { try target.validateSignatures() }
            try refused("maintenance cannot carry Automation on CLI/helper: \(relative)") { _ = try target.preflight() }
            host.entitlementOverrides.removeAll()
        }
        host.entitlementOverrides[target.path("/installer-tool")] = CommandResult(status: 0, output: automationXML)
        try refused("embedded maintenance tool cannot carry the app Automation grant") {
            _ = try target.codeHash("/installer-tool", identifier: "dev.girishkvs.hearth.installer")
        }
    }

    func testStagedAutomationEntitlements() throws {
        let key = "com.apple.security.automation.apple-events"
        let (source, _) = try fixture("automation-staging-source")
        try payload(source)
        let extraction = try extractionFor(source, name: "automation-staging-extraction")
        let app = source.app + "/Contents/MacOS/HearthApp"
        let cases = [
            ("automation-app", app, try entitlementXML([key: true])),
            ("false-app", app, try entitlementXML([key: false])),
            ("extra-app", app, try entitlementXML([key: true, "com.apple.security.get-task-allow": true])),
            ("cli-grant", source.app + "/Contents/MacOS/hearth", try entitlementXML([key: true])),
            ("helper-grant", source.helper, try entitlementXML([key: true]))
        ]
        for (label, relative, output) in cases {
            let (installed, host) = try fixture("automation-staging-\(label)")
            try payload(installed, appAutomation: false)
            let oldReceipt = try Data(contentsOf: URL(fileURLWithPath: installed.path(installed.receipt)))
            let maintenance = Maintenance(validator: installed, extraction: extraction)
            try write(Data(), installed.path(maintenance.lock), mode: 0o600)
            try maintenance.run("setup-preflight")
            host.ownershipObserver = {
                let staged = installed.path(maintenance.staging + "/payload" + relative)
                host.entitlementOverrides[staged] = CommandResult(status: 0, output: output)
            }
            try refused("staging rejects obsolete or unexpected grants: \(label)") {
                try maintenance.run("setup-postflight")
            }
            try assert(try Data(contentsOf: URL(fileURLWithPath: installed.path(installed.receipt))) == oldReceipt &&
                       installed.preflight() != nil,
                       "invalid staged \(label) leaves the fully verified old installation untouched")
            try assert(!host.commands.contains { $0.0 == "/bin/launchctl" && $0.1.first == "bootstrap" },
                       "invalid staged \(label) never activates a new helper")
        }
    }

    func testProtocolUpgradePreservesActiveUserState() throws {
        for (protocolVersion, appAutomation) in [(1, false), (2, false), (2, true)] {
            let suffix = "\(protocolVersion)-\(appAutomation)"
            let (installed, host) = try fixture("legacy-installed-\(suffix)")
            try payload(installed, protocolVersion: protocolVersion, appAutomation: appAutomation)
            try assert(installed.preflight() != nil,
                       "verified empty-app protocol \(protocolVersion) installation remains eligible for maintenance")
            let legacyExtraction = try extractionFor(installed, name: "legacy-protocol-extraction-\(suffix)")
            let (legacyTarget, legacyHost) = try fixture("legacy-protocol-target-\(suffix)")
            let legacyMaintenance = Maintenance(validator: legacyTarget, extraction: legacyExtraction)
            if protocolVersion == 1 || appAutomation {
                try refused("new package cannot enroll old protocol or Automation app") {
                    try installed.validateSignatures()
                }
                try refused("legacy package source refused before creating maintenance state") {
                    try legacyMaintenance.run("setup-preflight")
                }
            } else {
                try installed.validateSignatures()
            }
            try assert(legacyHost.commands.allSatisfy { ["/usr/bin/lipo", "/usr/bin/codesign"].contains($0.0) } &&
                       legacyTarget.metadata(legacyMaintenance.marker) == nil &&
                       legacyTarget.metadata(legacyMaintenance.lock) == nil,
                       "legacy source refusal never reaches service/copy tools or creates maintenance state")

            let (source, _) = try fixture("automation-upgrade-source-\(suffix)")
            try payload(source)
            let extraction = try extractionFor(source, name: "automation-upgrade-extraction-\(suffix)")
            let maintenance = Maintenance(validator: installed, extraction: extraction)
            let statePath = installed.path("/Users/test/Library/Application Support/Hearth/state.json")
            let activeState = Data(#"{"version":1,"profiles":{"battery":{"override":{"original":1,"applied":0}}}}"#.utf8)
            try write(activeState, statePath, mode: 0o600)
            try write(Data(), installed.path(maintenance.lock), mode: 0o600)
            host.registered = true
            try maintenance.run("setup-preflight")
            try assert(try Data(contentsOf: URL(fileURLWithPath: statePath)) == activeState,
                       "protocol \(protocolVersion) update preflight preserves raw active System 0/original 1 state")
            try maintenance.run("setup-postflight")
            try installed.validateSignatures()
            let policy = try PropertyListDecoder().decode(
                Authorization.self, from: Data(contentsOf: URL(fileURLWithPath: installed.path(installed.policy))))
            try assert(policy.FormatVersion == 1 && policy.ProtocolVersion == 2,
                       "explicit update enrolls no-entitlement app with IPC 2 and policy format 1")
            try assert(try Data(contentsOf: URL(fileURLWithPath: statePath)) == activeState,
                       "protocol \(protocolVersion) update leaves raw user state untouched for unprivileged migration")
            try assert(!host.commands.contains { $0.0.contains("pmset") || $0.0.contains("open") },
                       "legacy upgrade does not run power commands or open Installer")

            let (removal, removalHost) = try fixture("legacy-removal-\(suffix)")
            try payload(removal, protocolVersion: protocolVersion, appAutomation: appAutomation)
            let remove = Maintenance(validator: removal, extraction: temporary)
            try write(Data(), removal.path(remove.lock), mode: 0o600)
            let removalState = removal.path("/Users/test/Library/Application Support/Hearth/state.json")
            try write(activeState, removalState, mode: 0o600)
            removalHost.registered = true
            try remove.run("remove-preflight")
            try remove.run("remove-postflight")
            try assert(removal.metadata(removal.app) == nil && !removalHost.registered &&
                       Data(contentsOf: URL(fileURLWithPath: removalState)) == activeState,
                       "verified empty-app protocol \(protocolVersion) removal remains eligible and preserves raw state")
        }

        let (future, _) = try fixture("future-protocol")
        try payload(future, protocolVersion: 3)
        try refused("future installed protocol refused despite matching inventory") { _ = try future.preflight() }
    }

    func run() throws {
        guard getuid() != 0,
              CommandLine.arguments.count >= 2 else { throw InstallFailure.refused("Tests require a normal user and repository path") }
        repository = CommandLine.arguments[1]
        temporary = files.temporaryDirectory.appendingPathComponent("hearth-fake-\(UUID().uuidString)")
        try files.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: temporary) }

        let (fresh, _) = try fixture("fresh")
        try assert(fresh.preflight() == nil, "fresh fixed-layout preflight; stock admin-writable Applications accepted")
        try testCreatedOwnership()
        try testSupportRepair()
        try testScriptOnlyReceipts()
        try testAutomationEntitlements()
        try testStagedAutomationEntitlements()
        try testProtocolUpgradePreservesActiveUserState()
        try write(Data("foreign".utf8), fresh.path(fresh.helper))
        try refused("foreign helper collision") { _ = try fresh.preflight() }
        let (hostile, _) = try fixture("hostile-ancestor")
        try files.moveItem(atPath: hostile.path("/Library"), toPath: hostile.path("/SavedLibrary"))
        try files.createSymbolicLink(atPath: hostile.path("/Library"), withDestinationPath: hostile.path("/SavedLibrary"))
        try refused("symlinked protected ancestor refused before writes") { _ = try hostile.preflight() }

        let (installed, host) = try fixture("installed")
        try payload(installed)
        try appleReceipt(installed)
        try assert(installed.preflight() != nil, "verified protected inventory permits explicit update")
        let protectedReceipt = try Data(contentsOf: URL(fileURLWithPath: installed.path(installed.receipt)))
        try write(Data("corrupt inventory".utf8), installed.path(installed.receipt))
        try refused("corrupt protected receipt") { _ = try installed.preflight() }
        try write(protectedReceipt, installed.path(installed.receipt))
        try files.moveItem(atPath: installed.path(installed.receipt), toPath: installed.path(installed.receipt + ".saved"))
        try files.createSymbolicLink(atPath: installed.path(installed.receipt), withDestinationPath: installed.path(installed.receipt + ".saved"))
        try refused("symlinked protected receipt") { _ = try installed.preflight() }
        try files.removeItem(atPath: installed.path(installed.receipt))
        try files.moveItem(atPath: installed.path(installed.receipt + ".saved"), toPath: installed.path(installed.receipt))
        host.badSignature = true
        try refused("full signature failure") { _ = try installed.preflight() }
        host.badSignature = false
        host.universal = true
        try refused("universal artifact not silently reduced to one slice") { _ = try installed.preflight() }
        host.universal = false
        host.injectedEntitlements = true
        try refused("injection entitlement refused") { _ = try installed.preflight() }
        host.injectedEntitlements = false
        host.candidateHashOnly = true
        try refused("CandidateCDHashFull is not the enrolled 20-byte CDHash") { _ = try installed.preflight() }
        host.candidateHashOnly = false
        let addition = installed.path(installed.app + "/foreign.txt")
        try write(Data("foreign".utf8), addition)
        try refused("unlisted app addition") { _ = try installed.preflight() }
        try files.removeItem(atPath: addition)
        let resource = installed.path(installed.app + "/Contents/Resources/web.html")
        try write(Data("modified".utf8), resource)
        try refused("modified signed inventory") { _ = try installed.preflight() }
        try write(Data("sealed web resource".utf8), resource)
        host.wrongOwners.insert(installed.path(installed.helper))
        try refused("user-owned helper") { _ = try installed.preflight() }
        host.wrongOwners.removeAll()
        host.acls.insert(installed.path(installed.policy))
        try refused("authorization ACL") { _ = try installed.preflight() }
        host.acls.removeAll()
        try files.setAttributes([.posixPermissions: 0o666], ofItemAtPath: installed.path(installed.policy))
        try refused("writable authorization policy") { _ = try installed.preflight() }
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installed.path(installed.policy))
        try files.removeItem(atPath: installed.path(installed.link))
        try files.createSymbolicLink(atPath: installed.path(installed.link), withDestinationPath: "/tmp/foreign")
        try refused("foreign CLI symlink") { _ = try installed.preflight() }
        try files.removeItem(atPath: installed.path(installed.link))
        try files.createSymbolicLink(atPath: installed.path(installed.link), withDestinationPath: installed.app + "/Contents/MacOS/hearth")
        try files.createSymbolicLink(atPath: installed.path(installed.app + "/Contents/Resources/escape"), withDestinationPath: temporary.path)
        try refused("symlink inside app") { _ = try installed.preflight() }
        try files.removeItem(atPath: installed.path(installed.app + "/Contents/Resources/escape"))
        let bogus = Inventory(formatVersion: 1, buildIdentifier: "x", entries: [
            Entry(path: installed.app + "/../Other.app", kind: "directory", mode: 0o755, digest: "")])
        try refused("inventory path traversal") { _ = try installed.readInventory(PropertyListEncoder().encode(bogus)) }

        let extraction = try extractionFor(installed, name: "extraction")
        let maintenance = Maintenance(validator: installed, extraction: extraction)
        host.serviceFailure = true
        try refused("launchctl permission failure is not service absence") { _ = try maintenance.serviceStatus() }
        host.serviceFailure = false
        let lock = installed.path(maintenance.lock)
        try write(Data(), lock, mode: 0o600)
        let fd = open(lock, O_RDWR | O_NOFOLLOW)
        guard fd >= 0, flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw InstallFailure.refused("Cannot prepare busy lease fixture") }
        try refused("in-flight helper operation blocks maintenance") { try maintenance.run("setup-preflight") }
        flock(fd, LOCK_UN)
        close(fd)
        host.registered = true
        host.serviceObserver = { phase in
            try self.assertExclusiveLeaseHeld(lock, phase: phase)
            try installed.assertNode(maintenance.marker, kind: S_IFREG, mode: 0o644)
            try self.assert(true, "maintenance marker remains present during \(phase)")
        }
        try maintenance.run("setup-preflight")
        try installed.assertNode(maintenance.marker, kind: S_IFREG, mode: 0o644)
        try assert(maintenance.marker == "/Library/Application Support/Hearth/maintenance.plist",
                   "installer transaction record uses its fixed path and root0644 metadata")
        try assert(host.registered, "preinstall leaves old service running across the script boundary")
        try assert(try installed.metadata(installed.app) != nil, "preflight leaves old installed payload unchanged")
        try refused("incomplete maintenance refuses another installer") { try maintenance.run("setup-preflight") }
        let admitted = open(lock, O_RDONLY | O_NOFOLLOW)
        guard admitted >= 0, flock(admitted, LOCK_SH | LOCK_NB) == 0 else { throw InstallFailure.refused("Cannot simulate admitted helper batch") }
        let inherited = dup(admitted)
        guard inherited >= 0 else { throw InstallFailure.refused("Cannot simulate child lease inheritance") }
        close(admitted)
        try refused("inherited shared lease blocks maintenance after helper descriptor closes") { try maintenance.run("setup-postflight") }
        try assert(host.registered, "busy postinstall does not stop the old service")
        close(inherited)
        host.verificationObserver = {
            try self.assertExclusiveLeaseHeld(lock, phase: "postinstall signature verification")
        }
        host.copyObserver = { destination in
            let parent = (destination as NSString).deletingLastPathComponent
            let mode = try self.files.attributesOfItem(atPath: parent)[.posixPermissions] as? Int
            try self.assert(mode == 0o700, "copy occurs behind a root-only 0700 staging boundary")
            try self.assertExclusiveLeaseHeld(lock, phase: "private copy and replacement")
        }
        try maintenance.run("setup-postflight")
        try assert(host.registered, "postflight registers only verified installed payload")
        try assert(try installed.metadata(maintenance.marker) == nil, "successful setup clears maintenance marker")
        try assert(try installed.metadata(maintenance.staging) == nil, "successful setup removes only its empty staging directories")
        host.verificationObserver = nil

        let state = installed.path("/Users/test/Library/Application Support/Hearth/state.json")
        let journal = installed.path(installed.support + "/journal.json")
        try write(Data("user restore state".utf8), state)
        try write(Data("protected restore journal".utf8), journal, mode: 0o600)
        try maintenance.run("remove-preflight")
        try assert(host.registered, "removal preinstall does not stop service before continuous EX scope")
        host.verificationObserver = {
            try self.assertExclusiveLeaseHeld(lock, phase: "removal signature verification")
        }
        try maintenance.run("remove-postflight")
        host.verificationObserver = nil
        try assert(try installed.metadata(installed.app) == nil, "removal deletes verified app without recursive deletion")
        try assert(try Data(contentsOf: URL(fileURLWithPath: state)) == Data("user restore state".utf8), "removal preserves user state")
        try assert(try Data(contentsOf: URL(fileURLWithPath: journal)) == Data("protected restore journal".utf8), "removal preserves protected journal")
        try assert(try installed.metadata(maintenance.lock) != nil, "removal preserves operation lock inode")
        try assert(!host.commands.contains(where: { $0.0.contains("pmset") || $0.0.contains("open") }), "fake maintenance never invokes power tools or Installer")

        let (newInstall, newHost) = try fixture("fresh-install")
        let newMaintenance = Maintenance(validator: newInstall, extraction: extraction)
        try newMaintenance.run("setup-preflight")
        try assert(!newHost.registered, "fresh preflight does not bootstrap early")
        try newMaintenance.run("setup-postflight")
        try assert(true, "postinstall does not depend on Apple's receipt-write timing")
        try assert(newInstall.preflight() != nil, "fresh scripts-only setup has a verifiable installed inventory")
        try assert(try newInstall.metadata("/private/var/db/receipts/\(newInstall.packageID).plist") == nil,
                   "scripts-only installation is verified without a fabricated Apple receipt")
        try appleReceipt(newInstall)
        try files.removeItem(atPath: newInstall.path("/private/var/db/receipts/\(newInstall.packageID).bom"))
        try assert(newInstall.preflight() != nil, "scripts-only receipt may legitimately omit a BOM")
        try assert(newHost.registered, "fresh setup bootstraps only after published payload verifies")

        let hostileExtraction = temporary.appendingPathComponent("hostile-extraction")
        try files.createDirectory(at: hostileExtraction, withIntermediateDirectories: false)
        try files.copyItem(at: extraction.appendingPathComponent("payload-receipt.plist"),
                           to: hostileExtraction.appendingPathComponent("payload-receipt.plist"))
        try files.createSymbolicLink(atPath: hostileExtraction.appendingPathComponent("payload").path,
                                     withDestinationPath: newInstall.root)
        let (hostileSourceTarget, hostileSourceHost) = try fixture("hostile-source-target")
        let hostileSource = Maintenance(validator: hostileSourceTarget, extraction: hostileExtraction)
        try refused("symlinked package source root refused before reading payload") { try hostileSource.run("setup-preflight") }
        try assert(hostileSourceHost.commands.isEmpty, "hostile source never reaches copy or service tools")

        let (failedInstall, failedHost) = try fixture("bootstrap-failure")
        let failedMaintenance = Maintenance(validator: failedInstall, extraction: extraction)
        try failedMaintenance.run("setup-preflight")
        failedHost.bootstrapFailure = true
        try refused("bootstrap failure reports partial setup") { try failedMaintenance.run("setup-postflight") }
        try assert(try failedInstall.metadata(failedMaintenance.marker) != nil, "bootstrap failure preserves installer repair record")
        try refused("partial setup cannot silently restart installation") { try failedMaintenance.run("setup-preflight") }

        let (racedInstall, racedHost) = try fixture("raced-destination")
        let racedMaintenance = Maintenance(validator: racedInstall, extraction: extraction)
        try racedMaintenance.run("setup-preflight")
        let foreign = temporary.appendingPathComponent("foreign-directory").path
        try files.createDirectory(atPath: foreign, withIntermediateDirectories: false)
        let sentinel = foreign + "/untouched"
        try write(Data("foreign state".utf8), sentinel)
        racedHost.ownershipObserver = {
            try self.files.createSymbolicLink(atPath: racedInstall.path(racedInstall.app), withDestinationPath: foreign)
        }
        try refused("exclusive publish refuses raced Applications symlink") { try racedMaintenance.run("setup-postflight") }
        try assert(try Data(contentsOf: URL(fileURLWithPath: sentinel)) == Data("foreign state".utf8), "raced foreign destination remains untouched")
        try assert(try files.contentsOfDirectory(atPath: foreign) == ["untouched"], "copy never follows raced destination symlink")
        try assert(!racedHost.registered, "raced publish never bootstraps helper")

        for kind in ["file", "directory"] {
            let (collision, collisionHost) = try fixture("raced-\(kind)")
            let coordinator = Maintenance(validator: collision, extraction: extraction)
            try coordinator.run("setup-preflight")
            let leaf = collision.path(collision.app)
            let content = Data("foreign \(kind)".utf8)
            collisionHost.ownershipObserver = {
                if kind == "directory" {
                    try self.files.createDirectory(atPath: leaf, withIntermediateDirectories: false)
                    try self.write(content, leaf + "/untouched")
                } else {
                    try self.write(content, leaf)
                }
            }
            try refused("exclusive publish refuses raced \(kind) leaf") { try coordinator.run("setup-postflight") }
            let file = kind == "directory" ? leaf + "/untouched" : leaf
            try assert(try Data(contentsOf: URL(fileURLWithPath: file)) == content, "raced \(kind) contents are unchanged")
            if kind == "directory" {
                try assert(try files.contentsOfDirectory(atPath: leaf) == ["untouched"],
                           "publish cannot move app inside an existing destination directory")
            }
            try assert(collisionHost.commands.filter { $0.0 == "/usr/sbin/chown" }.allSatisfy {
                $0.1.last == collision.path(coordinator.staging + "/payload")
            }, "ownership changes target only protected private staging")
            try assert(!collisionHost.registered, "raced \(kind) never activates helper")
        }

        func testCreatedOwnership() throws {
            let (target, host) = try fixture("group-inheritance")
            let parentPath = target.path("/Library/Application Support")
            let childPath = target.path(target.support)
            try files.removeItem(atPath: childPath)
            var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
            _ = getgroups(Int32(groups.count), &groups)
            let inherited = groups.contains(80) ? gid_t(80) : getgid()
            guard chown(parentPath, uid_t.max, inherited) == 0 else {
                throw InstallFailure.refused("Cannot prepare native parent-group fixture")
            }
            host.nativeInheritedGroup = inherited
            host.inheritedGroupPaths = [parentPath, childPath]
            var parentBefore = stat()
            guard lstat(parentPath, &parentBefore) == 0 else { throw InstallFailure.refused("Missing parent fixture") }
            host.creationObserver = { _, _, made in
                try self.assert(made.st_gid == parentBefore.st_gid, "native mkdir inherits the actual parent group")
                try self.assert(host.ownership(childPath, made).1 == 80, "new root:admin child is not masked as root:wheel")
                try self.assert(host.descriptorOwnershipChanges.isEmpty, "inherited group is observed before any ownership syscall")
            }
            let maintenance = Maintenance(validator: target, extraction: temporary)
            try maintenance.createParents()
            try target.assertNode(target.support, kind: S_IFDIR, mode: 0o755)
            try assert(host.descriptorOwnershipChanges.count == 1, "new support directory normalized only through its checked descriptor")
            var parentAfter = stat()
            guard lstat(parentPath, &parentAfter) == 0 else { throw InstallFailure.refused("Missing parent after creation") }
            try assert(parentAfter.st_uid == parentBefore.st_uid && parentAfter.st_gid == parentBefore.st_gid &&
                       parentAfter.st_mode == parentBefore.st_mode && parentAfter.st_flags == parentBefore.st_flags,
                       "shared parent ownership, group, mode and flags stay unchanged")
            host.creationObserver = nil
            try maintenance.createParents()
            try assert(host.descriptorOwnershipChanges.count == 1, "existing valid directories are never rechowned")

            for path in [target.support + "/install-staging"] {
                try maintenance.createOwnedDirectory(path, mode: 0o700)
                try target.assertNode(path, kind: S_IFDIR, mode: 0o700)
            }
            let oldMask = umask(0o077)
            defer { umask(oldMask) }
            try maintenance.withLease(createIfMissing: true) {
                try maintenance.writeMarker(MaintenanceRecord(formatVersion: 1, operation: "setup", buildIdentifier: "test"))
            }
            try target.assertNode(maintenance.lock, kind: S_IFREG, mode: 0o600)
            try target.assertNode(maintenance.marker, kind: S_IFREG, mode: 0o644)
            try assert(host.descriptorOwnershipChanges.count == 4, "staging, new lock and marker establish ownership explicitly")

            let (existing, existingHost) = try fixture("existing-admin-directory")
            existingHost.adminDirectories.insert(existing.path(existing.support))
            let existingMaintenance = Maintenance(validator: existing, extraction: temporary)
            try refused("existing wrong-group directory is refused rather than silently normalized") {
                try existingMaintenance.createParents()
            }
            try assert(existingHost.descriptorOwnershipChanges.isEmpty, "existing directory refusal performs no ownership change")

            let (failed, failedHost) = try fixture("new-owner-failure")
            try files.removeItem(atPath: failed.path(failed.support))
            failedHost.ownershipFailure = true
            try refused("failed ownership establishment stops setup") {
                try Maintenance(validator: failed, extraction: temporary).createParents()
            }

            for kind in ["symlink", "directory", "flags", "acl"] {
                let (raced, racedHost) = try fixture("created-\(kind)")
                try files.removeItem(atPath: raced.path(raced.support))
                let child = raced.path(raced.support)
                var prepared = false
                racedHost.creationObserver = { parent, name, _ in
                    switch kind {
                    case "symlink", "directory":
                        try self.files.moveItem(atPath: child, toPath: child + "-original")
                        if kind == "symlink" {
                            try self.files.createSymbolicLink(atPath: child, withDestinationPath: child + "-original")
                        } else {
                            guard mkdirat(parent, name, 0o755) == 0 else { throw InstallFailure.refused("Cannot simulate replacement") }
                        }
                    case "flags":
                        guard chflags(child, UInt32(UF_HIDDEN)) == 0 else { throw InstallFailure.refused("Cannot set fixture flags") }
                    default:
                        try self.installReadACL(child)
                    }
                    prepared = true
                }
                try refused("changed new directory is refused before fchown: \(kind)") {
                    try Maintenance(validator: raced, extraction: temporary).createParents()
                }
                try assert(racedHost.descriptorOwnershipChanges.isEmpty, "no ownership change on unsafe created \(kind)")
                try assert(prepared, "unsafe \(kind) fixture was constructed before product refusal")
                if kind == "flags" { guard chflags(child, 0) == 0 else { throw InstallFailure.refused("Cannot clear fixture flags") } }
            }
        }

        let (writableCLI, _) = try fixture("writable-cli-parent")
        try files.setAttributes([.posixPermissions: 0o775], ofItemAtPath: writableCLI.path("/usr/local/bin"))
        try refused("writable global CLI parent refused before any copy") { _ = try writableCLI.preflight() }

        let real = Host()
        let guide = try real.run("/bin/bash", [repository + "/scripts/install.sh"])
        try assert(guide.status == 0 && guide.output.contains("NOT notarized"), "setup default prints unsigned trust guidance only")
        let remove = try real.run("/bin/bash", [repository + "/scripts/uninstall.sh"])
        try assert(remove.status == 2 && remove.output.contains("--keep-settings"), "noninteractive removal requires explicit choice")
        for arguments in [["--restore"], ["--restore", "--open-installer"]] {
            let restore = try real.run("/bin/bash", [repository + "/scripts/uninstall.sh"] + arguments)
            try assert(restore.status == 2 && restore.output.contains("never executes any CLI") &&
                       restore.output.contains("no Installer was opened"),
                       "unsupported automatic restore cannot invoke legacy CLI or Installer: \(arguments)")
        }
        let legacy = try real.run("/bin/bash", [repository + "/scripts/install.sh", "--app-dir", temporary.path])
        try assert(legacy.status == 2, "legacy arbitrary install path overrides refused")
        if CommandLine.arguments.count == 4 && CommandLine.arguments[2] == "--packages" {
            try inspectPackages(CommandLine.arguments[3])
        } else if CommandLine.arguments.count != 2 {
            throw InstallFailure.refused("Usage: test-install.sh [--packages /absolute/package-directory]")
        }
        print("HEARTH_INSTALL_TEST: PASS (\(passed) assertions; isolated fake filesystem only)")
    }

    func inspectPackages(_ directory: String) throws {
        let version = try String(contentsOfFile: repository + "/VERSION", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Host()
        let expanded = temporary.appendingPathComponent("expanded-setup").path
        let architecture = try host.run("/usr/bin/uname", ["-m"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = "hearth-\(version)-macos-\(architecture)-local"
        let setup = directory + "/\(stem)-setup.pkg"
        let result = try host.run("/usr/sbin/pkgutil", ["--expand-full", setup, expanded])
        try assert(result.status == 0, "setup package expands without installation: \(result.output)")
        let distribution = try XMLDocument(contentsOf: URL(fileURLWithPath: expanded + "/Distribution"))
        try assert(distribution.nodes(forXPath: "/installer-gui-script/options/@hostArchitectures").first?.stringValue == architecture,
                   "setup declares exactly its native host architecture, avoiding implicit Rosetta")
        try assert(distribution.nodes(forXPath: "/installer-gui-script/title").first?.stringValue == "Hearth",
                   "native window title is Install Hearth")
        let licenseStep = try distribution.nodes(forXPath: "/installer-gui-script/license").first as? XMLElement
        try assert(licenseStep?.attribute(forName: "file")?.stringValue == "License.txt" &&
                   licenseStep?.attribute(forName: "mime-type")?.stringValue == "text/plain",
                   "project license has its own native License step")
        try assert(distribution.nodes(forXPath: "/installer-gui-script/conclusion/@file").first?.stringValue == "Conclusion.html",
                   "native conclusion points to first-launch guidance")
        let resources = URL(fileURLWithPath: expanded + "/Resources")
        guard let enumeration = files.enumerator(at: resources, includingPropertiesForKeys: nil) else {
            throw InstallFailure.refused("Missing product resources")
        }
        let resourceFiles = enumeration.compactMap { $0 as? URL }
        let licenses = resourceFiles.filter { $0.lastPathComponent == "License.txt" }
        let conclusions = resourceFiles.filter { $0.lastPathComponent == "Conclusion.html" }
        try assert(conclusions.count == 1, "exactly one first-launch conclusion resource is packaged")
        let conclusion = try String(contentsOf: conclusions[0], encoding: .utf8)
        try assert(conclusion.contains("open /Applications/Hearth.app") && conclusion.contains("not the Dock"),
                   "packaged conclusion makes the exact installed app reachable without Spotlight")
        try assert(licenses.count == 1, "exactly one native project License resource is packaged")
        let projectLicense = try Data(contentsOf: URL(fileURLWithPath: repository + "/LICENSE"))
        try assert(Data(contentsOf: licenses[0]) == projectLicense, "Installer license bytes exactly equal project LICENSE")
        let component = expanded + "/Hearth-Setup-Component.pkg"
        let repairInput = URL(fileURLWithPath: component + "/Scripts/empty-support-repair.plist")
        let information = try resourceFiles.first { $0.lastPathComponent == "Installation.html" }
            .map { try String(contentsOf: $0, encoding: .utf8) } ?? ""
        if files.fileExists(atPath: repairInput.path) {
            let approval = try PropertyListDecoder().decode(SupportRepairApproval.self, from: Data(contentsOf: repairInput))
            try assert(approval.formatVersion == 1 && approval.device > 0 && approval.inode > 0,
                       "opt-in local repair fingerprint is embedded in setup only")
            try assert(information.localizedCaseInsensitiveContains("approved repair") && information.contains("group ownership"),
                       "repair-enabled setup clearly discloses its one-folder correction")
        } else {
            try assert(!information.localizedCaseInsensitiveContains("approved repair"), "ordinary setup does not silently opt in to a repair")
        }
        let validator = Validator(root: component + "/Scripts/payload")
        for executable in [validator.app + "/Contents/MacOS/HearthApp",
                           validator.app + "/Contents/MacOS/hearth", validator.helper] {
            let slices = try host.run("/usr/bin/lipo", ["-archs", validator.path(executable)])
            try assert(slices.status == 0 && slices.output.trimmingCharacters(in: .whitespacesAndNewlines) == architecture,
                       "Distribution host architecture matches packaged Mach-O: \(executable)")
        }
        let appInfo = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: validator.path(validator.app + "/Contents/Info.plist"))),
            format: nil) as? [String: Any]
        try assert(appInfo?["CFBundleShortVersionString"] as? String == version, "packaged app version matches VERSION")
        let sourceInfo = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: repository + "/Packaging/Info.plist")),
            format: nil) as? [String: Any]
        try assert(appInfo?["NSAppleEventsUsageDescription"] == nil &&
                   sourceInfo?["NSAppleEventsUsageDescription"] == nil,
                   "packaged and source app metadata omit obsolete Automation consent text")
        let receipt = try validator.readInventory(Data(contentsOf: URL(fileURLWithPath: validator.path(validator.receipt))))
        let actual = try validator.inventory(build: receipt.buildIdentifier, enforceOwnership: false)
        try assert(receipt.entries == actual.entries, "expanded payload matches exact final inventory")
        try validator.validateSignatures()
        try assert(true, "empty app/CLI/helper grants, signatures and exact 20-byte CDHashes verify")
        try assert(Data(contentsOf: URL(fileURLWithPath: validator.path(validator.app + "/Contents/Resources/LICENSE.txt"))) == projectLicense,
                   "app includes the same project MIT license separately from dependency notices")
        try assert(try validator.metadata(validator.app + "/Contents/Resources/Hearth_HearthWeb.bundle/index.html") != nil,
                   "web resources included")
        try assert(try validator.metadata(validator.app + "/Contents/Resources/swift-nio_NIOPosix.bundle/PrivacyInfo.xcprivacy") != nil,
                   "dependency privacy resource included")
        for dependency in ["swift-nio", "swift-atomics", "swift-collections", "swift-system"] {
            try assert(try validator.metadata(validator.app + "/Contents/Resources/ThirdPartyLicenses/\(dependency).txt") != nil,
                       "\(dependency) license included")
        }
        let copiedReceipt = try Data(contentsOf: URL(fileURLWithPath: component + "/Scripts/payload-receipt.plist"))
        try assert(copiedReceipt == Data(contentsOf: URL(fileURLWithPath: validator.path(validator.receipt))),
                   "trusted Scripts archive carries matching authorized inventory")
        let validation = Maintenance(validator: validator, extraction: URL(fileURLWithPath: component + "/Scripts"))
        try validation.validateSource(validator, expected: receipt, ownership: false)
        try assert(true, "entire packaged source tree is allowlisted and has no unsafe links or ACLs")
        let unsigned = try host.run("/usr/sbin/pkgutil", ["--check-signature", setup])
        try assert(unsigned.output.contains("no signature"), "setup package is honestly unsigned")
        let removal = temporary.appendingPathComponent("expanded-remove").path
        let removeResult = try host.run("/usr/sbin/pkgutil", ["--expand-full", directory + "/\(stem)-remove.pkg", removal])
        try assert(removeResult.status == 0, "removal package expands without installation")
        let removalDistribution = try XMLDocument(contentsOf: URL(fileURLWithPath: removal + "/Distribution"))
        try assert(removalDistribution.nodes(forXPath: "/installer-gui-script/options/@hostArchitectures").first?.stringValue == architecture,
                   "removal declares exactly its native host architecture")
        try assert(!files.fileExists(atPath: removal + "/Hearth-Remove-Component.pkg/Scripts/empty-support-repair.plist"),
                   "removal package never carries a setup repair approval")
        try assert(!files.fileExists(atPath: removal + "/Hearth-Remove-Component.pkg/Payload"),
                   "removal has no replacement payload")
        for package in [component, removal + "/Hearth-Remove-Component.pkg"] {
            try assert(!files.fileExists(atPath: package + "/Payload"), "scripts-only package has no filesystem Payload")
            let info = try String(contentsOfFile: package + "/PackageInfo", encoding: .utf8)
            let metadata = try XMLDocument(xmlString: info)
            try assert((metadata.rootElement()?.attribute(forName: "version")?.stringValue) == version,
                       "setup/removal package version matches VERSION")
            try assert(!info.contains("<payload") && !info.contains("install-location="),
                       "Installer has no payload declaration or installation root")
            try assert(!files.fileExists(atPath: package + "/Bom"),
                       "scripts-only package has no BOM capable of assigning ancestor metadata")
            for script in ["preinstall", "postinstall"] {
                let contents = try String(contentsOfFile: package + "/Scripts/" + script, encoding: .utf8)
                try assert(contents.contains("\"$3\" != \"/\"") && contents.contains("/usr/bin/env -i"),
                           "root wrapper uses fixed volume and clean environment")
            }
            let code = Validator(root: package + "/Scripts")
            let slices = try host.run("/usr/bin/lipo", ["-archs", code.path("/installer-tool")])
            try assert(slices.status == 0 && slices.output.trimmingCharacters(in: .whitespacesAndNewlines) == architecture,
                       "maintenance Mach-O matches its Distribution host architecture")
            _ = try code.codeHash("/installer-tool", identifier: "dev.girishkvs.hearth.installer")
            try assert(true, "embedded maintenance tool hardened signature verifies")
        }
    }
}
