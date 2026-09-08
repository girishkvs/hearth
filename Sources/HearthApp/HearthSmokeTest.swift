import AppKit
import Foundation
import HearthCore

private struct SmokeFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Shared by smoke tests and documentation capture; never runs a process or changes system settings.
final class SmokePowerRunner: PowerCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PowerProfile: Int] = [.battery: 5, .adapter: 0]
    private var batches: [[PowerChange]] = []
    private var denied = false
    private var failedProfile: PowerProfile?
    private var readFailure = false
    private var activeCalls = 0
    private var maximumCalls = 0
    private var hideBatteryAfterApply = false
    private var helper = HelperAvailability.ready

    var writeCount: Int { lock.withLock { batches.count } }
    var maximumConcurrency: Int { lock.withLock { maximumCalls } }

    func helperAvailability() -> HelperAvailability {
        lock.withLock { helper }
    }

    func setHelperAvailability(_ availability: HelperAvailability) {
        lock.withLock { helper = availability }
    }

    func readSettings() throws -> PowerSettings {
        enterCall()
        defer { leaveCall() }
        Thread.sleep(forTimeInterval: 0.04)
        return try lock.withLock {
            if readFailure {
                throw HearthError.command("Fake status read failure.")
            }
            return PowerSettings(values: values, currentSource: "Fake power adapter")
        }
    }

    func apply(_ changes: [PowerChange]) throws -> [CommandOutcome] {
        enterCall()
        defer { leaveCall() }
        Thread.sleep(forTimeInterval: 0.06)
        return try lock.withLock {
            batches.append(changes)
            guard helper.isReady else {
                throw HearthError.command("Fake helper is unavailable.")
            }
            if denied {
                throw HearthError.command("Fake helper request rejected.")
            }
            let results = changes.map { change in
                if change.profile == failedProfile {
                    return CommandOutcome(profile: change.profile, exitCode: 1, message: "Fake write failure.")
                }
                values[change.profile] = change.minutes
                return CommandOutcome(profile: change.profile, exitCode: 0)
            }
            if hideBatteryAfterApply {
                values.removeValue(forKey: .battery)
            }
            return results
        }
    }

    func configure(denied: Bool = false, failedProfile: PowerProfile? = nil, readFailure: Bool = false) {
        lock.withLock {
            self.denied = denied
            self.failedProfile = failedProfile
            self.readFailure = readFailure
        }
    }

    func changeExternally(_ profile: PowerProfile, minutes: Int) {
        lock.withLock { values[profile] = minutes }
    }

    func simulateMissingBatteryAfterWrite(_ enabled: Bool) {
        lock.withLock { hideBatteryAfterApply = enabled }
    }

    private func enterCall() {
        lock.withLock {
            activeCalls += 1
            maximumCalls = max(maximumCalls, activeCalls)
        }
    }

    private func leaveCall() {
        lock.withLock { activeCalls -= 1 }
    }
}

@MainActor
final class HearthSmokeTest {
    private var terminationCount = 0

