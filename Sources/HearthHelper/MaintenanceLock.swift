import Darwin
import Foundation
import HearthIPC

final class MaintenanceLease: @unchecked Sendable {
    let handle: FileHandle

    init(owning handle: FileHandle) {
        self.handle = handle
    }

    deinit {
        // The installer must preserve this inode. Closing, never LOCK_UN, permits
        // inherited references in a still-running child to retain the shared lock.
        try? handle.close()
    }
}

protocol MaintenanceLockProviding: Sendable {
    func acquire() throws -> MaintenanceLease
}

struct ProtectedMaintenanceLock: MaintenanceLockProviding {
    func acquire() throws -> MaintenanceLease {
        let installation = ProtectedHelperInstallation()
        let handle = try installation.openOperationLock()
        let lease = MaintenanceLease(owning: handle)
        guard flock(handle.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
            throw HelperClientError.unavailable("Hearth setup/removal holds the maintenance lock. This batch was not queued.")
        }
        return lease
    }
}
