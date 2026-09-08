import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum InstallFailure: Error, CustomStringConvertible {
    case refused(String)

    var description: String {
        switch self {
        case .refused(let message): return message
        }
    }
}

struct Entry: Codable, Equatable {
    let path: String
    let kind: String
    let mode: UInt16
    let digest: String
}

struct Inventory: Codable {
    let formatVersion: Int
    let buildIdentifier: String
    let entries: [Entry]
}

struct Authorization: Codable {
    let FormatVersion: Int
    let ProtocolVersion: Int
    let AppCodeHash: String
    let CLICodeHash: String
    let HelperCodeHash: String
    let BuildIdentifier: String
}

struct CommandResult {
    let status: Int32
    let output: String
}

class Host {
    func createDirectory(_ name: String, parent: Int32, mode: mode_t) throws -> stat {
        guard mkdirat(parent, name, mode) == 0 else {
            throw InstallFailure.refused("Cannot create protected directory \(name): errno \(errno)")
        }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw InstallFailure.refused("Cannot inspect newly created directory \(name)")
        }
        return info
    }

    func setOwnership(_ descriptor: Int32, uid: uid_t, gid: gid_t) throws {
        guard fchown(descriptor, uid, gid) == 0 else {
            throw InstallFailure.refused("Cannot establish new object ownership: errno \(errno)")
        }
    }

    func run(_ executable: String, _ arguments: [String], standardOutputOnly: Bool = false) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = standardOutputOnly ? FileHandle.nullDevice : output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    func ownership(_ path: String, _ metadata: stat) -> (uid_t, gid_t) {
        (metadata.st_uid, metadata.st_gid)
    }

    func hasACL(_ path: String) throws -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT for an existing object with no extended ACL.
            var metadata = stat()
            if errno == ENOENT && lstat(path, &metadata) == 0 { return false }
            throw InstallFailure.refused("Cannot inspect ACL: \(path)")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == 0 || errno == EINVAL else { throw InstallFailure.refused("Cannot read ACL: \(path)") }
        return result == 0
    }

    func hasACL(_ descriptor: Int32) throws -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw InstallFailure.refused("Cannot inspect descriptor ACL: errno \(errno)")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == 0 || errno == EINVAL else {
            throw InstallFailure.refused("Cannot read descriptor ACL")
        }
        return result == 0
    }
}

final class Validator {
    let root: String
    let host: Host
    let fileManager = FileManager.default
    let app = "/Applications/Hearth.app"
    let helper = "/Library/PrivilegedHelperTools/dev.girishkvs.hearth.helper"
    let daemon = "/Library/LaunchDaemons/dev.girishkvs.hearth.helper.plist"
    let support = "/Library/Application Support/Hearth"
    let policy = "/Library/Application Support/Hearth/authorization.plist"
    let receipt = "/Library/Application Support/Hearth/install-receipt.plist"
    let link = "/usr/local/bin/hearth"
    let packageID = "dev.girishkvs.hearth.setup"
    let service = "system/dev.girishkvs.hearth.helper"
    let currentProtocolVersion = 2

    init(root: String, host: Host = Host()) {
        self.root = root == "/" ? "" : root
        self.host = host
    }

    func path(_ relative: String) -> String {
        relative == "/" && !root.isEmpty ? root : root + relative
    }

    func metadata(_ relative: String) throws -> stat? {
        var value = stat()
        if lstat(path(relative), &value) != 0 {
            if errno == ENOENT { return nil }
            throw InstallFailure.refused("Cannot inspect \(relative): errno \(errno)")
        }
        return value
    }

    func fail(_ message: String) throws -> Never { throw InstallFailure.refused(message) }

    func assertNode(_ relative: String, kind: mode_t, mode: mode_t, group: gid_t = 0, systemAncestor: Bool = false) throws {
        guard let info = try metadata(relative) else { try fail("Missing required path: \(relative)") }
        let owners = host.ownership(path(relative), info)
        guard info.st_mode & S_IFMT == kind,
              info.st_mode & 0o7777 == mode,
              owners.0 == 0,
              owners.1 == group,
              systemAncestor || info.st_flags == 0,
              !(try host.hasACL(path(relative))) else {
            try fail("Unsafe type, ownership, mode, flags, or ACL: \(relative)")
        }
        if kind == S_IFREG && info.st_nlink != 1 {
            try fail("Hard-linked file refused: \(relative)")
        }
    }

