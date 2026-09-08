import AppKit
import Foundation
import HearthCore
import HearthWeb
import WebKit
import XCTest

private final class PageHelperRunner: PowerCommandRunning, @unchecked Sendable {
    let power = FakeRunner()
    private let lock = NSLock()
    private var helper = HelperAvailability(state: .setupRequired, message: "Fake helper needs setup.")
    private var attempts = 0
    private var rejectRequests = false
    private var batteryAvailable = true

    var applyAttempts: Int { lock.withLock { attempts } }

    func helperAvailability() -> HelperAvailability {
        lock.withLock { helper }
    }

    func setAvailability(_ availability: HelperAvailability) {
        lock.withLock { helper = availability }
    }

    func failRequests(_ reject: Bool) { lock.withLock { rejectRequests = reject } }
    func omitBattery() { lock.withLock { batteryAvailable = false } }

    func readSettings() throws -> PowerSettings {
        let settings = try power.readSettings()
        let values = lock.withLock { batteryAvailable ? settings.values : settings.values.filter { $0.key != .battery } }
        return PowerSettings(values: values, currentSource: settings.currentSource)
    }

    func apply(_ changes: [PowerChange]) throws -> [CommandOutcome] {
        let available = lock.withLock {
            attempts += 1
            return helper.isReady
        }
        guard available else {
            XCTFail("An unavailable helper must not receive a power write.")
            throw HearthError.command("Fake helper unavailable.")
        }
        if lock.withLock({ rejectRequests }) { throw HearthError.command("Fake helper rejected the request.") }
        return try power.apply(changes)
    }
}