    func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearthApp-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let runner = SmokePowerRunner()
        let service = HearthService(runner: runner, stateDirectory: directory)
        let controller = HearthAppController(service: service, smokeTest: true) { [weak self] in
            self?.terminationCount += 1
        }
        do {
            try await exercise(controller, runner: runner)
            try await exerciseHelperAvailability(in: directory.appendingPathComponent("helper", isDirectory: true))
            try await exerciseCorruptState(in: directory.appendingPathComponent("damaged", isDirectory: true))
            controller.stop()
            controller.panel.window.close()
            controller.setupPanel.window.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            controller.stop()
            controller.panel.window.close()
            controller.setupPanel.window.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func exercise(_ app: HearthAppController, runner: SmokePowerRunner) async throws {
        app.start()
        try await settle(app)
        try expect(app.target == .both, "Both must be the default power target.")
        try expect(app.preventItem.title == "Keep awake", "The native menu must have one clear primary action.")
        try expect(app.menu.items.contains { $0.submenu === app.advancedMenu }, "Secondary controls must be under Advanced.")
        try expect(!app.menu.items.contains(app.timeoutItem) && !app.menu.items.contains(app.setupItem), "Advanced controls must not fill the main menu.")
        try expect(app.panel.target.indexOfSelectedItem == 0, "Native popup must show Both.")
        try expect(runner.writeCount == 0, "Opening the app must not write power settings.")
        try expect(app.panel.window.contentView != nil, "The actual native window must be constructed.")
        app.panel.window.contentView?.layoutSubtreeIfNeeded()
        try expect(app.panel.displayNote.stringValue == "Display may still turn off.", "The display warning is required.")
        try profile(app, .battery, actual: 5, original: nil)
        try profile(app, .adapter, actual: 0, original: nil)
        print("smoke: native menu/window constructed; startup is read-only; default Both")

        try select(.battery, in: app)
        app.panel.target.selectItem(at: 2)
        app.panel.target.sendAction(app.panel.target.action, to: app.panel.target.target)
        try expect(app.target == .adapter, "Native target popup action must select adapter.")
        try select(.both, in: app)
        try activate(app.preventItem)
        try expect(app.isBusy, "The menu action must start asynchronous work.")
        try expect(app.message == "Preventing idle sleep on battery and power adapter…", "Progress must name both selected profiles.")
        try expect(!app.preventItem.isEnabled && !app.restoreItem.isEnabled, "Menu writes must be disabled during work.")
        try expect(!app.panel.prevent.isEnabled && !app.panel.minutes.isEnabled, "Panel writes must be disabled during work.")
        app.menuWillOpen(app.menu)
        app.pollStatus()
        // Reaching this main-actor continuation while the fake runner is sleeping proves responsiveness.
        try await Task.sleep(for: .milliseconds(10))
        try expect(app.isBusy, "The main actor must remain responsive during a blocking runner call.")
        try await settle(app)
        try expect(runner.maximumConcurrency == 1, "Refresh and writes must not overlap.")
        try expect(runner.writeCount == 1, "Repeated refresh triggers must not duplicate writes.")
        try profile(app, .battery, actual: 0, original: 5)
        try profile(app, .adapter, actual: 0, original: nil)
        try expect(app.preventItem.title == "Restore previous settings", "Active native primary action must preserve honest restore semantics.")
        try expect(app.lastActionSucceeded == true, "Fake activation should succeed.")
        try expect(app.panel.details.string.contains("unchanged"), "Already-never adapter outcome must be visible.")

        try activate(app.restoreItem)
        try await settle(app)
        try profile(app, .battery, actual: 5, original: nil)
        try profile(app, .adapter, actual: 0, original: nil)
        print("smoke: prevent/restore preserve the original baseline and unmanaged never-sleep")

        try select(.adapter, in: app)
        try activate(app.timeoutItem)
        let writesBeforeInvalidInput = runner.writeCount
        for input in ["0", "-1", "1.5", "abc", "2147483648"] {
            enter(input, in: app)
            app.panel.setTimeout.performClick(nil)
            try expect(app.lastActionSucceeded == false, "Invalid minutes must fail: \(input)")
            try expect(!app.isBusy, "Invalid minutes must not reach the worker.")
        }
        enter("", in: app)
        try expect(!app.panel.setTimeout.isEnabled, "An explicit timeout is required; no default is guessed.")
        try expect(runner.writeCount == writesBeforeInvalidInput, "Invalid input must never write.")
        enter("10", in: app)
        app.panel.setTimeout.performClick(nil)
        try expect(app.message == "Setting idle sleep to 10 minutes on power adapter…", "Timeout progress must name the real target.")
        try await settle(app)
        try profile(app, .adapter, actual: 10, original: nil)
        try profile(app, .battery, actual: 5, original: nil)
        app.panel.prevent.performClick(nil)
        try await settle(app)
        try profile(app, .adapter, actual: 0, original: 10)
        enter("20", in: app)
        app.panel.setTimeout.performClick(nil)
        try await settle(app)
        try profile(app, .adapter, actual: 20, original: nil)
        print("smoke: target selection and explicit timeout controls validate input and clear ownership")

        try select(.both, in: app)
        runner.configure(denied: true)
        try activate(app.preventItem)
        try await settle(app)
        try expect(app.lastActionSucceeded == false, "A rejected helper request must not claim success.")
        try expect(app.panel.details.string.contains("Fake helper request rejected"), "Helper request failure must be shown.")
        try profile(app, .battery, actual: 5, original: nil)
        try profile(app, .adapter, actual: 20, original: nil)

        runner.configure(failedProfile: .adapter)
        try activate(app.preventItem)
        try await settle(app)
        try expect(app.lastActionSucceeded == false, "Partial completion must not claim full success.")
        try profile(app, .battery, actual: 0, original: 5)
        try profile(app, .adapter, actual: 20, original: nil)
        try expect(app.panel.details.string.contains("failed"), "Per-profile failure must be visible.")
        print("smoke: helper request rejection and partial writes report precise failures")

        try select(.adapter, in: app)
        runner.configure(failedProfile: .battery)
        app.smokeQuitChoice = .restoreAndQuit
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == 0, "Failed restoration must keep the app open.")
        try expect(app.lastRequest?.target == .both, "Restore and quit must attempt both, not the selected target.")
        try expect(app.currentStatus?.hasManagedChanges == true, "Failed restoration must retain records.")
        runner.configure()
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == 1, "Verified restoration should allow quitting.")
        try expect(app.currentStatus?.hasManagedChanges == false, "No records may remain after restore and quit.")

