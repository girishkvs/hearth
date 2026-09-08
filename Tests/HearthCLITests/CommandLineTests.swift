import Foundation
import XCTest
import HearthCore
@testable import HearthCLI

final class CommandLineTests: XCTestCase {
    func testReleaseVersionUsesTheCanonicalVersionFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(HearthVersion.current, version)
        let notes = try String(contentsOf: root.appendingPathComponent("docs/releases/\(version).md"), encoding: .utf8)
        XCTAssertTrue(notes.contains("Hearth \(version)"))
    }
    func testDefaultStatusAndJSON() throws {
        XCTAssertEqual(try CommandLineParser().parse([]), .status(json: false))
        XCTAssertEqual(try CommandLineParser().parse(["status", "--json"]), .status(json: true))
    }

    func testDefaultBothAndRestoreAlias() throws {
        XCTAssertEqual(try CommandLineParser().parse(["on"]), .power(try PowerRequest(action: .on)))
        XCTAssertEqual(try CommandLineParser().parse(["off"]), .power(try PowerRequest(action: .restore)))
        XCTAssertEqual(
            try CommandLineParser().parse(["sleep", "--minutes", "10", "--power", "adapter"]),
            .power(try PowerRequest(action: .sleep, target: .adapter, minutes: 10))
        )
    }

    func testRejectsAmbiguousOrInvalidInputBeforeAnyEffects() {
        for args in [
            ["on", "--power", "ups"], ["on", "--minutes", "10"], ["restore", "--minutes", "1"],
            ["sleep"], ["sleep", "--minutes", "0"], ["sleep", "--minutes", "-1"],
            ["sleep", "--minutes", "1.5"], ["sleep", "--minutes", "1;id"],
            ["sleep", "--minutes", "9999999999999999999999999999"],
            ["on", "--power", "battery", "--power", "adapter"], ["on", "--power"],
            ["status", "--power", "both"], ["status", "--json", "--json"],
            ["web", "--port", "-1"], ["web", "--port", "65536"], ["web", "--host", "0.0.0.0"],
            ["web", "--no-open", "--no-open"], ["help", "on"], ["unknown"],
        ] {
            XCTAssertThrowsError(try CommandLineParser().parse(args), "\(args)")
        }
    }

    func testWebOptions() throws {
        XCTAssertEqual(try CommandLineParser().parse(["web"]), .web(port: 0, openBrowser: true))
        XCTAssertEqual(try CommandLineParser().parse(["web", "--no-open", "--port", "8080"]), .web(port: 8080, openBrowser: false))
    }

    func testSetupIsAnExplicitNoArgumentCommand() throws {
        XCTAssertEqual(try CommandLineParser().parse(["setup"]), .setup)
        for arguments in [
            ["setup", "--help"], ["setup", "--repair"], ["setup", "--install"],
            ["setup", "--power", "both"], ["setup", "dist/Hearth-Setup.pkg"], ["setup", ""],
        ] {
            XCTAssertThrowsError(try CommandLineParser().parse(arguments), "\(arguments)")
        }
    }

    func testSetupOnlyProvidesExplicitBuildReviewAndInstallGuidance() {
        let instructions = SetupInstructions().text
        XCTAssertTrue(instructions.contains("only prints guidance"))
        XCTAssertTrue(instructions.contains("scripts/package-installer.sh"))
        XCTAssertTrue(instructions.contains("versioned local setup package"))
        XCTAssertTrue(instructions.contains("scripts/install.sh --gui or --cli"))
        XCTAssertTrue(instructions.contains("revoked, missing, or incompatible"))
        XCTAssertTrue(instructions.contains("does not guarantee"))
        XCTAssertTrue(instructions.contains("scripts/uninstall.sh --restored --gui"))
    }
}
