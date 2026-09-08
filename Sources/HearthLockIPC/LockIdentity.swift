import AppKit
import Darwin
import Foundation
import HearthCore
import HearthIPC
import Security

struct LockPeerRequirements: Sendable {
    let app: ValidatedCodeRequirement
    let clients: ValidatedCodeRequirement

    init(policy: HelperAuthorizationPolicy) throws {
        app = try ValidatedCodeRequirement(
            #"identifier "dev.girishkvs.hearth" and cdhash H"\#(policy.appCodeHash)""#
        )
        clients = policy.clientsRequirement
    }

    init(app: ValidatedCodeRequirement, clients: ValidatedCodeRequirement) {
        self.app = app
        self.clients = clients
    }
}

struct LockCodeIdentity {
    func requirements() throws -> LockPeerRequirements {
        guard getuid() != 0, geteuid() == getuid() else {
            throw IdleLockClientError.setupRequired("Run Hearth as your normal local user, without sudo.")
        }
        return try LockPeerRequirements(policy: ProtectedHelperInstallation().loadPolicy())
    }

    func validateCurrentApp(_ requirements: LockPeerRequirements) throws {
        var dynamic: SecCode?
        var code: SecStaticCode?
        let requirement = try requirement(requirements.app)
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCheckValidity(dynamic, [], requirement) == errSecSuccess,
              SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement
              ) == errSecSuccess else {
            throw IdleLockClientError.setupRequired("Only the enrolled native Hearth app may host Lock. Run explicit setup/repair.")
        }
    }

    func launchApp(_ requirements: LockPeerRequirements) throws {
        let url = URL(fileURLWithPath: "/Applications/Hearth.app", isDirectory: true)
        // Match the installer's fixed layout, including stock admin-writable
        // /Applications. Check the full signature immediately before launch;
        // the final live XPC app pin remains mandatory, not inferred from a path.
        try validateLaunchPath()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode),
                try requirement(requirements.app)
              ) == errSecSuccess else {
            throw IdleLockClientError.setupRequired("Installed Hearth.app does not match enrolled code. Run explicit setup/repair.")
        }
        let waiter = LockReplyWaiter<Bool>()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        // NSWorkspace documents its completion on a concurrent queue. This call
        // runs on the client's coordinator, never dispatching to a blocked main.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            waiter.complete(.success(app != nil && error == nil))
        }
        let failure = IdleLockClientError.unavailable("Hearth could not open. Open the installed app and try the explicit action again.")
        guard try waiter.wait(seconds: 10, failure: failure) else { throw failure }
    }

    private func requirement(_ value: ValidatedCodeRequirement) throws -> SecRequirement {
        var result: SecRequirement?
        guard SecRequirementCreateWithString(value.text as CFString, [], &result) == errSecSuccess, let result else {
            throw IdleLockClientError.setupRequired("Invalid enrolled app requirement.")
        }
        return result
    }

    private func validateLaunchPath() throws {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw unsafePath() }
        defer { close(descriptor) }
        for component in ["Applications", "Hearth.app"] {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw unsafePath() }
            close(descriptor)
            descriptor = next
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw unsafePath() }
            try LockFileChecks().validateLaunchDirectory(
                info, applications: component == "Applications", hasACL: LockFileChecks().hasACL(descriptor)
            )
        }
    }

    private func unsafePath() -> IdleLockClientError {
        .setupRequired("The fixed installed Hearth.app path is missing or not protected. Run explicit setup/repair.")
    }
}

protocol LockLifetimeLease: AnyObject, Sendable {}

// A cooperative singleton, not a secret or an endpoint archive. It remains open
// through every accepted job, including client interruption and listener release.
final class LockRuntimeLease: LockLifetimeLease, @unchecked Sendable {
    private let descriptor: Int32

    init(directory: URL = StateStore.defaultDirectory.appendingPathComponent("lock-runtime", isDirectory: true)) throws {
        let checks = LockFileChecks()
        let parent = try checks.openRuntimeDirectory(directory)
        defer { close(parent) }
        var fd = openat(parent, "listener.lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0, errno == EEXIST {
            fd = openat(parent, "listener.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { throw checks.failure() }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0,
                  info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o7777 == 0o600,
                  info.st_nlink == 1,
                  try !checks.hasACL(fd) else { throw checks.failure() }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw IdleLockClientError.unavailable("Another native Hearth Lock listener is still running.")
            }
            descriptor = fd
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(descriptor) }
}

struct LockFileChecks {
    func validateLaunchDirectory(_ info: stat, applications: Bool, hasACL: Bool) throws {
        let expectedMode: mode_t = applications ? 0o775 : 0o755
        let expectedGroup: gid_t = applications ? 80 : 0
        guard info.st_uid == 0,
              info.st_gid == expectedGroup,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o7777 == expectedMode,
              !hasACL else {
            throw IdleLockClientError.setupRequired("The installed app path does not match Hearth's protected package layout.")
        }
    }

    func openRuntimeDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw failure() }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        do {
            let components = url.path.split(separator: "/").map(String.init)
            for (index, component) in components.enumerated() {
                let privateDirectory = index >= components.count - 2
                if privateDirectory {
                    guard mkdirat(descriptor, component, 0o700) == 0 || errno == EEXIST else { throw failure() }
                }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure() }
                close(descriptor)
                descriptor = next
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw failure() }
                if privateDirectory {
                    guard info.st_uid == getuid(),
                          info.st_mode & 0o7777 == 0o700,
                          try !hasACL(descriptor) else { throw failure() }
                } else {
                    let trustedOwner = info.st_uid == 0 || info.st_uid == getuid()
                    let protectedOrSticky = info.st_mode & 0o022 == 0 ||
                        (info.st_uid == 0 && info.st_mode & S_ISVTX != 0)
                    guard trustedOwner, protectedOrSticky else { throw failure() }
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    func hasACL(_ descriptor: Int32) throws -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw failure() }
            return false
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == 0 || (result == -1 && errno == EINVAL) else { throw failure() }
        return result == 0
    }

    func failure() -> IdleLockClientError {
        .unavailable("Native Lock runtime has unsafe ownership, permissions, links, or ACLs.")
    }
}