    func validateSystemAncestors() throws {
        try assertNode("/", kind: S_IFDIR, mode: 0o755, systemAncestor: true)
        // /Applications is deliberately writable by the admin group on stock macOS.
        try assertNode("/Applications", kind: S_IFDIR, mode: 0o775, group: 80, systemAncestor: true)
        guard let supportParent = try metadata("/Library/Application Support") else { try fail("Missing /Library/Application Support") }
        let supportGroup = host.ownership(path("/Library/Application Support"), supportParent).1
        guard [gid_t(0), gid_t(80)].contains(supportGroup) else { try fail("Unexpected Application Support group") }
        try assertNode("/Library/Application Support", kind: S_IFDIR, mode: 0o755, group: supportGroup, systemAncestor: true)
        for directory in ["/Library", "/usr", "/var", "/private",
                          "/private/var", "/private/var/db", "/private/var/db/receipts"] {
            // /var is the one fixed, Apple-owned ancestor symlink, never a caller-selected target.
            if directory == "/var" {
                try assertNode(directory, kind: S_IFLNK, mode: 0o755, systemAncestor: true)
                guard try fileManager.destinationOfSymbolicLink(atPath: path(directory)) == "private/var" else {
                    try fail("Unexpected /var link")
                }
            } else {
                try assertNode(directory, kind: S_IFDIR, mode: 0o755, systemAncestor: true)
            }
        }
    }

