import Darwin
import Foundation
import XCTest
@testable import HearthHelper

final class ProcessOutputTests: XCTestCase {
    func testReadOnlyBackendCompletesWithEOFAndDoesNotTouchLeaseContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-output-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalPath = directory.appendingPathComponent("journal")
        let maintenancePath = directory.appendingPathComponent("operation")
        let contents = Data("unchanged lease data".utf8)
        try contents.write(to: journalPath)
        try contents.write(to: maintenancePath)
        let journal = try FileHandle(forUpdating: journalPath)
        let maintenance = try FileHandle(forUpdating: maintenancePath)
        defer { try? journal.close(); try? maintenance.close() }
        let finished = expectation(description: "read-only pmset drains and returns")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                let value = try PMSetBackend().readMinutes(profile: "adapter", lease: journal, maintenance: maintenance)
                XCTAssertGreaterThanOrEqual(value, 0)
            } catch {
                XCTFail("Read-only backend failed: \(error)")
            }
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: journalPath), contents)
        XCTAssertEqual(try Data(contentsOf: maintenancePath), contents)
    }

    func testParentSpawnCopiesMustCloseBeforePipeEOF() throws {
        let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw POSIXError(.EIO) }
        defer { close(input) }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        var actions: InheritedLockActions? = try InheritedLockActions(
            journal: input, maintenance: input, output: pipe.fileHandleForWriting.fileDescriptor
        )
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK), 0)
        var byte: UInt8 = 0
        withExtendedLifetime(actions) {
            XCTAssertEqual(read(pipe.fileHandleForReading.fileDescriptor, &byte, 1), -1)
            XCTAssertEqual(errno, EAGAIN)
        }
        actions = nil
        XCTAssertEqual(read(pipe.fileHandleForReading.fileDescriptor, &byte, 1), 0)
    }
}
