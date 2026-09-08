import Darwin
import Foundation

extension Maintenance {
    var staging: String { validator.support + "/install-staging" }

    func validateSource(_ source: Validator, expected: Inventory, ownership: Bool) throws {
        var allowed = Set(expected.entries.map(\.path) + [source.receipt])
        for item in Array(allowed) {
            var parent = (item as NSString).deletingLastPathComponent
            while parent != "/" {
                allowed.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        try inspectSourceTree(source, relative: "/", allowed: allowed, ownership: ownership)
        let receipt = try source.readInventory(Data(contentsOf: URL(fileURLWithPath: source.path(source.receipt))))
        let actual = try source.inventory(build: expected.buildIdentifier, enforceOwnership: ownership)
        guard receipt.entries == expected.entries,
              receipt.buildIdentifier == expected.buildIdentifier,
              actual.entries == expected.entries else { try validator.fail("Packaged payload differs from authorized inventory") }
        try source.validateSignatures()
    }

    func inspectSourceTree(_ source: Validator, relative: String, allowed: Set<String>, ownership: Bool) throws {
        guard let metadata = try source.metadata(relative),
              metadata.st_flags == 0,
              !(try source.host.hasACL(source.path(relative))) else { try validator.fail("Unsafe package source metadata") }
        let kind = metadata.st_mode & S_IFMT
        if ownership {
            let mode: mode_t = kind == S_IFDIR || kind == S_IFLNK ||
                [source.app + "/Contents/MacOS/HearthApp", source.app + "/Contents/MacOS/hearth", source.helper].contains(relative) ? 0o755 : 0o644
            try source.assertNode(relative, kind: kind, mode: mode)
        }
        if relative != "/" && !allowed.contains(relative) { try validator.fail("Unexpected packaged path: \(relative)") }
        if kind == S_IFDIR {
            guard metadata.st_mode & 0o7777 == 0o755 else { try validator.fail("Unsafe packaged directory permissions") }
            for name in try source.fileManager.contentsOfDirectory(atPath: source.path(relative)) {
                let child = relative == "/" ? "/" + name : relative + "/" + name
                try inspectSourceTree(source, relative: child, allowed: allowed, ownership: ownership)
            }
        } else if relative == source.link {
            guard kind == S_IFLNK else { try validator.fail("Packaged CLI link is not a symlink") }
        } else {
            guard kind == S_IFREG,
                  metadata.st_nlink == 1 else { try validator.fail("Unexpected packaged file type") }
        }
    }

    func packagedSource() -> Validator {
        Validator(root: extraction.appendingPathComponent("payload").path, host: validator.host)
    }

    func preflightSetup() throws {
        let expected = try expectedInventory()
        try validateSource(packagedSource(), expected: expected, ownership: false)
        try repairSupportIfApproved()
        let installed = try validator.preflight()
        guard try validator.metadata(marker) == nil,
              try validator.metadata(staging) == nil else { try validator.fail("Previous maintenance is incomplete; repair needed") }
        try createParents()
        try withLease(createIfMissing: installed == nil) {
            let current = try validator.preflight()
            let service = try serviceStatus()
            if current == nil && service != nil { try validator.fail("Unowned helper service already registered") }
            var record = MaintenanceRecord(formatVersion: 1, operation: "setup", buildIdentifier: expected.buildIdentifier)
            record.oldInventory = current
            record.authorizedInventory = expected
            try writeMarker(record)
        }
        print("Hearth setup preflight passed. Service and payload remain unchanged until postinstall holds the exclusive lease.")
    }

    func postflightSetup() throws {
        // Validate the lock's ancestor path before opening it. All payload verification
        // and active maintenance then share one continuously held exclusive descriptor.
        try validator.validateAncestors()
        try withLease {
            let expected = try expectedInventory()
            let source = packagedSource()
            try validateSource(source, expected: expected, ownership: false)
            let record = try readMarker(removing: false, build: expected.buildIdentifier)
            guard record.authorizedInventory?.entries == expected.entries,
                  record.authorizedInventory?.buildIdentifier == expected.buildIdentifier else {
                try validator.fail("Package does not match the pending authorized transaction")
            }
            // Apple owns its receipt-write timing during this already authorized transaction.
            // Recheck the protected Hearth inventory here, not "fresh install" receipt absence.
            let old: Inventory?
            if record.oldInventory != nil {
                old = try validator.installedInventory()
            } else {
                for target in validator.payloadRoots() + [validator.receipt] {
                    if try validator.metadata(target) != nil { try validator.fail("Destination appeared during maintenance: \(target)") }
                }
                old = nil
            }
            guard old?.entries == record.oldInventory?.entries,
                  old?.buildIdentifier == record.oldInventory?.buildIdentifier else {
                try validator.fail("Installed payload changed during maintenance; repair needed")
            }
            let service = try serviceStatus()
            if old == nil && service != nil { try validator.fail("Unowned helper appeared during maintenance") }
            try stopService(service)
            try createOwnedDirectory(staging, mode: 0o700)
            try validator.assertNode(staging, kind: S_IFDIR, mode: 0o700)
            let copied = validator.path(staging + "/payload")
            let copy = try validator.host.run("/usr/bin/ditto",
                ["--norsrc", "--noextattr", "--noacl", source.root, copied])
            guard copy.status == 0 else { try validator.fail("Cannot copy trusted package payload: \(copy.output)") }
            // The 0700 outer staging directory prevents access even if ditto preserves
            // source ownership temporarily. -h/-P never follows the absolute CLI symlink.
            let ownership = try validator.host.run("/usr/sbin/chown", ["-h", "-R", "-P", "0:0", copied])
            guard ownership.status == 0 else { try validator.fail("Cannot protect staged payload: \(ownership.output)") }
            let staged = Validator(root: copied, host: validator.host)
            try validateSource(staged, expected: expected, ownership: true)
            if let old {
                for entry in old.entries.sorted(by: { $0.path.count > $1.path.count }) { try removeVerified(entry) }
                try validator.assertNode(validator.receipt, kind: S_IFREG, mode: 0o644)
                guard unlink(validator.path(validator.receipt)) == 0 else { try validator.fail("Cannot replace protected inventory") }
            }
            for target in validator.payloadRoots() + [validator.receipt] { try publish(staged: staged, target: target) }
            try removeEmptyStaging()
            let installed = try validator.installedInventory()
            guard installed.entries == expected.entries,
                  installed.buildIdentifier == expected.buildIdentifier else { try validator.fail("Published payload does not match authorized package") }
            let result = try validator.host.run("/bin/launchctl", ["bootstrap", "system", validator.daemon])
            guard result.status == 0 else { try validator.fail("Helper bootstrap failed: \(result.output)") }
            guard try serviceStatus() != nil else { try validator.fail("Bootstrap did not register helper") }
            guard unlink(validator.path(marker)) == 0 else { try validator.fail("Cannot clear maintenance marker") }
            print("Hearth setup verified. Only fixed Hearth destinations were published; on-demand helper registered. No power settings changed.")
        }
    }

    func openDirectory(_ root: String, relative: String) throws -> Int32 {
        var descriptor = open(root.isEmpty ? "/" : root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { try validator.fail("Cannot open protected directory root") }
        for component in relative.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { try validator.fail("Symlink or unavailable directory in fixed publish path") }
            descriptor = next
        }
        return descriptor
    }

    func createOwnedDirectory(_ relative: String, mode: mode_t) throws {
        let allowed = ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons", validator.support,
                       "/usr/local", "/usr/local/bin", staging]
        guard allowed.contains(relative) else { try validator.fail("Unrecognized protected directory") }
        let parentPath = (relative as NSString).deletingLastPathComponent
        let name = (relative as NSString).lastPathComponent
        let parent = try openDirectory(validator.root, relative: parentPath)
        defer { close(parent) }
        let made = try validator.host.createDirectory(name, parent: parent, mode: mode)
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { try validator.fail("New directory was replaced or cannot be opened: \(relative)") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == made.st_dev,
              opened.st_ino == made.st_ino else {
            try validator.fail("New directory identity changed before ownership was established: \(relative)")
        }
        try establishCreatedOwnership(descriptor, relative: relative, kind: S_IFDIR, mode: mode)
        guard fsync(parent) == 0 else { try validator.fail("Cannot persist new directory entry: \(relative)") }
    }

    func establishCreatedOwnership(_ descriptor: Int32, relative: String, kind: mode_t, mode: mode_t) throws {
        // Only call for a successful exclusive creation in this transaction.
        // macOS inherits a new directory's group from its parent, even for root.
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              let named = try validator.metadata(relative),
              before.st_dev == named.st_dev,
              before.st_ino == named.st_ino else {
            try validator.fail("New object identity changed: \(relative)")
        }
        let parentPath = (relative as NSString).deletingLastPathComponent
        guard let parent = try validator.metadata(parentPath) else { try validator.fail("Missing creation parent") }
        let inheritedGroup = validator.host.ownership(validator.path(parentPath), parent).1
        let owners = validator.host.ownership(validator.path(relative), before)
        guard before.st_mode & S_IFMT == kind,
              before.st_mode & 0o7777 & ~mode == 0,
              owners.0 == 0,
              owners.1 == 0 || owners.1 == inheritedGroup,
              before.st_flags == 0,
              !(try validator.host.hasACL(descriptor)),
              kind != S_IFREG || before.st_nlink == 1 else {
            try validator.fail("Unsafe newly created object; ownership left unchanged: \(relative)")
        }
        try validator.host.setOwnership(descriptor, uid: 0, gid: 0)
        guard fchmod(descriptor, mode) == 0,
              fsync(descriptor) == 0 else {
            try validator.fail("Cannot establish new object permissions: \(relative)")
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              let final = try validator.metadata(relative),
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_dev == final.st_dev,
              after.st_ino == final.st_ino,
              after.st_mode & 0o7777 == mode,
              after.st_flags == 0,
              !(try validator.host.hasACL(descriptor)) else {
            try validator.fail("Created object changed during ownership establishment: \(relative)")
        }
        let finalOwners = validator.host.ownership(validator.path(relative), after)
        guard finalOwners.0 == 0, finalOwners.1 == 0 else {
            try validator.fail("Could not establish root:wheel ownership: \(relative)")
        }
        try validator.assertNode(relative, kind: kind, mode: mode)
    }

    func publish(staged: Validator, target: String) throws {
        // Exclusive descriptor-relative rename prevents an admin racing a new symlink/file
        // into /Applications from redirecting root writes or having foreign content replaced.
        let parent = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        let sourceFD = try openDirectory(staged.root, relative: parent)
        defer { close(sourceFD) }
        let targetFD = try openDirectory(validator.root, relative: parent)
        defer { close(targetFD) }
        guard renameatx_np(sourceFD, name, targetFD, name, UInt32(RENAME_EXCL)) == 0 else {
            try validator.fail("Exclusive publish refused for \(target) (errno \(errno)); partial setup needs repair")
        }
    }

    func removeEmptyStaging() throws {
        let directories = [
            "/payload/Applications", "/payload/Library/PrivilegedHelperTools", "/payload/Library/LaunchDaemons",
            "/payload/Library/Application Support/Hearth", "/payload/Library/Application Support", "/payload/Library",
            "/payload/usr/local/bin", "/payload/usr/local", "/payload/usr", "/payload", ""
        ]
        for relative in directories {
            guard rmdir(validator.path(staging + relative)) == 0 else {
                try validator.fail("Staging contains unexpected entries or cannot be cleared; repair needed")
            }
        }
    }
}
