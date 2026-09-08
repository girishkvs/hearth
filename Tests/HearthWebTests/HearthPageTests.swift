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
    private var displayBatteryAvailable = true

    var applyAttempts: Int { lock.withLock { attempts } }

    func helperAvailability() -> HelperAvailability {
        lock.withLock { helper }
    }

    func setAvailability(_ availability: HelperAvailability) {
        lock.withLock { helper = availability }
    }

    func failRequests(_ reject: Bool) { lock.withLock { rejectRequests = reject } }
    func omitBattery(for setting: PowerSetting = .system) {
        lock.withLock {
            if setting == .display { displayBatteryAvailable = false }
            else { batteryAvailable = false }
        }
    }

    func readSettings() throws -> PowerSettings {
        let settings = try power.readSettings()
        return lock.withLock {
            PowerSettings(
                values: batteryAvailable ? settings.values : settings.values.filter { $0.key != .battery },
                currentSource: settings.currentSource,
                displayValues: displayBatteryAvailable ? settings.displayValues : settings.displayValues.filter { $0.key != .battery }
            )
        }
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
    func testLockIsGlobalAndRequiresBorrowedSystemUntilRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.runner.apply([PowerChange(profile: .battery, minutes: 1)])
        _ = try fixture.service.perform(PowerRequest(action: .on, target: .battery))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 900), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: fixture.url))
        try await waitFor(page, expression: "document.getElementById('prevent-lock')?.disabled === false")
        let scope = try await page.evaluateJavaScript("document.querySelector('[aria-labelledby=\"lock-state\"]').textContent") as? String
        XCTAssertTrue(scope?.contains("Current user · all sources · keeps System/Display awake") == true)
        XCTAssertEqual(fixture.saver.writeCount, 0)
        _ = try await page.evaluateJavaScript("""
            document.getElementById('target').value = 'battery';
            document.getElementById('target').dispatchEvent(new Event('change'));
            document.getElementById('prevent-lock').click();
            """)
        try await waitFor(page, expression: "document.getElementById('lock-actual').textContent === 'Configured' && !document.getElementById('prevent-lock').disabled")
        let disclosure = try await page.evaluateJavaScript("document.body.textContent") as? String
        XCTAssertTrue(disclosure?.contains("macOS may adopt or restore the timer later") == true)
        XCTAssertTrue(disclosure?.contains("do not prove immediate macOS timer adoption") == true)
        let activeStatus = try fixture.service.status()
        XCTAssertEqual(activeStatus.idleLock?.dependencies.count, 4)
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 0, .adapter: 0])
        let required = try await page.evaluateJavaScript("""
            document.getElementById('keep-awake').disabled &&
            document.getElementById('keep-awake').textContent === 'Required by Lock' &&
            document.getElementById('keep-display-on').disabled &&
            document.getElementById('controls').disabled &&
            document.getElementById('prevent-lock').textContent === 'Restore Lock'
            """) as? Bool
        XCTAssertEqual(required, true)
        let borrowed = try await page.evaluateJavaScript("document.getElementById('profiles').textContent") as? String
        XCTAssertTrue(borrowed?.contains("borrowed; pre-existing override") == true)
        XCTAssertTrue(borrowed?.contains("Idle sleep after 1 minute") == true)
        let applies = fixture.runner.applyCount
        _ = try await page.evaluateJavaScript("""
            document.getElementById('minutes').value = '9';
            for (const id of ['keep-awake', 'keep-display-on', 'set-timeout']) {
              document.getElementById(id).dispatchEvent(new Event('click'));
            }
            """)
        XCTAssertEqual(fixture.runner.applyCount, applies)
        try await preview(page, name: "lock-active")
        page.frame.size.width = 390
        let overflow = try await page.evaluateJavaScript("document.documentElement.scrollWidth > innerWidth") as? Bool
        XCTAssertEqual(overflow, false)
        _ = try await page.evaluateJavaScript("document.getElementById('prevent-lock').click()")
        try await waitFor(page, expression: "document.getElementById('lock-actual').textContent === 'Not enabled' && !document.getElementById('keep-awake').disabled")
        let action = try await page.evaluateJavaScript("document.getElementById('keep-awake').textContent") as? String
        XCTAssertEqual(action, "Restore prior system")
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 0, .adapter: 0])
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 10])
        let restoredStatus = try fixture.service.status()
        XCTAssertEqual(restoredStatus.profiles.first { $0.profile == .battery }?.originalMinutes, 1)
    }

    func testLockUnavailableAndUncertainResultsNeverClaimConfigured() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.saver.configure(availability: .unavailable)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 900), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: fixture.url))
        try await waitFor(page, expression: "document.getElementById('lock-actual')?.textContent === 'Unavailable'")
        let instructions = try await page.evaluateJavaScript("document.getElementById('setup-instructions').textContent") as? String
        XCTAssertFalse(instructions?.contains("Enable Lock controls") == true)
        XCTAssertTrue(instructions?.contains("no Automation setup is needed") == true)
        for availability in [ScreenSaverAvailability.setupRequired, .managed, .unavailable] {
            fixture.saver.configure(availability: availability)
            _ = try await page.evaluateJavaScript("document.getElementById('refresh').click()")
            try await waitFor(page, expression: "document.getElementById('lock-details').textContent.includes('Fake Lock \(availability.rawValue)')")
            _ = try await page.evaluateJavaScript("document.getElementById('prevent-lock').dispatchEvent(new Event('click'))")
            XCTAssertEqual(fixture.saver.writeCount, 0)
            XCTAssertEqual(fixture.runner.applyCount, 0)
            let disabled = try await page.evaluateJavaScript("document.getElementById('prevent-lock').disabled && !document.getElementById('keep-awake').disabled") as? Bool
            XCTAssertEqual(disabled, true)
        }
        fixture.saver.configure()
        _ = try await page.evaluateJavaScript("document.getElementById('refresh').click()")
        try await waitFor(page, expression: "!document.getElementById('prevent-lock').disabled")
        _ = try await page.evaluateJavaScript("document.getElementById('prevent-lock').click()")
        try await waitFor(page, expression: "document.getElementById('lock-actual').textContent === 'Configured' && !document.getElementById('prevent-lock').disabled")
        fixture.saver.configure(failure: .rejected("Fake preference rejection during restore."))
        _ = try await page.evaluateJavaScript("document.getElementById('prevent-lock').click()")
        try await waitFor(page, expression: "document.getElementById('lock-actual').textContent === 'Restore needed' && !document.getElementById('refresh').disabled")
        let failed = try await page.evaluateJavaScript("document.getElementById('error').textContent") as? String
        XCTAssertTrue(failed?.contains("Lock: not fully completed") == true)
        let details = try await page.evaluateJavaScript("document.getElementById('error-detail').textContent") as? String
        XCTAssertTrue(details?.contains("Fake preference rejection") == true)
        fixture.saver.configure()
        _ = try await page.evaluateJavaScript("document.getElementById('prevent-lock').click()")
        try await waitFor(page, expression: "document.getElementById('lock-actual').textContent === 'Not enabled' && !document.getElementById('prevent-lock').disabled")
        fixture.saver.configure(failure: .completionUnknown("Fake unknown completion."))
        _ = try await page.evaluateJavaScript("document.getElementById('prevent-lock').click()")
        try await waitFor(page, expression: "document.getElementById('lock-actual').textContent.includes('unconfirmed') && !document.getElementById('refresh').disabled")
        let uncertain = try await page.evaluateJavaScript("document.getElementById('prevent-lock').disabled && document.getElementById('keep-awake').disabled && document.getElementById('lock-actual').textContent === 'Configuration unconfirmed'") as? Bool
        XCTAssertEqual(uncertain, true)
        let recovery = try await page.evaluateJavaScript("document.getElementById('lock-recovery').textContent") as? String
        XCTAssertTrue(recovery?.contains("does not mean cancelled or unchanged") == true)
        XCTAssertTrue(recovery?.contains("Restore Lock and required System/Display changes are blocked") == true)
        XCTAssertTrue(recovery?.contains("hearth status --json") == true)
        XCTAssertTrue(recovery?.contains("Do not clear state") == true)
        let originals = try await page.evaluateJavaScript("document.getElementById('lock-saver-values').textContent") as? String
        XCTAssertTrue(originals?.contains("Saved effective screen-saver idle delay: 300 seconds") == true)
        let dependencyHints = try await page.evaluateJavaScript("document.getElementById('profiles').textContent") as? String
        XCTAssertFalse(dependencyHints?.contains("Use Restore Lock") == true)
        XCTAssertTrue(dependencyHints?.contains("Changes blocked; recovery review required") == true)
        let noRecoveryActions = try await page.evaluateJavaScript("document.querySelectorAll('#lock-recovery button').length === 0") as? Bool
        XCTAssertEqual(noRecoveryActions, true)
        try await preview(page, name: "lock-unconfirmed")
        _ = try await page.evaluateJavaScript("document.getElementById('advanced').open = true")
        try await preview(page, name: "lock-recovery")
    }

    func testPreferenceFailureKeepsPowerControlsWithoutAutomationSetup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.saver.configure(readFailure: "Synthetic preference synchronization failure.")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 900), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: fixture.url))
        try await waitFor(page, expression: "document.getElementById('lock-actual')?.textContent === 'Unavailable'")
        let controls = try await page.evaluateJavaScript("""
            document.getElementById('prevent-lock').disabled &&
            !document.getElementById('keep-awake').disabled &&
            !document.getElementById('keep-display-on').disabled
            """) as? Bool
        XCTAssertEqual(controls, true)
        let detail = try await page.evaluateJavaScript("document.getElementById('lock-details').textContent") as? String
        XCTAssertTrue(detail?.contains("Synthetic preference synchronization failure") == true)
        XCTAssertFalse(detail?.contains("Enable Lock controls") == true)
        let note = try await page.evaluateJavaScript("document.getElementById('lock-note').textContent") as? String
        XCTAssertFalse(note?.contains("Enable Lock controls") == true)
        _ = try await page.evaluateJavaScript("document.getElementById('prevent-lock').dispatchEvent(new Event('click'))")
        XCTAssertEqual(fixture.saver.writeCount, 0)
        XCTAssertEqual(fixture.runner.applyCount, 0)
        try await preview(page, name: "lock-unavailable")
    }

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
        let initialDisplayAction = try await page.evaluateJavaScript("document.getElementById('keep-display-on').textContent") as? String
        XCTAssertEqual(initialDisplayAction, "Keep display on")
        let timeoutSetting = try await page.evaluateJavaScript("document.getElementById('timeout-setting').value") as? String
        XCTAssertEqual(timeoutSetting, "system")
        let initial = try await page.evaluateJavaScript("document.getElementById('profiles').textContent") as? String
        XCTAssertTrue(initial?.contains("Idle sleep after 5 minutes") == true)
        XCTAssertTrue(initial?.contains("Never idle sleeps") == true)
        XCTAssertTrue(initial?.contains("Display off after 2 minutes") == true)
        XCTAssertTrue(initial?.contains("Display off after 10 minutes") == true)
        XCTAssertEqual(fixture.runner.applyCount, 0)
        let helper = try await page.evaluateJavaScript("document.getElementById('helper-heading').textContent") as? String
        XCTAssertEqual(helper, "Helper ready")

        try await preview(page, name: "ready")
        _ = try await page.evaluateJavaScript("document.getElementById('keep-awake').click()")
        try await waitFor(page, expression: "document.getElementById('activity').textContent.includes('System: keep-awake settings applied')")
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 0, .adapter: 0])
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 10])
        let restoreAction = try await page.evaluateJavaScript("document.getElementById('keep-awake').textContent") as? String
        let activeState = try await page.evaluateJavaScript("document.getElementById('actual').textContent") as? String
        XCTAssertEqual(restoreAction, "Restore prior system")
        XCTAssertEqual(activeState, "Battery: no timeout · Adapter: no timeout")
        let unchangedDisplay = try await page.evaluateJavaScript("document.getElementById('keep-display-on').textContent") as? String
        XCTAssertEqual(unchangedDisplay, "Keep display on")

        _ = try await page.evaluateJavaScript("document.getElementById('keep-display-on').click()")
        try await waitFor(page, expression: "document.getElementById('activity').textContent.includes('Display: keep-display-on settings applied')")
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 0, .adapter: 0])
        let displayRestore = try await page.evaluateJavaScript("document.getElementById('keep-display-on').textContent") as? String
        XCTAssertEqual(displayRestore, "Restore prior display")
        try await preview(page, name: "keeping-awake")

        _ = try await page.evaluateJavaScript("document.getElementById('keep-awake').click()")
        try await waitFor(page, expression: "document.getElementById('activity').textContent.includes('System: prior settings restored')")
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 0, .adapter: 0])
        _ = try await page.evaluateJavaScript("document.getElementById('keep-display-on').click()")
        try await waitFor(page, expression: "document.getElementById('activity').textContent.includes('Display: prior settings restored')")
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 10])

        _ = try await page.evaluateJavaScript("document.getElementById('advanced').open = true")
        _ = try await page.evaluateJavaScript("document.getElementById('timeout-setting').value = 'display'; document.getElementById('timeout-setting').dispatchEvent(new Event('change'))")
        try await preview(page, name: "advanced")
        _ = try await page.evaluateJavaScript("document.getElementById('minutes').value = '0'; document.getElementById('set-timeout').click()")
        let validation = try await page.evaluateJavaScript("document.getElementById('error').textContent") as? String
        XCTAssertTrue(validation?.contains("whole number") == true)
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 10])
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
            let disabled = try await page.evaluateJavaScript("document.getElementById('controls').disabled && document.getElementById('keep-awake').disabled && document.getElementById('keep-display-on').disabled") as? Bool
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
                for (const id of ['keep-awake', 'keep-display-on', 'set-timeout']) {
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
        try await waitFor(page, expression: "document.getElementById('activity').textContent.includes('System: keep-awake settings applied')")
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

    func testSelectedTargetAndTimeoutSettingDoNotMixOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: fixture.url))
        try await waitFor(page, expression: "!document.getElementById('keep-display-on').disabled")

        _ = try await page.evaluateJavaScript("""
            document.getElementById('advanced').open = true;
            document.getElementById('target').value = 'battery';
            document.getElementById('target').dispatchEvent(new Event('change'));
            document.getElementById('keep-display-on').click();
            """)
        try await waitFor(page, expression: "document.getElementById('keep-display-on').textContent === 'Restore prior display'")
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 0, .adapter: 10])
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])

        _ = try await page.evaluateJavaScript("document.getElementById('target').value = 'adapter'; document.getElementById('target').dispatchEvent(new Event('change'))")
        let adapterAction = try await page.evaluateJavaScript("document.getElementById('keep-display-on').textContent") as? String
        XCTAssertEqual(adapterAction, "Keep display on")
        _ = try await page.evaluateJavaScript("document.getElementById('keep-display-on').click()")
        try await waitFor(page, expression: "document.getElementById('keep-display-on').textContent === 'Restore prior display'")
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 0, .adapter: 0])

        _ = try await page.evaluateJavaScript("""
            document.getElementById('target').value = 'battery';
            document.getElementById('target').dispatchEvent(new Event('change'));
            document.getElementById('keep-display-on').click();
            """)
        try await waitFor(page, expression: "document.getElementById('keep-display-on').textContent === 'Keep display on'")
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 0])

        _ = try await page.evaluateJavaScript("""
            document.getElementById('target').value = 'adapter';
            document.getElementById('target').dispatchEvent(new Event('change'));
            document.getElementById('timeout-setting').value = 'display';
            document.getElementById('timeout-setting').dispatchEvent(new Event('change'));
            document.getElementById('minutes').value = '7';
            document.getElementById('set-timeout').click();
            """)
        try await waitFor(page, expression: "document.getElementById('activity').textContent === 'Display: timeout saved.'")
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 7])
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 5, .adapter: 0])
        XCTAssertFalse(try fixture.service.status().hasManagedChanges)

        _ = try await page.evaluateJavaScript("""
            document.getElementById('target').value = 'battery';
            document.getElementById('target').dispatchEvent(new Event('change'));
            document.getElementById('timeout-setting').value = 'system';
            document.getElementById('timeout-setting').dispatchEvent(new Event('change'));
            document.getElementById('minutes').value = '11';
            document.getElementById('set-timeout').click();
            """)
        try await waitFor(page, expression: "document.getElementById('activity').textContent === 'System: timeout saved.'")
        XCTAssertEqual(fixture.runner.settings.values, [.battery: 11, .adapter: 0])
        XCTAssertEqual(fixture.runner.settings.displayValues, [.battery: 2, .adapter: 7])
    }

    func testUnavailableSettingDoesNotDisableTheOtherRowOrTrapTimeoutSelector() async throws {
        for missingSetting in PowerSetting.allCases {
            let runner = PageHelperRunner()
            runner.setAvailability(.ready)
            runner.omitBattery(for: missingSetting)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-independent-page-\(UUID())")
            let server = HearthWebServer(service: HearthService(runner: runner, stateDirectory: directory))
            defer { try? server.stop(); try? FileManager.default.removeItem(at: directory) }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
            defer { page.stopLoading() }
            page.load(URLRequest(url: try server.start()))
            let missingActual = missingSetting == .system ? "actual" : "display-actual"
            let missingButton = missingSetting == .system ? "keep-awake" : "keep-display-on"
            let availableButton = missingSetting == .system ? "keep-display-on" : "keep-awake"
            let availableSetting = missingSetting == .system ? "display" : "system"
            try await waitFor(page, expression: "document.getElementById('\(missingActual)').textContent.includes('Battery: unknown')")
            let independentlyGated = try await page.evaluateJavaScript("document.getElementById('\(missingButton)').disabled && !document.getElementById('\(availableButton)').disabled") as? Bool
            XCTAssertEqual(independentlyGated, true)

            _ = try await page.evaluateJavaScript("""
                document.getElementById('timeout-setting').value = '\(missingSetting.rawValue)';
                document.getElementById('timeout-setting').dispatchEvent(new Event('change'));
                """)
            let selectable = try await page.evaluateJavaScript("document.getElementById('controls').disabled && !document.getElementById('timeout-setting').disabled && !document.getElementById('target').disabled") as? Bool
            XCTAssertEqual(selectable, true)
            _ = try await page.evaluateJavaScript("document.getElementById('\(missingButton)').dispatchEvent(new Event('click'))")
            XCTAssertEqual(runner.applyAttempts, 0)

            _ = try await page.evaluateJavaScript("""
                document.getElementById('timeout-setting').value = '\(availableSetting)';
                document.getElementById('timeout-setting').dispatchEvent(new Event('change'));
                """)
            let timeoutEnabled = try await page.evaluateJavaScript("!document.getElementById('controls').disabled") as? Bool
            XCTAssertEqual(timeoutEnabled, true)
            _ = try await page.evaluateJavaScript("document.getElementById('\(availableButton)').click()")
            try await waitFor(page, expression: "document.getElementById('\(availableButton)').textContent === 'Restore prior \(availableSetting)'")
            XCTAssertEqual(runner.applyAttempts, 1)
        }
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
        let readsBeforeRefresh = runner.power.readCount
        _ = try await page.evaluateJavaScript("document.getElementById('refresh').click()")
        try await waitFor(page, expression: "!document.getElementById('refresh').disabled && !document.getElementById('keep-display-on').disabled")
        XCTAssertGreaterThan(runner.power.readCount, readsBeforeRefresh)
        let error = try await page.evaluateJavaScript("document.getElementById('error').textContent") as? String
        XCTAssertTrue(error?.contains("not fully completed") == true)
        XCTAssertEqual(runner.power.settings.values, [.battery: 5, .adapter: 0])
        try await preview(page, name: "action-error")
        runner.failRequests(false)
        _ = try await page.evaluateJavaScript("document.getElementById('keep-display-on').click()")
        try await waitFor(page, expression: "document.getElementById('activity').textContent.includes('Display: keep-display-on settings applied')")
        let retainedError = try await page.evaluateJavaScript("document.getElementById('error').textContent") as? String
        XCTAssertTrue(retainedError?.contains("System: Battery change was not fully completed") == true)
        XCTAssertEqual(runner.power.settings.displayValues, [.battery: 0, .adapter: 0])
        XCTAssertEqual(runner.power.settings.values, [.battery: 5, .adapter: 0])
    }

    func testAlreadyNeverUnmanagedStateDoesNotOfferAFakeOffSwitch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.runner.apply([
            PowerChange(profile: .battery, minutes: 0),
            PowerChange(profile: .battery, minutes: 0, setting: .display),
            PowerChange(profile: .adapter, minutes: 0, setting: .display),
        ])
        let before = fixture.runner.applyCount
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 650), configuration: configuration)
        defer { page.stopLoading() }
        page.load(URLRequest(url: fixture.url))
        try await waitFor(page, expression: "document.getElementById('actual').textContent.includes('Battery: no timeout')")
        let disabled = try await page.evaluateJavaScript("document.getElementById('keep-awake').disabled && document.getElementById('keep-display-on').disabled") as? Bool
        let note = try await page.evaluateJavaScript("document.getElementById('system-note').textContent + document.getElementById('display-note').textContent") as? String
        XCTAssertEqual(disabled, true)
        XCTAssertTrue(note?.contains("No prior setting saved") == true)
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
        try await waitFor(page, expression: "document.getElementById('error').textContent.includes('Settings need attention')")
        let disabled = try await page.evaluateJavaScript("document.getElementById('keep-awake').disabled && document.getElementById('keep-display-on').disabled && document.getElementById('controls').disabled") as? Bool
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
        let contentHeight = try await page.evaluateJavaScript("""
            Math.ceil(document.querySelector('main').getBoundingClientRect().bottom +
              parseFloat(getComputedStyle(document.body).paddingBottom))
            """)
        let height = try XCTUnwrap(contentHeight as? Double)
        XCTAssertTrue(height.isFinite && (100...4000).contains(height))
        page.frame.size.height = height
        page.layoutSubtreeIfNeeded()
        let footerVisible = try await page.evaluateJavaScript(
            "document.querySelector('footer').getBoundingClientRect().bottom <= innerHeight") as? Bool
        XCTAssertEqual(footerVisible, true)
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

    private func waitFor(_ page: WKWebView, expression: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if let ready = try? await page.evaluateJavaScript(expression) as? Bool, ready {
                return
            }

            try await Task.sleep(for: .milliseconds(100))
        }
        let feedback = try? await page.evaluateJavaScript("""
            JSON.stringify({
              activity: document.getElementById('activity')?.textContent,
              error: document.getElementById('error')?.textContent,
              details: document.getElementById('error-detail')?.textContent,
              refreshing: document.getElementById('refresh')?.disabled,
              systemDisabled: document.getElementById('keep-awake')?.disabled,
              displayDisabled: document.getElementById('keep-display-on')?.disabled
            })
            """)
        _ = try XCTUnwrap(
            nil as Bool?,
            "Embedded page timed out waiting for \(expression). Feedback: \(feedback ?? "unavailable")",
            file: file,
            line: line
        )
    }

    private enum PageTestError: Error {
        case timedOut
    }
}
