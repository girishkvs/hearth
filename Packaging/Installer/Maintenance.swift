import Darwin
import Foundation

struct MaintenanceRecord: Codable {
    let formatVersion: Int
    let operation: String
    let buildIdentifier: String
    var oldInventory: Inventory? = nil
    var authorizedInventory: Inventory? = nil
}

final class Maintenance {
    let validator: Validator
    let extraction: URL
    let marker = "/Library/Application Support/Hearth/maintenance.plist"
    let lock = "/Library/Application Support/Hearth/operation.lock"

    init(validator: Validator, extraction: URL) {
        self.validator = validator
        self.extraction = extraction
    }

    func run(_ operation: String) throws {
        switch operation {
        case "setup-preflight": try preflightSetup()
        case "setup-postflight": try postflightSetup()
        case "remove-preflight": try preflightRemoval()
        case "remove-postflight": try postflightRemoval()
        default: try validator.fail("Unsupported maintenance operation")
        }
    }

    func expectedInventory() throws -> Inventory {
        let path = extraction.appendingPathComponent("payload-receipt.plist")
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1 else { try validator.fail("Unsafe inventory in package extraction") }
        return try validator.readInventory(Data(contentsOf: path))
    }

    func createParents() throws {
        for directory in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons", validator.support,
                          "/usr/local", "/usr/local/bin"] {
            if try validator.metadata(directory) == nil {
                try createOwnedDirectory(directory, mode: 0o755)
            }
            try validator.assertNode(directory, kind: S_IFDIR, mode: 0o755, systemAncestor: true)
        }
    }

    func withLease(createIfMissing: Bool = false, _ action: () throws -> Void) throws {
        let descriptor: Int32
        let created: Bool
        if try validator.metadata(lock) == nil {
            guard createIfMissing else { try validator.fail("Permanent helper operation lock is missing; repair needed") }
            descriptor = open(validator.path(lock), O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            created = true
        } else {
            try validator.assertNode(lock, kind: S_IFREG, mode: 0o600)
            descriptor = open(validator.path(lock), O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            created = false
        }
        guard descriptor >= 0 else { try validator.fail("Cannot open the protected operation lock") }
        defer { close(descriptor) }
        if created { try establishCreatedOwnership(descriptor, relative: lock, kind: S_IFREG, mode: 0o600) }
        try validator.assertNode(lock, kind: S_IFREG, mode: 0o600)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            try validator.fail("A Hearth operation is in flight. Wait for it to finish, then retry explicit maintenance")
        }
        defer { flock(descriptor, LOCK_UN) }
        try action()
    }

    func serviceStatus() throws -> CommandResult? {
        let result = try validator.host.run("/bin/launchctl", ["print", validator.service])
        if result.status == 0 { return result }
        // Only the exact service-not-found result is evidence of absence.
        let absent = result.status == 113 &&
            result.output.contains("Could not find service \"dev.girishkvs.hearth.helper\" in domain for system")
        if absent { return nil }
        try validator.fail("Cannot determine helper service state (exit \(result.status)): \(result.output)")
    }

    func stopService(_ status: CommandResult?) throws {
        guard let status else {
            print("Hearth service is not registered; no bootout was needed.")
            return
        }
        let pidLine = status.output.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }
        let pid = pidLine.flatMap { Int32($0.trimmingCharacters(in: .whitespaces).dropFirst(6)) }
        let result = try validator.host.run("/bin/launchctl", ["bootout", validator.service])
        guard result.status == 0 else {
            try validator.fail("Helper bootout failed (exit \(result.status)); payload was not replaced: \(result.output)")
        }
        guard try serviceStatus() == nil else { try validator.fail("Helper is still registered after bootout") }
        if let pid {
            for _ in 0..<100 {
                if kill(pid, 0) != 0 && errno == ESRCH { return }
                usleep(100_000)
            }
            try validator.fail("Old helper process did not exit. Maintenance remains blocked; retry only after repair")
        }
    }

    func writeMarker(_ value: MaintenanceRecord) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(value)
        let fd = open(validator.path(marker), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { try validator.fail("Maintenance marker already exists or cannot be created; repair needed") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try establishCreatedOwnership(fd, relative: marker, kind: S_IFREG, mode: 0o644)
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0 else { try validator.fail("Cannot persist maintenance marker") }
        try validator.assertNode(marker, kind: S_IFREG, mode: 0o644)
    }

    func readMarker(removing: Bool, build: String) throws -> MaintenanceRecord {
        try validator.assertNode(marker, kind: S_IFREG, mode: 0o644)
        let value = try PropertyListDecoder().decode(
            MaintenanceRecord.self, from: Data(contentsOf: URL(fileURLWithPath: validator.path(marker))))
        guard value.formatVersion == 1,
              value.operation == (removing ? "remove" : "setup"),
              value.buildIdentifier == build else { try validator.fail("Maintenance marker does not match this transaction") }
        return value
    }

    func preflightRemoval() throws {
        guard let installed = try validator.preflight() else { try validator.fail("No verified Hearth installation to remove") }
        guard try validator.metadata(marker) == nil,
              try validator.metadata(staging) == nil else { try validator.fail("Previous maintenance is incomplete; repair needed") }
        try createParents()
        try withLease {
            // Recheck after acquiring the same lease used by helper operations.
            _ = try validator.preflight()
            try writeMarker(MaintenanceRecord(formatVersion: 1, operation: "remove", buildIdentifier: installed.buildIdentifier))
        }
        print("Hearth removal preflight passed. Service and payload remain unchanged until postinstall holds the exclusive lease.")
    }

    func postflightRemoval() throws {
        try validator.validateAncestors()
        try withLease {
            let installed = try validator.installedInventory()
            _ = try readMarker(removing: true, build: installed.buildIdentifier)
            let registeredPackages = try validator.validatePackageReceipts(verifiedInstallation: true)
            try stopService(serviceStatus())
            for entry in installed.entries.sorted(by: { $0.path.count > $1.path.count }) {
                try removeVerified(entry)
            }
            try validator.assertNode(validator.receipt, kind: S_IFREG, mode: 0o644)
            guard unlink(validator.path(validator.receipt)) == 0 else { try validator.fail("Cannot remove protected inventory") }
            for identifier in registeredPackages {
                let forgotten = try validator.host.run("/usr/sbin/pkgutil", ["--forget", identifier])
                guard forgotten.status == 0 else { try validator.fail("Cannot forget verified setup receipt: \(forgotten.output)") }
            }
            guard unlink(validator.path(marker)) == 0 else { try validator.fail("Cannot clear maintenance marker") }
            print("Removed only verified Hearth components. Current power settings, all user state, and protected restore journals were kept.")
        }
    }

    func removeVerified(_ entry: Entry) throws {
        // Walk with directory descriptors: an admin replacing /Applications/Hearth.app with a
        // symlink cannot redirect root deletion into another tree. Never recursively remove.
        let parts = entry.path.split(separator: "/").map(String.init)
        var parent = open(validator.root.isEmpty ? "/" : validator.root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { try validator.fail("Cannot open removal root") }
        defer { close(parent) }
        for component in parts.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { try validator.fail("Unsafe removal ancestor: \(entry.path)") }
            close(parent)
            parent = next
        }
        let name = parts.last!
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { try validator.fail("Missing removal entry: \(entry.path)") }
        let owners = validator.host.ownership(validator.path(entry.path), info)
        let kind: mode_t = entry.kind == "directory" ? S_IFDIR : entry.kind == "symlink" ? S_IFLNK : S_IFREG
        guard info.st_mode & S_IFMT == kind,
              info.st_mode & 0o7777 == entry.mode,
              owners.0 == 0, owners.1 == 0,
              info.st_flags == 0 else { try validator.fail("Changed removal entry: \(entry.path)") }
        if entry.kind == "file" {
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0, info.st_nlink == 1 else { try validator.fail("Unsafe removal file") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let data = try handle.readToEnd() ?? Data()
            guard validator.digest(data) == entry.digest else { try validator.fail("Modified removal file") }
        } else if entry.kind == "symlink" {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let length = readlinkat(parent, name, &bytes, bytes.count)
            guard length >= 0,
                  String(decoding: bytes.prefix(Int(length)), as: UTF8.self) == entry.digest else {
                try validator.fail("Changed removal symlink")
            }
        }
        guard unlinkat(parent, name, entry.kind == "directory" ? AT_REMOVEDIR : 0) == 0 else {
            try validator.fail("Refused removal; entry changed, contains additions, or is busy: \(entry.path)")
        }
    }
}
