import Darwin
import Foundation
import HearthIPC

final class LockLease: @unchecked Sendable {
    let handle: FileHandle

    init(transferring handle: FileHandle, callerUID: uid_t) throws {
        // Own the duplicate before returning to XPC or scheduling any work. Closing an
        // XPC connection cannot close this reference to the caller's open description.
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        guard descriptor >= 0 else { throw HelperClientError.unavailable("Cannot retain the journal lock lease.") }
        do {
            var info = stat()
            let flags = fcntl(descriptor, F_GETFL)
            guard callerUID != 0,
                  fstat(descriptor, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == callerUID,
                  info.st_nlink == 1,
                  info.st_mode & 0o7777 == 0o600,
                  flags >= 0,
                  flags & O_ACCMODE == O_RDWR,
                  flags & (O_APPEND | O_NONBLOCK | O_ASYNC | O_EVTONLY) == 0 else {
                throw HelperClientError.unavailable("Invalid journal lock lease.")
            }
            if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
                guard result == -1, errno == EINVAL else {
                    throw HelperClientError.unavailable("Journal lock lease must have no ACL entries.")
                }
            } else if errno != ENOENT {
                // ENOENT is Darwin's absent-ACL result for an already-open valid fd.
                throw HelperClientError.unavailable("Cannot validate journal lock lease ACL.")
            }
            self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit {
        // NEVER LOCK_UN: all copies, including pmset's stdin, share the flock.
        try? handle.close()
    }
}
