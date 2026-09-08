import Darwin
import Foundation

extension InstallerTests {
    func installReadACL(_ path: String) throws {
        let result = try Host().run("/bin/chmod", ["+a", "everyone allow read", path])
        try assert(result.status == 0 && Host().hasACL(path), "native extended ACL is present in the fixture")
    }

    func repairFixture(_ name: String) throws -> (Maintenance, FakeHost, SupportRepairApproval) {
        let (target, host) = try fixture("repair-\(name)")
        host.adminDirectories.insert(target.path(target.support))
        let extraction = temporary.appendingPathComponent("repair-input-\(name)")
        try files.createDirectory(at: extraction, withIntermediateDirectories: false)
        let coordinator = Maintenance(validator: target, extraction: extraction)
        let approval = try coordinator.captureSupportRepair()
        return (coordinator, host, approval)
    }

    func testSupportRepair() throws {
        let (repair, host, approved) = try repairFixture("approved")
        try repair.repairSupportIfApproved()
        try assert(host.descriptorOwnershipChanges.isEmpty, "default installer does not repair an existing wrong-group folder")
        try plist(approved, repair.repairInput.path)
        let parent = repair.validator.path("/Library/Application Support")
        var before = stat()
        guard lstat(parent, &before) == 0 else { throw InstallFailure.refused("Cannot inspect repair parent") }
        try repair.repairSupportIfApproved()
        try repair.validator.assertNode(repair.validator.support, kind: S_IFDIR, mode: 0o755)
        try assert(host.descriptorOwnershipChanges.count == 1, "opt-in repair changes only the verified directory descriptor")
        let child = try repair.validator.metadata(repair.validator.support)!
        try assert(approved.matches(child, afterGroupChange: true), "repair preserves device, inode, birth time and modification time")
        var after = stat()
        guard lstat(parent, &after) == 0 else { throw InstallFailure.refused("Cannot inspect repair parent") }
        try assert(before.st_uid == after.st_uid && before.st_gid == after.st_gid &&
                   before.st_mode == after.st_mode && before.st_flags == after.st_flags &&
                   before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
                   before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
                   before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
                   before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                   "repair leaves all shared-parent ownership, permissions and timestamps unchanged")
        try assert(try files.contentsOfDirectory(atPath: repair.validator.path(repair.validator.support)).isEmpty,
                   "repair does not add or delete directory contents")
        try refused("a stale repair approval cannot be reused after the group changes") { try repair.repairSupportIfApproved() }
        try assert(host.descriptorOwnershipChanges.count == 1, "reused approval performs no further group change")

        for scenario in ["nonempty", "changed-empty", "replacement", "symlink", "owner", "group",
                         "mode", "flags", "acl", "service", "receipt", "artifact", "wrong-fingerprint", "fchown"] {
            let (candidate, candidateHost, fingerprint) = try repairFixture(scenario)
            try plist(fingerprint, candidate.repairInput.path)
            let path = candidate.validator.path(candidate.validator.support)
            switch scenario {
            case "nonempty":
                try write(Data("unrelated".utf8), path + "/unrelated")
            case "changed-empty":
                try write(Data("changed".utf8), path + "/temporary")
                try files.removeItem(atPath: path + "/temporary")
            case "replacement":
                try files.moveItem(atPath: path, toPath: path + "-original")
                try files.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            case "symlink":
                try files.moveItem(atPath: path, toPath: path + "-original")
                try files.createSymbolicLink(atPath: path, withDestinationPath: path + "-original")
            case "owner":
                candidateHost.wrongOwners.insert(path)
            case "group":
                candidateHost.adminDirectories.remove(path)
            case "mode":
                try files.setAttributes([.posixPermissions: 0o775], ofItemAtPath: path)
            case "flags":
                guard chflags(path, UInt32(UF_HIDDEN)) == 0 else { throw InstallFailure.refused("Cannot set test flags") }
            case "acl":
                try installReadACL(path)
            case "service":
                candidateHost.registered = true
            case "receipt":
                try appleReceipt(candidate.validator)
            case "artifact":
                try write(Data("foreign helper".utf8), candidate.validator.path(candidate.validator.helper), mode: 0o755)
            case "wrong-fingerprint":
                try plist(approved, candidate.repairInput.path)
            case "fchown":
                candidateHost.ownershipFailure = true
            default:
                throw InstallFailure.refused("Unknown repair test")
            }
            try refused("bounded repair refuses \(scenario)") { try candidate.repairSupportIfApproved() }
            try assert(candidateHost.descriptorOwnershipChanges.isEmpty, "refused \(scenario) repair leaves ownership unchanged")
            if scenario == "flags" { guard chflags(path, 0) == 0 else { throw InstallFailure.refused("Cannot clear test flags") } }
        }

        let (source, _) = try fixture("repair-install-source")
        try payload(source)
        let package = try extractionFor(source, name: "repair-install-extraction")
        let (target, installHost) = try fixture("repair-install-target")
        installHost.adminDirectories.insert(target.path(target.support))
        let setup = Maintenance(validator: target, extraction: package)
        let fingerprint = try setup.captureSupportRepair()
        try plist(fingerprint, setup.repairInput.path)
        try setup.run("setup-preflight")
        try target.assertNode(target.support, kind: S_IFDIR, mode: 0o755)
        try assert(!installHost.registered, "approved repair is integrated before strict preflight without early service activation")
        try setup.run("setup-postflight")
        try assert(installHost.registered && target.preflight() != nil, "repair-enabled setup completes through the normal verified installation flow")
    }
}
