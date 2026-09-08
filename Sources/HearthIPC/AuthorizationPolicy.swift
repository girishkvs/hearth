import CoreFoundation
import Darwin
import Foundation
import Security

public struct ValidatedCodeRequirement: Sendable {
    public let text: String

    public init(_ text: String) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              requirement != nil else {
            throw HelperClientError.incompatible("Invalid code signing requirement. Run explicit setup/repair.")
        }
        self.text = text
    }
}

public struct HelperAuthorizationPolicy: Sendable {
    public let appCodeHash: String
    public let cliCodeHash: String
    public let helperCodeHash: String
    public let buildIdentifier: String
    public let clientsRequirement: ValidatedCodeRequirement
    public let helperRequirement: ValidatedCodeRequirement

    public init(data: Data) throws {
        guard data.count <= 4096,
              let fields = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(fields.keys) == [
                "FormatVersion", "ProtocolVersion", "AppCodeHash", "CLICodeHash", "HelperCodeHash", "BuildIdentifier",
              ] else {
            throw HelperClientError.incompatible("Invalid Hearth authorization policy fields. Run explicit setup/repair.")
        }
        let validator = PolicyValueValidator()
        try validator.version(fields["FormatVersion"], expected: 1)
        try validator.version(fields["ProtocolVersion"], expected: HelperWireCodec.version)
        appCodeHash = try validator.hash(fields["AppCodeHash"])
        cliCodeHash = try validator.hash(fields["CLICodeHash"])
        helperCodeHash = try validator.hash(fields["HelperCodeHash"])
        guard let build = fields["BuildIdentifier"] as? String,
              !build.isEmpty, build.utf8.count <= 256 else {
            throw HelperClientError.incompatible("Invalid Hearth build identifier.")
        }
        buildIdentifier = build
        clientsRequirement = try ValidatedCodeRequirement(
            #"(identifier "dev.girishkvs.hearth" and cdhash H"\#(appCodeHash)") or (identifier "dev.girishkvs.hearth.cli" and cdhash H"\#(cliCodeHash)")"#
        )
        helperRequirement = try ValidatedCodeRequirement(
            #"identifier "dev.girishkvs.hearth.helper" and cdhash H"\#(helperCodeHash)""#
        )
    }
}

private struct PolicyValueValidator {
    func version(_ value: Any?, expected: Int) throws {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.int64Value == expected else {
            throw HelperClientError.incompatible(HelperWireCodec.updateRequiredMessage)
        }
    }

    func hash(_ value: Any?) throws -> String {
        guard let hash = value as? String,
              hash.utf8.count == 40,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HelperClientError.incompatible("Invalid Hearth CDHash. Run explicit setup/repair.")
        }
        return hash
    }
}

public struct ProtectedHelperInstallation: Sendable {
    public init() {}

    public func loadPolicy() throws -> HelperAuthorizationPolicy {
        let descriptor = try ProtectedFiles().open(
            HelperInstallation.policyPath, mode: 0o644, managedDirectory: "/Library/Application Support/Hearth"
        )
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 4097), data.count <= 4096 else {
            throw HelperClientError.incompatible("Hearth authorization policy is too large.")
        }
        return try HelperAuthorizationPolicy(data: data)
    }

    public func validateDaemonFiles(policy: HelperAuthorizationPolicy) throws {
        for (path, mode) in [
            (HelperInstallation.executablePath, mode_t(0o755)),
            (HelperInstallation.launchDaemonPath, mode_t(0o644)),
            (HelperInstallation.operationLockPath, mode_t(0o600)),
            ("/usr/bin/pmset", mode_t(0o755)),
        ] {
            let descriptor = try ProtectedFiles().open(path, mode: mode)
            close(descriptor)
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let url = URL(fileURLWithPath: HelperInstallation.executablePath)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(policy.helperRequirement.text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement
              ) == errSecSuccess else {
            throw HelperClientError.setupRequired("Installed Hearth helper signature does not match protected policy.")
        }
    }

    public func openOperationLock() throws -> FileHandle {
        let descriptor = try ProtectedFiles().open(
            HelperInstallation.operationLockPath, mode: 0o600,
            managedDirectory: "/Library/Application Support/Hearth", writable: true
        )
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

}

struct ProtectedFileMetadata {
    let owner: uid_t
    let group: gid_t
    let mode: mode_t
    let links: nlink_t
    let hasACL: Bool

    func validate(directory: Bool, exactMode: mode_t? = nil) throws {
        let type = mode & S_IFMT
        guard owner == 0,
              type == (directory ? S_IFDIR : S_IFREG),
              mode & 0o022 == 0,
              mode & 0o7000 == 0,
              !hasACL,
              directory || links == 1 else {
            throw HelperClientError.setupRequired("Hearth installation has unsafe ownership, permissions, links, or ACLs.")
        }
        if let exactMode {
            guard group == 0, mode & 0o777 == exactMode else {
                throw HelperClientError.setupRequired("Hearth installed file modes must match the protected package layout.")
            }
        }
    }
}

struct ProtectedFiles {
    func open(_ path: String, mode: mode_t, managedDirectory: String? = nil, writable: Bool = false) throws -> Int32 {
        // Traverse from a descriptor for /, rejecting symlinks at EVERY component.
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure() }
        do {
            try validate(descriptor, directory: true)
            let components = path.split(separator: "/").map(String.init)
            var current = ""
            for (index, component) in components.enumerated() {
                current += "/" + component
                let directory = index < components.count - 1
                let access = !directory && writable ? O_RDWR : O_RDONLY
                let flags = access | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
                let next = openat(descriptor, component, flags)
                guard next >= 0 else { throw failure() }
                close(descriptor)
                descriptor = next
                let exactMode = directory ? (current == managedDirectory ? mode_t(0o755) : nil) : mode
                try validate(descriptor, directory: directory, exactMode: exactMode)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validate(_ descriptor: Int32, directory: Bool, exactMode: mode_t? = nil) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure() }
        try ProtectedFileMetadata(
            owner: info.st_uid, group: info.st_gid, mode: info.st_mode, links: info.st_nlink,
            hasACL: hasExtendedACL(descriptor)
        ).validate(directory: directory, exactMode: exactMode)
    }

    private func hasExtendedACL(_ descriptor: Int32) throws -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin returns ENOENT for an absent ACL on an already-open valid fd.
            guard errno == ENOENT else { throw failure() }
            return false
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        guard result == 0 || (result == -1 && errno == EINVAL) else { throw failure() }
        return result == 0
    }

    private func failure() -> HelperClientError {
        .setupRequired("Hearth helper is missing or its protected installation cannot be verified. Run explicit setup/repair.")
    }
}