    func validateAncestors() throws {
        try validateSystemAncestors()
        for directory in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons", support,
                          "/usr/local", "/usr/local/bin"] {
            if try metadata(directory) != nil {
                try assertNode(directory, kind: S_IFDIR, mode: 0o755, systemAncestor: true)
            }
        }
    }

    func payloadRoots() -> [String] { [app, helper, daemon, policy, link] }

    func packageIDs() -> [String] { [packageID] }

    func regularDigest(_ relative: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path(relative)), options: [.mappedIfSafe])
        return digest(data)
    }

    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func collect(_ relative: String, enforceOwnership: Bool) throws -> [Entry] {
        guard let info = try metadata(relative) else { try fail("Missing payload: \(relative)") }
        let kind = info.st_mode & S_IFMT
        let mode = info.st_mode & 0o7777
        let executable = [app + "/Contents/MacOS/HearthApp", app + "/Contents/MacOS/hearth", helper]
        let expectedMode: mode_t = kind == S_IFDIR || kind == S_IFLNK || executable.contains(relative) ? 0o755 : 0o644
        guard mode == expectedMode else { try fail("Unexpected payload permissions: \(relative)") }
        if enforceOwnership { try assertNode(relative, kind: kind, mode: expectedMode) }
        if kind == S_IFDIR {
            var entries = [Entry(path: relative, kind: "directory", mode: UInt16(mode), digest: "")]
            for name in try fileManager.contentsOfDirectory(atPath: path(relative)).sorted() {
                entries += try collect(relative + "/" + name, enforceOwnership: enforceOwnership)
            }
            return entries
        }
        if kind == S_IFLNK && relative == link {
            let target = try fileManager.destinationOfSymbolicLink(atPath: path(relative))
            guard target == app + "/Contents/MacOS/hearth" else { try fail("Foreign CLI link") }
            return [Entry(path: relative, kind: "symlink", mode: UInt16(mode), digest: target)]
        }
        guard kind == S_IFREG, info.st_nlink == 1 else { try fail("Unsupported payload node: \(relative)") }
        return [Entry(path: relative, kind: "file", mode: UInt16(mode), digest: try regularDigest(relative))]
    }

    func inventory(build: String, enforceOwnership: Bool) throws -> Inventory {
        var entries: [Entry] = []
        for item in payloadRoots() { entries += try collect(item, enforceOwnership: enforceOwnership) }
        return Inventory(formatVersion: 1, buildIdentifier: build, entries: entries)
    }

    func readInventory(_ data: Data) throws -> Inventory {
        let value = try PropertyListDecoder().decode(Inventory.self, from: data)
        guard value.formatVersion == 1,
              !value.buildIdentifier.isEmpty,
              value.entries.count <= 10_000,
              Set(value.entries.map(\.path)).count == value.entries.count else {
            try fail("Invalid protected inventory")
        }
        for item in value.entries {
            let parts = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(".."),
                  !parts.dropFirst().contains(""),
                  payloadRoots().contains(item.path) || item.path.hasPrefix(app + "/") else {
                try fail("Inventory contains an unexpected path")
            }
        }
        return value
    }

    private func validateEntitlements(_ relative: String, nativeApp: Bool, acceptingLegacyApp: Bool) throws {
        // --xml avoids codesign's human-readable abstract format. Diagnostics such
        // as Executable= go to stderr; successful empty stdout means no entitlements.
        let result = try host.run("/usr/bin/codesign",
            ["--display", "--entitlements", "-", "--xml", path(relative)], standardOutputOnly: true)
        guard result.status == 0 else { try fail("Cannot read entitlements: \(relative)") }
        let entitlements: [String: Any]
        if result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entitlements = [:]
        } else {
            guard let value = try? PropertyListSerialization.propertyList(
                from: Data(result.output.utf8), format: nil) as? [String: Any] else {
                try fail("Invalid entitlement property list: \(relative)")
            }
            entitlements = value
        }
        if entitlements.isEmpty { return }
        guard nativeApp,
              acceptingLegacyApp,
              entitlements.count == 1,
              let automation = entitlements["com.apple.security.automation.apple-events"] as? NSNumber,
              CFGetTypeID(automation) == CFBooleanGetTypeID(),
              automation.boolValue else {
            try fail("Unexpected entitlements: \(relative)")
        }
    }

    func codeHash(_ relative: String, identifier: String, acceptingLegacyApp: Bool = false) throws -> String {
        let artifact = path(relative)
        let architecture = try host.run("/usr/bin/lipo", ["-archs", artifact])
        let slices = architecture.output.split(whereSeparator: \.isWhitespace)
        guard architecture.status == 0,
              slices.count == 1,
              ["arm64", "x86_64"].contains(String(slices[0])) else {
            try fail("Only one native architecture is supported: \(relative)")
        }
        let check = try host.run("/usr/bin/codesign", ["--verify", "--strict", "--all-architectures", artifact])
        guard check.status == 0 else { try fail("Invalid full signature: \(relative)\n\(check.output)") }
        let display = try host.run("/usr/bin/codesign", ["--display", "--verbose=4", artifact])
        let lines = display.output.split(separator: "\n").map(String.init)
        guard display.status == 0,
              lines.contains("Identifier=\(identifier)"),
              lines.contains(where: {
                  $0.hasPrefix("CodeDirectory ") &&
                      $0.range(of: #"flags=0x[0-9a-f]+\([^)]*\bruntime\b"#, options: .regularExpression) != nil
              }) else {
            try fail("Expected identifier and hardened runtime missing: \(relative)")
        }
        let nativeApp = relative == app + "/Contents/MacOS/HearthApp" &&
            identifier == "dev.girishkvs.hearth"
        try validateEntitlements(relative, nativeApp: nativeApp, acceptingLegacyApp: acceptingLegacyApp)
        let hashes = lines.filter { $0.hasPrefix("CDHash=") }.map { String($0.dropFirst(7)) }
        guard hashes.count == 1,
              hashes[0].range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            try fail("Missing 20-byte CDHash: \(relative)")
        }
        return hashes[0]
    }

    func validateSignatures(acceptingLegacyInstallation: Bool = false) throws {
        let authorization = try PropertyListDecoder().decode(
            Authorization.self, from: Data(contentsOf: URL(fileURLWithPath: path(policy))))
        let compatibleProtocol = authorization.ProtocolVersion == currentProtocolVersion ||
            (acceptingLegacyInstallation && authorization.ProtocolVersion == 1)
        guard authorization.FormatVersion == 1,
              compatibleProtocol,
              !authorization.BuildIdentifier.isEmpty else { try fail("Invalid authorization policy") }
        let appHash = try codeHash(app + "/Contents/MacOS/HearthApp", identifier: "dev.girishkvs.hearth",
                                  acceptingLegacyApp: acceptingLegacyInstallation)
        let cliHash = try codeHash(app + "/Contents/MacOS/hearth", identifier: "dev.girishkvs.hearth.cli")
        let helperHash = try codeHash(helper, identifier: "dev.girishkvs.hearth.helper")
        let bundle = try host.run("/usr/bin/codesign", ["--verify", "--strict", "--all-architectures", path(app)])
        guard bundle.status == 0,
              appHash == authorization.AppCodeHash,
              cliHash == authorization.CLICodeHash,
              helperHash == authorization.HelperCodeHash else { try fail("Signed payload does not match enrolled policy") }
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: path(daemon))), format: nil) as? NSDictionary
        let expected: NSDictionary = [
            "Label": "dev.girishkvs.hearth.helper",
            "Program": helper,
            "MachServices": ["dev.girishkvs.hearth.helper": true],
            "ProcessType": "Interactive",
            "UserName": "root",
            "GroupName": "wheel"
        ]
        guard plist == expected else { try fail("Unexpected launch daemon configuration") }
    }

    func installedInventory() throws -> Inventory {
        try assertNode(receipt, kind: S_IFREG, mode: 0o644)
        let expected = try readInventory(Data(contentsOf: URL(fileURLWithPath: path(receipt))))
        let actual = try inventory(build: expected.buildIdentifier, enforceOwnership: true)
        guard expected.entries == actual.entries else { try fail("Installed payload was modified or contains foreign additions") }
        let authorization = try PropertyListDecoder().decode(
            Authorization.self, from: Data(contentsOf: URL(fileURLWithPath: path(policy))))
        guard authorization.BuildIdentifier == expected.buildIdentifier else { try fail("Policy and inventory builds differ") }
        // Only installed maintenance accepts the verified legacy app-only Automation
        // grant. New/staged apps need no entitlements for current-user preferences.
        try validateSignatures(acceptingLegacyInstallation: true)
        return expected
    }

    @discardableResult
    func validatePackageReceipts(verifiedInstallation: Bool) throws -> [String] {
        var registered: [String] = []
        for identifier in packageIDs() {
            let base = "/private/var/db/receipts/\(identifier)"
            let hasPlist = try metadata(base + ".plist") != nil
            let hasBOM = try metadata(base + ".bom") != nil
            guard hasPlist || hasBOM else {
                // Scripts-only installs may record history without an Apple receipt.
                // This never substitutes for the verified Hearth manifest and code.
                continue
            }
            guard verifiedInstallation, hasPlist else {
                try fail("Foreign or incomplete Apple Installer receipt: \(base)")
            }
            try assertNode(base + ".plist", kind: S_IFREG, mode: 0o644)
            if hasBOM { try assertNode(base + ".bom", kind: S_IFREG, mode: 0o644) }
            let plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: URL(fileURLWithPath: path(base + ".plist"))), format: nil) as? [String: Any]
            guard plist?["PackageIdentifier"] as? String == identifier else { try fail("Foreign Apple Installer receipt") }
            registered.append(identifier)
        }
        for component in ["app", "helper", "daemon", "policy", "cli"] {
            for suffix in ["plist", "bom"] {
                if try metadata("/private/var/db/receipts/\(packageID).\(component).\(suffix)") != nil {
                    try fail("Prototype component receipt requires explicit repair")
                }
            }
        }
        let removalID = "dev.girishkvs.hearth.remove"
        let removalBase = "/private/var/db/receipts/\(removalID)"
        let removalPlist = try metadata(removalBase + ".plist")
        let removalBOM = try metadata(removalBase + ".bom")
        if removalPlist != nil || removalBOM != nil {
            try assertNode(removalBase + ".plist", kind: S_IFREG, mode: 0o644)
            if removalBOM != nil { try assertNode(removalBase + ".bom", kind: S_IFREG, mode: 0o644) }
            let plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: URL(fileURLWithPath: path(removalBase + ".plist"))), format: nil) as? [String: Any]
            guard plist?["PackageIdentifier"] as? String == removalID else { try fail("Foreign removal-package receipt") }
        }
        return registered
    }

    func preflight() throws -> Inventory? {
        try validateAncestors()
        if try metadata(receipt) != nil {
            let installed = try installedInventory()
            try validatePackageReceipts(verifiedInstallation: true)
            return installed
        }
        for item in payloadRoots() {
            if try metadata(item) != nil { try fail("Refusing existing unowned path: \(item)") }
        }
        try validatePackageReceipts(verifiedInstallation: false)
        return nil
    }
}
