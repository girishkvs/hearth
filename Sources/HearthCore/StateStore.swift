import Darwin
import Foundation

struct OverrideState: Codable, Equatable, Sendable {
    let original: Int
    let applied: Int
}

struct PendingOperation: Codable, Equatable, Sendable {
    let action: PowerAction
    let original: Int
    let applied: Int
}

struct ProfileState: Codable, Equatable, Sendable {
    var override: OverrideState?
    var pending: PendingOperation?

    var isEmpty: Bool { override == nil && pending == nil }
}

struct SavedState: Codable, Equatable, Sendable {
    var version = 1
    var profiles: [String: ProfileState] = [:]

    func validate() throws {
        guard version == 1 else {
            throw HearthError.state("Unsupported Hearth state version \(version). Use a compatible Hearth version; state was not changed.")
        }
        for (key, record) in profiles {
            guard PowerProfile(rawValue: key) != nil, !record.isEmpty else {
                throw HearthError.state("Invalid profile in Hearth state. Restore values cannot be trusted.")
            }
            if let value = record.override {
                guard (1...Int(Int32.max)).contains(value.original), value.applied == 0 else {
                    throw HearthError.state("Invalid override in Hearth state. Restore values cannot be trusted.")
                }
            }
            if let pending = record.pending {
                let validOriginal = (0...Int(Int32.max)).contains(pending.original)
                let validApplied = (0...Int(Int32.max)).contains(pending.applied)
                guard validOriginal, validApplied, pending.original != pending.applied else {
                    throw HearthError.state("Invalid pending operation in Hearth state.")
                }
                switch pending.action {
                case .on:
                    guard record.override == nil, pending.original > 0, pending.applied == 0 else {
                        throw HearthError.state("Invalid pending activation in Hearth state.")
                    }
                case .restore:
                    guard let override = record.override,
                          pending.original == override.applied,
                          pending.applied == override.original else {
                        throw HearthError.state("Invalid pending restoration in Hearth state.")
                    }
                case .sleep:
                    guard pending.applied > 0 else {
                        throw HearthError.state("Invalid pending sleep timeout in Hearth state.")
                    }
                    if let override = record.override, pending.original != override.applied {
                        throw HearthError.state("Pending sleep timeout does not match its override.")
                    }
                }
            }
        }
    }
}

public struct StateStore: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hearth", isDirectory: true)
    }

    let directory: URL

    public init(directory: URL = StateStore.defaultDirectory) {
        self.directory = directory
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try withLockDescriptor { _ in try body() }
    }

    func withLockDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        try prepareDirectory()
        let lockURL = directory.appendingPathComponent("state.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw systemError("Open state lock") }
        defer { close(descriptor) }
        try validateFile(descriptor, label: "State lock")
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw HearthError.busy }
            throw systemError("Lock Hearth state")
        }
        // The helper holds a duplicate of this lock until its request finishes,
        // even if the unprivileged caller exits while the helper is working.
        return try body(descriptor)
    }

    func load() throws -> SavedState {
        let path = directory.appendingPathComponent("state.json").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return SavedState() }
            throw systemError("Open Hearth state")
        }
        defer { close(descriptor) }
        try validateFile(descriptor, label: "State file")
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw systemError("Inspect Hearth state") }
        guard info.st_size <= 65_536 else { throw HearthError.state("Hearth state is too large; it was not changed.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        let state: SavedState
        do {
            state = try JSONDecoder().decode(SavedState.self, from: data)
        } catch {
            throw HearthError.state("Hearth state is damaged at \(path): \(error.localizedDescription). No restore values will be guessed. Preserve this file for recovery.")
        }
        try state.validate()
        return state
    }

    func save(_ state: SavedState) throws {
        try state.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let temporary = directory.appendingPathComponent(".state-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw systemError("Create atomic state file") }
        defer {
            close(descriptor)
            unlink(temporary.path)
        }
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw systemError("Sync Hearth state") }
        let destination = directory.appendingPathComponent("state.json")
        guard rename(temporary.path, destination.path) == 0 else { throw systemError("Replace Hearth state") }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw systemError("Open Hearth state directory") }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw systemError("Sync Hearth state directory") }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if mkdir(directory.path, S_IRWXU) != 0, errno != EEXIST {
            throw systemError("Create Hearth state directory")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw systemError("Inspect Hearth state directory") }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            throw HearthError.state("Hearth state directory must be a real, private directory owned by you (mode 700): \(directory.path)")
        }
    }

    private func validateFile(_ descriptor: Int32, label: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw systemError("Inspect \(label)") }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else {
            throw HearthError.state("\(label) must be a private regular file owned by you (mode 600), without hard links.")
        }
    }

    private func systemError(_ operation: String) -> HearthError {
        .state("\(operation): \(String(cString: strerror(errno)))")
    }
}
