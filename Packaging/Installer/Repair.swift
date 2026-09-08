import Darwin
import Foundation

struct SupportRepairApproval: Codable, Equatable {
    let formatVersion: Int
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ info: stat) {
        formatVersion = 1
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }

    func matches(_ info: stat, afterGroupChange: Bool = false) -> Bool {
        let current = SupportRepairApproval(info)
        return formatVersion == 1 &&
            device == current.device &&
            inode == current.inode &&
            birthSeconds == current.birthSeconds &&
            birthNanoseconds == current.birthNanoseconds &&
            modifiedSeconds == current.modifiedSeconds &&
            modifiedNanoseconds == current.modifiedNanoseconds &&
            (afterGroupChange || (changedSeconds == current.changedSeconds && changedNanoseconds == current.changedNanoseconds))
    }
}

extension Maintenance {
    var repairInput: URL { extraction.appendingPathComponent("empty-support-repair.plist") }

    func approvedSupportRepair() throws -> SupportRepairApproval? {
        var info = stat()
        if lstat(repairInput.path, &info) != 0 {
            if errno == ENOENT { return nil }
            try validator.fail("Cannot inspect packaged repair approval")
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= 4096,
              info.st_flags == 0,
              !(try validator.host.hasACL(repairInput.path)) else {
            try validator.fail("Unsafe packaged repair approval")
        }
        let descriptor = open(repairInput.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { try validator.fail("Cannot read packaged repair approval") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == info.st_dev,
              opened.st_ino == info.st_ino else {
            try validator.fail("Packaged repair approval changed")
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        let approval = try PropertyListDecoder().decode(SupportRepairApproval.self, from: data)
        guard approval.formatVersion == 1,
              approval.device > 0,
              approval.inode > 0 else { try validator.fail("Unsupported repair approval") }
        return approval
    }

    func verifyRepairContext() throws {
        try validator.validateSystemAncestors()
        for directory in ["/Library/PrivilegedHelperTools", "/Library/LaunchDaemons", "/usr/local", "/usr/local/bin"] {
            if try validator.metadata(directory) != nil {
                try validator.assertNode(directory, kind: S_IFDIR, mode: 0o755, systemAncestor: true)
            }
        }
        for target in validator.payloadRoots() + [validator.receipt, lock, marker, staging] {
            guard try validator.metadata(target) == nil else {
                try validator.fail("Repair refused because Hearth installation state changed: \(target)")
            }
        }
        try validator.validatePackageReceipts(verifiedInstallation: false)
        guard try serviceStatus() == nil else { try validator.fail("Repair refused because a Hearth service is registered") }
    }

    func emptyDirectory(_ descriptor: Int32) throws -> Bool {
        let copy = dup(descriptor)
        guard copy >= 0 else { try validator.fail("Cannot duplicate repair directory descriptor") }
        guard let directory = fdopendir(copy) else {
            close(copy)
            try validator.fail("Cannot inspect repair directory contents")
        }
        defer { closedir(directory) }
        rewinddir(directory)
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { return false }
            errno = 0
        }
        guard errno == 0 else { try validator.fail("Cannot read repair directory contents") }
        return true
    }

    func inspectRepairDirectory(_ descriptor: Int32, parent: Int32, group: gid_t) throws -> stat {
        var info = stat()
        var named = stat()
        guard fstat(descriptor, &info) == 0,
              fstatat(parent, "Hearth", &named, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == named.st_dev,
              info.st_ino == named.st_ino else { try validator.fail("Repair directory identity changed") }
        let owners = validator.host.ownership(validator.path(validator.support), info)
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o7777 == 0o755,
              owners.0 == 0,
              owners.1 == group,
              info.st_nlink == 2,
              info.st_flags == 0,
              !(try validator.host.hasACL(descriptor)),
              try emptyDirectory(descriptor) else {
            try validator.fail("Repair requires the unchanged empty root:admin 0755 Hearth setup directory, without flags, links, or ACLs")
        }
        return info
    }

    func withRepairDirectory<T>(_ action: (Int32, Int32) throws -> T) throws -> T {
        let parent = try openDirectory(validator.root, relative: "/Library/Application Support")
        defer { close(parent) }
        let directory = openat(parent, "Hearth", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { try validator.fail("Approved repair directory is missing or is a link") }
        defer { close(directory) }
        return try action(directory, parent)
    }

    func captureSupportRepair() throws -> SupportRepairApproval {
        try verifyRepairContext()
        return try withRepairDirectory { directory, parent in
            SupportRepairApproval(try inspectRepairDirectory(directory, parent: parent, group: 80))
        }
    }

    func repairSupportIfApproved() throws {
        guard let approval = try approvedSupportRepair() else { return }
        try verifyRepairContext()
        try withRepairDirectory { directory, parent in
            guard flock(directory, LOCK_EX | LOCK_NB) == 0 else {
                try validator.fail("Another repair is using the approved directory")
            }
            let before = try inspectRepairDirectory(directory, parent: parent, group: 80)
            guard approval.matches(before) else { try validator.fail("Repair directory no longer matches the approved fingerprint") }
            try verifyRepairContext()
            guard approval.matches(try inspectRepairDirectory(directory, parent: parent, group: 80)) else {
                try validator.fail("Repair directory changed before the group update")
            }
            // The UID sentinel preserves the owner. Only this verified inode's group changes.
            try validator.host.setOwnership(directory, uid: uid_t.max, gid: 0)
            guard fsync(directory) == 0 else { try validator.fail("Cannot persist repaired group ownership") }
            let after = try inspectRepairDirectory(directory, parent: parent, group: 0)
            guard approval.matches(after, afterGroupChange: true) else {
                try validator.fail("Repair directory changed unexpectedly; setup stopped")
            }
        }
        print("Corrected only the group ownership of the approved empty Hearth setup directory. Sleep settings and shared parent metadata were not changed.")
    }
}