@MainActor
final class HearthPageTests: XCTestCase {
    func testEmbeddedPageAuthenticatesAndUsesSameOriginWrites() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: fixture.url))

        try await waitFor(page, expression: "document.getElementById('controls')?.disabled === false")
        let fragmentRemoved = try await page.evaluateJavaScript("location.hash === ''") as? Bool
        XCTAssertEqual(fragmentRemoved, true)
        let target = try await page.evaluateJavaScript("document.getElementById('target').value") as? String
        XCTAssertEqual(target, "both")
        let advancedOpen = try await page.evaluateJavaScript("document.getElementById('advanced').open") as? Bool
        let initialAction = try await page.evaluateJavaScript("document.getElementById('keep-awake').textContent") as? String
        XCTAssertEqual(advancedOpen, false)
        XCTAssertEqual(initialAction, "Keep awake")
        let initial = try await page.evaluateJavaScript("document.getElementById('profiles').textContent") as? String
        XCTAssertTrue(initial?.contains("Idle sleep after 5 minutes") == true)
        XCTAssertTrue(initial?.contains("Never idle sleeps") == true)
        XCTAssertEqual(fixture.runner.applyCount, 0)
        let helper = try await page.evaluateJavaScript("document.getElementById('helper-heading').textContent") as? String
        XCTAssertEqual(helper, "Helper ready")

        try await preview(page, name: "ready")
        _ = try await page.evaluateJavaScript("document.getElementById('keep-awake').click()")
        try await waitFor(page, expression: "document.getElementById('activity').textContent.includes('Keep-awake settings applied')")
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 0, .adapter: 0])
        let restoreAction = try await page.evaluateJavaScript("document.getElementById('keep-awake').textContent") as? String
        let activeState = try await page.evaluateJavaScript("document.getElementById('state').textContent") as? String
        XCTAssertEqual(restoreAction, "Restore previous settings")
        XCTAssertEqual(activeState, "Keeping awake")
        try await preview(page, name: "keeping-awake")

        _ = try await page.evaluateJavaScript("document.getElementById('keep-awake').click()")
        try await waitFor(page, expression: "document.getElementById('activity').textContent.includes('Previous settings restored')")
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])

        _ = try await page.evaluateJavaScript("document.getElementById('advanced').open = true")
        try await preview(page, name: "advanced")
        _ = try await page.evaluateJavaScript("document.getElementById('minutes').value = '0'; document.getElementById('set-timeout').click()")
        let validation = try await page.evaluateJavaScript("document.getElementById('error').textContent") as? String
        XCTAssertTrue(validation?.contains("whole number") == true)
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])
        let overflow = try await page.evaluateJavaScript("document.documentElement.scrollWidth > innerWidth") as? Bool
        XCTAssertEqual(overflow, false)

        page.frame.size.width = 390
        let mobileOverflow = try await page.evaluateJavaScript("document.documentElement.scrollWidth > innerWidth") as? Bool
        XCTAssertEqual(mobileOverflow, false)
    }

    func testUnavailableHelperKeepsStatusAndGuidanceButDisablesWrites() async throws {
        let runner = PageHelperRunner()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-helper-page-\(UUID().uuidString)")
        let server = HearthWebServer(service: HearthService(runner: runner, stateDirectory: directory))
        defer {
            try? server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try server.start()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: url))
        try await waitFor(page, expression: "document.getElementById('helper-heading')?.textContent.includes('setup required') === true")

        for state in [HelperState.setupRequired, .incompatible, .unavailable] {
            runner.setAvailability(HelperAvailability(state: state, message: "Fake helper state: \(state.rawValue)"))
            _ = try await page.evaluateJavaScript("document.getElementById('refresh').click()")
            try await waitFor(page, expression: "document.getElementById('helper-message').textContent.includes('Fake helper state: \(state.rawValue)')")
            let disabled = try await page.evaluateJavaScript("document.getElementById('controls').disabled") as? Bool
            XCTAssertEqual(disabled, true)
            let refreshEnabled = try await page.evaluateJavaScript("!document.getElementById('refresh').disabled") as? Bool
            XCTAssertEqual(refreshEnabled, true)
            let actual = try await page.evaluateJavaScript("document.getElementById('profiles').textContent") as? String
            XCTAssertTrue(actual?.contains("Idle sleep after 5 minutes") == true)
            XCTAssertTrue(actual?.contains("Never idle sleeps") == true)
            let instructions = try await page.evaluateJavaScript("document.getElementById('setup-instructions').textContent") as? String
            XCTAssertTrue(instructions?.contains("scripts/package-installer.sh") == true)
            XCTAssertTrue(instructions?.contains("versioned package") == true)
            XCTAssertTrue(instructions?.contains("scripts/install.sh --gui") == true)
            XCTAssertTrue(instructions?.contains("never opens Installer") == true)
            XCTAssertTrue(instructions?.contains("scripts/uninstall.sh --keep-settings --gui") == true)
            let instructionsOpen = try await page.evaluateJavaScript("document.getElementById('setup-instructions').open") as? Bool
            XCTAssertEqual(instructionsOpen, false)
            let errorHidden = try await page.evaluateJavaScript("document.getElementById('error').hidden") as? Bool
            XCTAssertEqual(errorHidden, false)

            _ = try await page.evaluateJavaScript("""
                for (const id of ['keep-awake', 'set-timeout']) {
                  document.getElementById(id).dispatchEvent(new Event('click'));
                }
                """)
            let idle = try await page.evaluateJavaScript("!document.getElementById('activity').textContent.includes('Applying') && !document.getElementById('refresh').disabled") as? Bool
            XCTAssertEqual(idle, true)
            XCTAssertEqual(runner.applyAttempts, 0)
        }
        let fragmentRemoved = try await page.evaluateJavaScript("location.hash === ''") as? Bool
        XCTAssertEqual(fragmentRemoved, true)
        page.frame.size.width = 390
        let overflow = try await page.evaluateJavaScript("document.documentElement.scrollWidth > innerWidth") as? Bool
        XCTAssertEqual(overflow, false)

        runner.setAvailability(.ready)
        _ = try await page.evaluateJavaScript("document.getElementById('refresh').click()")
        try await waitFor(page, expression: "document.getElementById('controls').disabled === false")
        _ = try await page.evaluateJavaScript("document.getElementById('keep-awake').click()")
        try await waitFor(page, expression: "document.getElementById('activity').textContent.includes('Keep-awake settings applied')")
        XCTAssertEqual(runner.power.settings.values, [.battery: 0, .adapter: 0])
        XCTAssertEqual(runner.applyAttempts, 1)

        runner.setAvailability(HelperAvailability(state: .unavailable, message: "Fake helper stopped."))
        _ = try await page.evaluateJavaScript("document.getElementById('refresh').click()")
        try await waitFor(page, expression: "document.getElementById('helper-message').textContent.includes('Fake helper stopped.')")
        let disabledAfterStop = try await page.evaluateJavaScript("document.getElementById('controls').disabled") as? Bool
        XCTAssertEqual(disabledAfterStop, true)
        let restoreRecord = try await page.evaluateJavaScript("document.getElementById('profiles').textContent") as? String
        XCTAssertTrue(restoreRecord?.contains("Saved previous setting: Idle sleep after 5 minutes.") == true)
        _ = try await page.evaluateJavaScript("document.getElementById('keep-awake').dispatchEvent(new Event('click'))")
        XCTAssertEqual(runner.applyAttempts, 1)
        XCTAssertEqual(runner.power.settings.values, [.battery: 0, .adapter: 0])
    }

    func testFailedChangeStaysVisibleAfterSuccessfulRefresh() async throws {
        let runner = PageHelperRunner()
        runner.setAvailability(.ready)
        runner.failRequests(true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-error-page-\(UUID())")
        let server = HearthWebServer(service: HearthService(runner: runner, stateDirectory: directory))
        defer { try? server.stop(); try? FileManager.default.removeItem(at: directory) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 700), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: try server.start()))
        try await waitFor(page, expression: "!document.getElementById('keep-awake').disabled")
        _ = try await page.evaluateJavaScript("document.getElementById('keep-awake').click()")
        try await waitFor(page, expression: "document.getElementById('error').textContent.includes('not fully completed')")
        _ = try await page.evaluateJavaScript("document.getElementById('refresh').click()")
        try await waitFor(page, expression: "document.getElementById('updated').textContent.includes('Updated')")
        let error = try await page.evaluateJavaScript("document.getElementById('error').textContent") as? String
        XCTAssertTrue(error?.contains("not fully completed") == true)
        XCTAssertEqual(runner.power.settings.values, [.battery: 5, .adapter: 0])
        try await preview(page, name: "action-error")
    }

    func testAlreadyNeverUnmanagedStateDoesNotOfferAFakeOffSwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.runner.apply([PowerChange(profile: .battery, minutes: 0)])
        let before = fixture.runner.applyCount
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 650), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: fixture.url))
        try await waitFor(page, expression: "document.getElementById('state').textContent === 'Already set to stay awake'")
        let disabled = try await page.evaluateJavaScript("document.getElementById('keep-awake').disabled") as? Bool
        let note = try await page.evaluateJavaScript("document.getElementById('action-note').textContent") as? String
        XCTAssertEqual(disabled, true)
        XCTAssertTrue(note?.contains("No saved setting to restore") == true)
        XCTAssertEqual(fixture.runner.applyCount, before)
        try await preview(page, name: "already-awake")
    }

    func testUnavailableProfileDoesNotTrapTargetSelection() async throws {
        let runner = PageHelperRunner()
        runner.setAvailability(.ready)
        runner.omitBattery()
        _ = try runner.power.apply([PowerChange(profile: .adapter, minutes: 10)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-target-page-\(UUID())")
        let server = HearthWebServer(service: HearthService(runner: runner, stateDirectory: directory))
        defer { try? server.stop(); try? FileManager.default.removeItem(at: directory) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 650), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: try server.start()))
        try await waitFor(page, expression: "document.getElementById('actual').textContent.includes('Battery: unknown')")
        let selectable = try await page.evaluateJavaScript("!document.getElementById('target').disabled") as? Bool
        let disabled = try await page.evaluateJavaScript("document.getElementById('keep-awake').disabled") as? Bool
        XCTAssertEqual(selectable, true)
        XCTAssertEqual(disabled, true)
        _ = try await page.evaluateJavaScript("document.getElementById('target').value='adapter'; document.getElementById('target').dispatchEvent(new Event('change'))")
        let enabled = try await page.evaluateJavaScript("!document.getElementById('keep-awake').disabled") as? Bool
        XCTAssertEqual(enabled, true)
        XCTAssertEqual(runner.applyAttempts, 0)
    }

    func testUntrustedCurrentJournalDisablesWritesButRetainsRefresh() async throws {
        let runner = PageHelperRunner()
        runner.setAvailability(.ready)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-untrusted-page-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let state = directory.appendingPathComponent("state.json")
        try Data("damaged journal".utf8).write(to: state)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
        let server = HearthWebServer(service: HearthService(runner: runner, stateDirectory: directory))
        defer { try? server.stop(); try? FileManager.default.removeItem(at: directory) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 650), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: try server.start()))
        try await waitFor(page, expression: "document.getElementById('state').textContent === 'Settings need attention'")
        let disabled = try await page.evaluateJavaScript("document.getElementById('keep-awake').disabled && document.getElementById('controls').disabled") as? Bool
        let refresh = try await page.evaluateJavaScript("!document.getElementById('refresh').disabled") as? Bool
        XCTAssertEqual(disabled, true)
        XCTAssertEqual(refresh, true)
        _ = try await page.evaluateJavaScript("document.getElementById('keep-awake').dispatchEvent(new Event('click'))")
        XCTAssertEqual(runner.applyAttempts, 0)
        XCTAssertEqual(try Data(contentsOf: state), Data("damaged journal".utf8))
    }

    private func preview(_ page: WKWebView, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["HEARTH_WEB_PREVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = page.frame
        page.frame.size = NSSize(width: 600, height: 650)
        defer { page.frame = original }
        page.layoutSubtreeIfNeeded()
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            page.takeSnapshot(with: nil) { image, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: PageTestError.timedOut) }
            }
        }
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private func waitFor(_ page: WKWebView, expression: String) async throws {
        for _ in 0..<100 {
            if let ready = try? await page.evaluateJavaScript(expression) as? Bool, ready {
                return
            }

            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Embedded page did not reach its expected state.")
        throw PageTestError.timedOut
    }

    private enum PageTestError: Error {
        case timedOut
    }
}
