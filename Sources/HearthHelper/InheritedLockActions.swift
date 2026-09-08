import Darwin
import Foundation

final class InheritedLockActions {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    private var descriptors: [Int32] = []

    init(journal: Int32, maintenance: Int32, output: Int32) throws {
        do {
            try check(posix_spawn_file_actions_init(&actions))
            try check(posix_spawnattr_init(&attributes))
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
            // Normalize sources above every destination, even if launchd closed a
            // standard descriptor. No dup2 action may clobber a later action's source.
            for source in [journal, maintenance, output] {
                let descriptor = fcntl(source, F_DUPFD_CLOEXEC, 4)
                guard descriptor >= 0 else { throw POSIXError(.EBADF) }
                descriptors.append(descriptor)
            }
            try check(posix_spawn_file_actions_adddup2(&actions, descriptors[2], STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, descriptors[2], STDERR_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, descriptors[0], STDIN_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], 3))
        } catch {
            cleanUp()
            throw error
        }
    }

    deinit { cleanUp() }

    private func cleanUp() {
        if actions != nil { posix_spawn_file_actions_destroy(&actions); actions = nil }
        if attributes != nil { posix_spawnattr_destroy(&attributes); attributes = nil }
        descriptors.forEach { close($0) }
        descriptors = []
    }

    private func check(_ code: Int32) throws {
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
}
