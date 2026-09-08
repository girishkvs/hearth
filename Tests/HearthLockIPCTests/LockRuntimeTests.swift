import Darwin
import Foundation
import XCTest
@testable import HearthLockIPC

final class LockRuntimeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Foundation may shorten /private/var back to its /var symlink. The
        // production descriptor walk deliberately rejects that alias.
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(.ENOENT)
        }
        defer { free(resolved) }
        directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("hearth-lock-runtime-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testLaunchPathMetadataMatchesInstallerWithoutReadingInstalledApp() throws {
        let checks = LockFileChecks()
        var metadata = stat()
        metadata.st_uid = 0
        metadata.st_gid = 80
        metadata.st_mode = S_IFDIR | 0o775
        XCTAssertNoThrow(try checks.validateLaunchDirectory(metadata, applications: true, hasACL: false))
        XCTAssertThrowsError(try checks.validateLaunchDirectory(metadata, applications: true, hasACL: true))
        XCTAssertThrowsError(try checks.validateLaunchDirectory(metadata, applications: false, hasACL: false))
        metadata.st_gid = 0
        XCTAssertThrowsError(
            try checks.validateLaunchDirectory(metadata, applications: false, hasACL: false),
            "A root:wheel app bundle must still refuse group-writable 0775 mode."
        )
        metadata.st_mode = S_IFDIR | 0o755
        XCTAssertNoThrow(try checks.validateLaunchDirectory(metadata, applications: false, hasACL: false))
        XCTAssertThrowsError(try checks.validateLaunchDirectory(metadata, applications: false, hasACL: true))
        metadata.st_uid = getuid()
        XCTAssertThrowsError(try checks.validateLaunchDirectory(metadata, applications: false, hasACL: false))
        metadata.st_uid = 0
        metadata.st_mode = S_IFLNK | 0o755
        XCTAssertThrowsError(try checks.validateLaunchDirectory(metadata, applications: false, hasACL: false))
    }

    func testSingletonHeldUntilLastLeaseReleaseAndLockFilePersists() throws {
        let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
        var lease: LockRuntimeLease? = try LockRuntimeLease(directory: runtime)
        XCTAssertThrowsError(try LockRuntimeLease(directory: runtime))
        withExtendedLifetime(lease) {}
        lease = nil
        let replacement = try LockRuntimeLease(directory: runtime)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("listener.lock").path))
        withExtendedLifetime(replacement) {}
    }

    func testSymlinkAndHardlinkLockAreRejected() throws {
        let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let target = directory.appendingPathComponent("target")
        let path = runtime.appendingPathComponent("listener.lock")
        let fd = open(target.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(fd)
        XCTAssertEqual(symlink(target.path, path.path), 0)
        XCTAssertThrowsError(try LockRuntimeLease(directory: runtime))
        XCTAssertEqual(unlink(path.path), 0)
        XCTAssertEqual(link(target.path, path.path), 0)
        XCTAssertThrowsError(try LockRuntimeLease(directory: runtime))
    }

    func testSymlinkDirectoryAndLoosePermissionsAreRejected() throws {
        let runtime = directory.appendingPathComponent("runtime")
        XCTAssertEqual(symlink(directory.path, runtime.path), 0)
        XCTAssertThrowsError(try LockRuntimeLease(directory: runtime))
        XCTAssertEqual(unlink(runtime.path), 0)
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]
        )
        XCTAssertThrowsError(try LockRuntimeLease(directory: runtime))
        XCTAssertEqual(chmod(runtime.path, 0o700), 0)
        let lockFile = runtime.appendingPathComponent("listener.lock")
        let fd = open(lockFile.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(fd)
        XCTAssertThrowsError(try LockRuntimeLease(directory: runtime))
    }
}