        try select(.battery, in: app)
        app.panel.prevent.performClick(nil)
        try await settle(app)
        let beforeQuitChoices = runner.writeCount
        app.smokeQuitChoice = .cancel
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == 1, "Cancel must keep the app open.")
        app.smokeQuitChoice = .keepSettings
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == 2, "Keep settings should allow quitting.")
        try expect(runner.writeCount == beforeQuitChoices, "Keep and Cancel must not restore.")
        try profile(app, .battery, actual: 0, original: 5)
        print("smoke: all quit choices exercised without dialogs; failed restore stays open")

        // A disappeared profile leaves a real pending record in the fake state store.
        app.panel.restore.performClick(nil)
        try await settle(app)
        runner.simulateMissingBatteryAfterWrite(true)
        app.panel.prevent.performClick(nil)
        try await settle(app)
        try expect(app.currentStatus?.hasManagedChanges == true, "An unavailable profile must retain pending records.")
        let pending = app.currentStatus?.profiles.first { $0.profile == .battery }
        try expect(pending?.phase?.hasPrefix("pending") == true, "The UI must show the actual pending phase.")
        try expect(app.panel.ownershipLabels[.battery]?.stringValue.contains("pending") == true, "Pending ownership must be visible.")
        app.smokeQuitChoice = .restoreAndQuit
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == 2, "Pending records must block restore and quit.")
        runner.simulateMissingBatteryAfterWrite(false)
        runner.changeExternally(.battery, minutes: 0)
        app.pollStatus()
        try await settle(app)
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == 3, "Recovered pending state should restore and allow quitting.")
        print("smoke: pending records remain visible and prevent an unsafe quit")

        let beforeRefreshes = runner.writeCount
        runner.changeExternally(.adapter, minutes: 9)
        app.menuWillOpen(app.menu)
        try await settle(app)
        try profile(app, .adapter, actual: 9, original: nil)
        runner.changeExternally(.battery, minutes: 4)
        app.pollStatus()
        try await settle(app)
        try profile(app, .battery, actual: 4, original: nil)
        runner.configure(readFailure: true)
        app.panel.refresh.performClick(nil)
        try await settle(app)
        try expect(!app.panel.prevent.isEnabled, "A failed status read must disable writes until refresh.")
        try expect(app.panel.details.string.contains("Fake status read failure"), "Status errors must be visible.")
        runner.configure()
        app.panel.refresh.performClick(nil)
        try await settle(app)
        try expect(app.panel.prevent.isEnabled, "Successful refresh must recover the controls.")
        app.panel.window.close()
        try expect(runner.writeCount == beforeRefreshes, "Refresh and window closure must not change settings.")
        try expect(runner.maximumConcurrency == 1, "Every core call must remain serialized.")
        print("smoke: menu, periodic, and manual refresh show external changes; closure does not restore")
    }

    private func exerciseHelperAvailability(in directory: URL) async throws {
        let runner = SmokePowerRunner()
        runner.setHelperAvailability(HelperAvailability(state: .setupRequired, message: "Fake helper needs setup."))
        let app = HearthAppController(
            service: HearthService(runner: runner, stateDirectory: directory),
            smokeTest: true
        ) { [weak self] in
            self?.terminationCount += 1
        }
        defer {
            app.stop()
            app.panel.window.close()
            app.setupPanel.window.close()
        }
        app.start()
        try await settle(app)
        for state in [HelperState.setupRequired, .incompatible, .unavailable] {
            runner.setHelperAvailability(HelperAvailability(state: state, message: "Fake helper needs setup / repair."))
            app.panel.refresh.performClick(nil)
            try await settle(app)
            try profile(app, .battery, actual: 5, original: nil)
            try profile(app, .adapter, actual: 0, original: nil)
            try expect(app.currentStatus?.helper.state == state, "Actual helper state must be available.")
            try expect(!app.preventItem.isEnabled && !app.restoreItem.isEnabled && !app.timeoutItem.isEnabled, "Menu writes require a ready helper.")
            try expect(!app.panel.prevent.isEnabled && !app.panel.restore.isEnabled && !app.panel.setTimeout.isEnabled, "Panel writes require a ready helper.")
            try expect(app.panel.refresh.isEnabled && app.panel.setup.isEnabled, "Refresh and setup guidance must remain available.")
            try expect(app.helperItem.title != "Helper: Ready", "Helper unavailability must be visible in the menu.")
            try expect(app.panel.details.string.contains("Fake helper needs setup / repair."), "Helper details must remain visible.")
            app.panel.prevent.sendAction(app.panel.prevent.action, to: app.panel.prevent.target)
            app.panel.restore.sendAction(app.panel.restore.action, to: app.panel.restore.target)
            app.panel.setTimeout.sendAction(app.panel.setTimeout.action, to: app.panel.setTimeout.target)
            try expect(!app.isBusy, "Unavailable helper must block even directly dispatched write actions.")
            try activate(app.setupItem)
            app.panel.setup.performClick(nil)
            try expect(runner.writeCount == 0, "Unavailable controls and setup guidance must never write.")
        }
        try expect(app.setupPanel.instructions.string.contains("scripts/package-installer.sh"), "Setup guidance must name the explicit build step.")
        try expect(app.setupPanel.instructions.string.contains("versioned local setup package"), "Setup guidance must name the reviewed package.")
        try expect(app.setupPanel.instructions.string.contains("does not guarantee"), "Setup guidance must not promise a consent bypass.")
        try expect(app.setupPanel.instructions.string.contains("scripts/uninstall.sh --restored --gui"), "Removal must be an explicit workflow.")

        runner.setHelperAvailability(.ready)
        app.panel.refresh.performClick(nil)
        try await settle(app)
        try expect(app.panel.prevent.isEnabled, "A ready helper must enable controls after refresh.")
        try select(.battery, in: app)
        app.panel.prevent.performClick(nil)
        try expect(app.message == "Preventing idle sleep on battery…", "Battery progress must not claim both profiles.")
        try await settle(app)
        try profile(app, .battery, actual: 0, original: 5)

        runner.setHelperAvailability(HelperAvailability(state: .unavailable, message: "Fake helper stopped."))
        app.panel.refresh.performClick(nil)
        try await settle(app)
        let writesBeforeQuit = runner.writeCount
        let terminationsBeforeQuit = terminationCount
        app.smokeQuitChoice = .restoreAndQuit
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == terminationsBeforeQuit, "Restore and quit must stay open without a helper.")
        try expect(app.message.contains("Hearth is still open"), "Blocked restoration must explain why the app stayed open.")
        try expect(app.currentStatus?.hasManagedChanges == true, "Blocked restoration must retain the original baseline.")
        try expect(runner.writeCount == writesBeforeQuit, "Restore and quit must not request a write without a helper.")
        app.smokeQuitChoice = .keepSettings
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == terminationsBeforeQuit + 1, "Keep settings must remain possible without a helper.")
        try expect(runner.writeCount == writesBeforeQuit, "Keep settings must not write.")

        runner.setHelperAvailability(.ready)
        app.smokeQuitChoice = .restoreAndQuit
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == terminationsBeforeQuit + 2, "Verified restoration can quit after helper recovery.")
        try profile(app, .battery, actual: 5, original: nil)
        print("smoke: setup / repair states keep actual values and guidance available; writes and restore-and-quit require helper readiness")
    }

    private func exerciseCorruptState(in directory: URL) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let created = FileManager.default.createFile(
            atPath: directory.appendingPathComponent("state.json").path,
            contents: Data("invalid smoke-test state".utf8),
            attributes: [.posixPermissions: 0o600]
        )
        try expect(created, "Could not create the isolated damaged-state fixture.")
        let runner = SmokePowerRunner()
        let app = HearthAppController(
            service: HearthService(runner: runner, stateDirectory: directory),
            smokeTest: true
        ) { [weak self] in
            self?.terminationCount += 1
        }
        defer {
            app.stop()
            app.panel.window.close()
            app.setupPanel.window.close()
        }
        app.start()
        try await settle(app)
        try profile(app, .battery, actual: 5, original: nil)
        try profile(app, .adapter, actual: 0, original: nil)
        try expect(app.currentStatus?.warnings.isEmpty == false, "Damaged state must produce a visible warning.")
        try expect(app.panel.details.string.contains("Warnings"), "State warnings must be shown in the native UI.")
        try expect(app.panel.ownershipLabels[.battery]?.stringValue.contains("uncertain") == true, "Untrusted ownership must not be labeled unmanaged.")

        let beforeQuit = terminationCount
        app.smokeQuitChoice = .cancel
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit, "Warnings must require a quit choice even without trusted managed records.")
        app.smokeQuitChoice = .restoreAndQuit
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit, "Damaged state must block restore and quit.")
        try expect(app.lastActionSucceeded == false, "A state failure must not claim restoration succeeded.")
        try expect(runner.writeCount == 0, "Damaged state must never result in a guessed power write.")
        app.smokeQuitChoice = .keepSettings
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 1, "An explicit Keep settings choice should still allow quitting.")
        print("smoke: damaged state shows actual values and uncertain ownership; restore-and-quit stays open")
    }

    private func enter(_ text: String, in app: HearthAppController) {
        app.panel.minutes.stringValue = text
        app.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: app.panel.minutes))
    }

    private func select(_ target: PowerTarget, in app: HearthAppController) throws {
        let targets: [PowerTarget] = [.both, .battery, .adapter]
        guard let index = targets.firstIndex(of: target) else {
            throw SmokeFailure(message: "Unknown test target.")
        }
        try activate(app.targetItems[index])
        try expect(app.target == target, "Power target menu must select \(target.rawValue).")
        try expect(app.targetItems[index].state == .on, "Selected target must be checked.")
    }

    private func activate(_ item: NSMenuItem) throws {
        guard let menu = item.menu else {
            throw SmokeFailure(message: "Native item has no menu: \(item.title)")
        }
        try expect(item.isEnabled, "Native menu item is unexpectedly disabled: \(item.title)")
        menu.performActionForItem(at: menu.index(of: item))
    }

    private func settle(_ app: HearthAppController) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while app.isBusy {
            guard clock.now < deadline else {
                throw SmokeFailure(message: "Timed out waiting for native operations.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func profile(_ app: HearthAppController, _ profile: PowerProfile, actual: Int, original: Int?) throws {
        let status = app.currentStatus?.profiles.first { $0.profile == profile }
        try expect(status?.actualMinutes == actual, "\(profile.label): expected actual \(actual), got \(String(describing: status?.actualMinutes)).")
        try expect(status?.originalMinutes == original, "\(profile.label): incorrect restore baseline.")
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SmokeFailure(message: message) }
    }
}
