import AppKit
import Foundation
import WebKit
import XCTest

@MainActor
final class InstallerPageTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testStandardTitleAndDedicatedProjectLicenseStep() throws {
        let document = try XMLDocument(contentsOf: root.appendingPathComponent("Packaging/Installer/Setup.xml"))
        XCTAssertEqual(try document.nodes(forXPath: "/installer-gui-script/title").first?.stringValue, "Hearth")
        let license = try XCTUnwrap(document.nodes(forXPath: "/installer-gui-script/license").first as? XMLElement)
        XCTAssertEqual(license.attribute(forName: "file")?.stringValue, "License.txt")
        XCTAssertEqual(license.attribute(forName: "mime-type")?.stringValue, "text/plain")
        let conclusion = try XCTUnwrap(document.nodes(forXPath: "/installer-gui-script/conclusion").first as? XMLElement)
        XCTAssertEqual(conclusion.attribute(forName: "file")?.stringValue, "Conclusion.html")
        let text = try String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("MIT License\n\nCopyright (c) 2026 Girish Konda\n"))
        XCTAssertFalse(text.contains("ThirdPartyLicenses"))
    }

    func testIntroductionAndInformationUseSystemTypographyInBothAppearances() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 330),
                                  styleMask: [], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 330), configuration: configuration)
            page.appearance = window.appearance
            window.contentView = page
            defer { page.stopLoading() }
            for name in ["Setup", "Installation", "RepairInstallation", "Remove", "Conclusion"] {
                let html = try String(contentsOf: root.appendingPathComponent("Packaging/Installer/Resources/\(name).html"), encoding: .utf8)
                page.loadHTMLString(html, baseURL: nil)
                try await waitForPage(page, name: name)
                let style = try await page.evaluateJavaScript("""
                    ({ font: getComputedStyle(document.body).fontFamily,
                       size: getComputedStyle(document.body).fontSize,
                       color: getComputedStyle(document.body).color,
                       dark: matchMedia('(prefers-color-scheme: dark)').matches,
                       overflow: document.documentElement.scrollWidth > innerWidth,
                       headings: document.querySelectorAll('h1').length,
                       bold: document.querySelectorAll('strong, b').length,
                       text: document.body.innerText,
                       height: document.body.scrollHeight })
                    """) as? [String: Any]
                XCTAssertTrue((style?["font"] as? String)?.contains("-apple-system") == true)
                XCTAssertEqual(style?["size"] as? String, "13px")
                XCTAssertEqual(style?["dark"] as? Bool, appearance == .darkAqua)
                XCTAssertEqual(style?["overflow"] as? Bool, false)
                XCTAssertEqual(style?["headings"] as? Int, 0)
                XCTAssertEqual(style?["color"] as? String, appearance == .darkAqua ? "rgb(255, 255, 255)" : "rgb(0, 0, 0)")
                let text = style?["text"] as? String ?? ""
                if name == "Setup" {
                    XCTAssertTrue(text.contains("battery") && text.contains("plugged in"))
                    XCTAssertTrue(text.contains("menu bar") && text.contains("Terminal") && text.contains("browser"))
                    XCTAssertTrue(text.contains("Setup leaves your current sleep settings unchanged"))
                    XCTAssertFalse(text.contains("Welcome"))
                    XCTAssertFalse(text.contains("unsigned") || text.contains("administrator") || text.contains("repair"))
                    XCTAssertEqual(style?["bold"] as? Int, 0)
                    XCTAssertLessThan(text.split(whereSeparator: \.isWhitespace).count, 45)
                } else if name == "Installation" || name == "RepairInstallation" {
                    XCTAssertTrue(text.contains("Applications") && text.contains("small helper"))
                    XCTAssertTrue(text.contains("flame icon") && text.contains("hearth web"))
                    XCTAssertTrue(text.contains("administrator approval") && text.contains("everyday controls do not"))
                    XCTAssertTrue(text.contains("Hearth-Remove.pkg"))
                    XCTAssertTrue(text.contains("unsigned") && text.contains("not notarized"))
                    XCTAssertEqual(text.contains("group ownership"), name == "RepairInstallation")
                    if name == "Installation" {
                        XCTAssertFalse(text.contains("earlier attempt") || text.contains("Application Support"))
                        XCTAssertLessThanOrEqual(style?["height"] as? Int ?? .max, 330)
                    }
                } else if name == "Conclusion" {
                    XCTAssertTrue(text.contains("Open Finder > Applications and double-click Hearth"))
                    XCTAssertTrue(text.contains("open /Applications/Hearth.app"))
                    XCTAssertTrue(text.contains("flame icon") && text.contains("not the Dock"))
                    XCTAssertTrue(text.contains("Your sleep settings are unchanged"))
                    XCTAssertFalse(text.contains("Spotlight") || text.contains("automatically"))
                    XCTAssertLessThanOrEqual(style?["height"] as? Int ?? .max, 330)
                }
                try await savePreview(page, name: name, appearance: appearance)
            }
        }
    }

    func testTerminalProgressReplayPreview() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
        process.arguments = ["-v", "interactive=1", "-v", "columns=80",
                             "-f", root.appendingPathComponent("scripts/installer-progress.awk").path,
                             root.appendingPathComponent("scripts/tests/installer-progress-replay.txt").path]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: output, as: UTF8.self)
        let frames = text.components(separatedBy: "\r")
        let frame = try XCTUnwrap(frames.last { $0.contains("52%  Running package scripts") })
        XCTAssertEqual(frames.filter { $0.contains("52%") }.count, 1)
        XCTAssertFalse(text.contains("100%") || text.contains("successfully"))
        let escaped = frame.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 220),
                              styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
        page.appearance = window.appearance
        window.contentView = page
        defer { page.stopLoading() }
        page.loadHTMLString("""
            <!doctype html><meta charset="utf-8">
            <style>
            body { margin: 0; padding: 28px; color: #f1f3f4; background: #151719; }
            h1, p { font: 13px -apple-system, sans-serif; color: #aeb4ba; }
            h1 { margin: 0 0 24px; font-weight: 600; }
            pre { font: 14px/1.7 ui-monospace, Menlo, monospace; margin: 0 0 24px; }
            </style><body data-page="TerminalProgress">
            <h1>Hearth / Terminal progress replay</h1>
            <pre>Hearth setup \(version) (sudo password entry is hidden).

            \(escaped)</pre>
            <p>Synthetic Installer output through the real formatter. Not a live installation.</p>
            </body>
            """, baseURL: nil)
        try await waitForPage(page, name: "TerminalProgress")
        let overflow = try await page.evaluateJavaScript("document.documentElement.scrollWidth > innerWidth") as? Bool
        XCTAssertEqual(overflow, false)
        try await savePreview(page, name: "TerminalProgress", appearance: .darkAqua)
    }

    private func waitForPage(_ page: WKWebView, name: String) async throws {
        for _ in 0..<100 {
            if let ready = try? await page.evaluateJavaScript("document.readyState === 'complete' && document.body.dataset.page === '\(name)'") as? Bool,
               ready {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "HearthInstallerPageTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Installer page did not finish loading."])
    }

    private func savePreview(_ page: WKWebView, name: String, appearance: NSAppearance.Name) async throws {
        guard let path = ProcessInfo.processInfo.environment["HEARTH_INSTALLER_PREVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let height = try await page.evaluateJavaScript("document.body.scrollHeight") as? Double ?? 330
        let original = page.frame
        page.frame.size.height = max(original.height, height + 8)
        defer { page.frame = original }
        page.layoutSubtreeIfNeeded()
        let snapshot: NSImage = try await withCheckedThrowingContinuation { continuation in
            page.takeSnapshot(with: nil) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "HearthInstallerPageTests", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "WebKit did not produce a preview image."]))
                }
            }
        }
        let image = try XCTUnwrap(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let names = ["Setup": "introduction", "Installation": "read-me",
                     "RepairInstallation": "read-me-repair", "Remove": "removal",
                     "Conclusion": "first-launch", "TerminalProgress": "terminal-progress"]
        let label = try XCTUnwrap(names[name])
        let mode = appearance == .darkAqua ? "dark" : "light"
        try png.write(to: directory.appendingPathComponent("\(label)-\(mode).png"), options: .atomic)
    }
}
