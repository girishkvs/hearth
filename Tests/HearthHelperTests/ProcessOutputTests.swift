import Darwin
import Foundation
import XCTest
@testable import HearthHelper

final class ProcessOutputTests: XCTestCase {
    func testFakeReadOnlyBackendDoesNotTouchLeaseContents() throws {
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
        let process = FakePMSetProcess(output: "AC Power:\n sleep 5\n displaysleep 10\n")
        let value = try PMSetBackend(process: process).readMinutes(
            profile: .adapter, setting: .display, lease: journal, maintenance: maintenance
        )
        XCTAssertEqual(value, 10)
        XCTAssertEqual(process.recorded(), [.read])
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
