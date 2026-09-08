import AppKit
import Darwin
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
    private var displayValues: [PowerProfile: Int] = [.battery: 2, .adapter: 10]
    private var batches: [[PowerChange]] = []
    private var denied = false
    private var failedProfile: PowerProfile?
    private var failedSetting: PowerSetting = .system
    private var readFailure = false
    private var activeCalls = 0
    private var maximumCalls = 0
    private var hideBatteryAfterApply = false
    private var hiddenBatterySetting: PowerSetting = .system
    private var failReadsAfterApply = false
    private var helper = HelperAvailability.ready

    var writeCount: Int { lock.withLock { batches.count } }
    var maximumConcurrency: Int { lock.withLock { maximumCalls } }

    func writes(for setting: PowerSetting) -> [PowerChange] {
        lock.withLock { batches.flatMap { $0 }.filter { $0.setting == setting } }
    }

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
            return PowerSettings(values: values, currentSource: "Sample power adapter", displayValues: displayValues)
        }
    }

    // Explicitly implement both protocol paths: sample actions can only reach this in-memory runner.
    func apply(_ changes: [PowerChange], holdingLock descriptor: Int32) throws -> [CommandOutcome] {
        try apply(changes)
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
                if change.profile == failedProfile &&
                    change.setting == failedSetting {
                    return CommandOutcome(profile: change.profile, exitCode: 1, message: "Fake write failure.", setting: change.setting)
                }
                if change.setting == .system {
                    values[change.profile] = change.minutes
                } else {
                    displayValues[change.profile] = change.minutes
                }
                return CommandOutcome(profile: change.profile, exitCode: 0, setting: change.setting)
            }
            if hideBatteryAfterApply {
                if hiddenBatterySetting == .system {
                    values.removeValue(forKey: .battery)
                } else {
                    displayValues.removeValue(forKey: .battery)
                }
            }
            if failReadsAfterApply { readFailure = true }
            return results
        }
    }

    func configure(
        denied: Bool = false, failedProfile: PowerProfile? = nil, readFailure: Bool = false,
        failedSetting: PowerSetting = .system, failReadsAfterApply: Bool = false
    ) {
        lock.withLock {
            self.denied = denied
            self.failedProfile = failedProfile
            self.failedSetting = failedSetting
            self.readFailure = readFailure
            self.failReadsAfterApply = failReadsAfterApply
        }
    }

    func changeExternally(_ profile: PowerProfile, minutes: Int?, setting: PowerSetting = .system) {
        lock.withLock {
            if setting == .system {
                values[profile] = minutes
            } else {
                displayValues[profile] = minutes
            }
        }
    }

    func simulateMissingBatteryAfterWrite(_ enabled: Bool, setting: PowerSetting = .system) {
        lock.withLock {
            hideBatteryAfterApply = enabled
            hiddenBatterySetting = setting
        }
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

// A screen-saver model only: no TCC, Apple Events, preferences, or installed runtime.
final class SmokeScreenSaver: ScreenSaverControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ScreenSaverStoredValue
    private var availability = ScreenSaverAvailability.ready
    private var failure: ScreenSaverError?
    private var readFailure: String?
    private var writes = 0

    init(storedValue: ScreenSaverStoredValue = .integer(300)) {
        self.storedValue = storedValue
    }

    var writeCount: Int { lock.withLock { writes } }

    func observe() throws -> ScreenSaverObservation {
        try lock.withLock {
            if let readFailure { throw ScreenSaverError.unavailable(readFailure) }
            let current = configuration()
            return ScreenSaverObservation(
                delaySeconds: current.effectiveSeconds, availability: availability,
                message: "Sample Lock availability: \(availability.rawValue).", configuration: current
            )
        }
    }

    func apply(value: ScreenSaverStoredValue, expected: ScreenSaverConfiguration) throws {
        try lock.withLock {
            writes += 1
            if let failure { throw failure }
            guard availability == .ready, configuration() == expected else {
                throw ScreenSaverError.rejected("Sample screen-saver change rejected.")
            }
            storedValue = value
        }
    }

    private func configuration() -> ScreenSaverConfiguration {
        let seconds: Int
        switch storedValue {
        case .absent: seconds = 300
        case .integer(let value): seconds = value
        }
        return ScreenSaverConfiguration(
            storedValue: storedValue, effectiveSeconds: seconds,
            dictionarySource: .currentUserCurrentHost,
            valueSource: storedValue == .absent ? .registeredDefaults : .currentUserCurrentHost,
            contextFingerprint: String(repeating: "a", count: 64)
        )
    }

    func configure(
        availability: ScreenSaverAvailability = .ready,
        failure: ScreenSaverError? = nil,
        readFailure: String? = nil
    ) {
        lock.withLock {
            self.availability = availability
            self.failure = failure
            self.readFailure = readFailure
        }
    }
}

private final class SmokeLockRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var failing = false
    var callCount: Int { lock.withLock { calls } }

    func setFailure(_ value: Bool) { lock.withLock { failing = value } }

    func refresh() throws {
        guard !Thread.isMainThread else { throw SmokeFailure(message: "Registration callback ran on the main actor.") }
        Thread.sleep(forTimeInterval: 0.04)
        try lock.withLock {
            calls += 1
            if failing { throw SmokeFailure(message: "Sample Lock registration failed.") }
        }
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
            try await exerciseDisplay(in: directory.appendingPathComponent("display", isDirectory: true))
            try await exerciseAdapterOnlyQuit(in: directory.appendingPathComponent("adapter-only", isDirectory: true))
            try await exerciseActionErrors(in: directory.appendingPathComponent("action-errors", isDirectory: true))
            try await exerciseHelperAvailability(in: directory.appendingPathComponent("helper", isDirectory: true))
            try await exerciseCorruptState(in: directory.appendingPathComponent("damaged", isDirectory: true))
            try await exerciseLock(in: directory.appendingPathComponent("lock", isDirectory: true))
            try await exerciseLockFailures(in: directory.appendingPathComponent("lock-failures", isDirectory: true))
            try await exerciseRegistrationRefresh(in: directory.appendingPathComponent("registration", isDirectory: true))
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
        try expect(app.preventItem.title == "Keep system awake", "System must have a clear, explicit primary action.")
        try expect(app.displayItem.title == "Keep display awake", "Display must have an independent primary action.")
        try expect(app.menu.items.contains { $0.submenu === app.advancedMenu }, "Secondary controls must be under Advanced.")
        try expect(!app.menu.items.contains(app.timeoutItem) && !app.menu.items.contains(app.setupItem), "Advanced controls must not fill the main menu.")
        try expect(app.panel.target.indexOfSelectedItem == 0, "Native popup must show Both.")
        try expect(runner.writeCount == 0, "Opening the app must not write power settings.")
        try expect(app.panel.window.contentView != nil, "The actual native window must be constructed.")
        app.panel.window.contentView?.layoutSubtreeIfNeeded()
        try expect(app.panel.displayNote.stringValue == "Display sleep control does not prevent automatic locking.", "The automatic-lock limitation is required.")
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
        try expect(app.message == "Keeping system awake on battery and power adapter…", "Progress must name the setting and both selected profiles.")
        try expect(!app.preventItem.isEnabled && !app.displayItem.isEnabled && !app.restoreItem.isEnabled, "Menu writes must be disabled during work.")
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
        try expect(app.preventItem.title == "Restore system settings", "Active native primary action must preserve honest restore semantics.")
        try profile(app, .battery, actual: 2, original: nil, setting: .display)
        try profile(app, .adapter, actual: 10, original: nil, setting: .display)
        try expect(runner.writes(for: .display).isEmpty, "Existing System controls must never opt into Display.")
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
        try expect(app.message == "Setting system timeout to 10 minutes on power adapter…", "Timeout progress must name the real setting and target.")
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
        try expect(app.lastRequest?.target == .battery, "Restore and quit must restore the managed battery, not the selected unmanaged adapter.")
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
        try expect(app.panel.ownershipLabels[.battery]?.stringValue.contains("unconfirmed") == true, "Unconfirmed ownership must be visible without raw journal terms.")
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

    private func exerciseDisplay(in directory: URL) async throws {
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
        let visible = app.menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }
        try expect(visible.count <= 11, "The everyday menu must stay compact with a single Lock action.")
        try expect(visible.contains { $0.title == "System · Battery: 5 min · Adapter: never" }, "Show actual System settings in the main menu.")
        try expect(visible.contains { $0.title == "Display · Battery: 2 min · Adapter: 10 min" }, "Show actual Display settings in the main menu.")
        try expect(!visible.contains { $0.title.contains("baseline") || $0.title.contains("pending-") }, "Keep raw restore details out of the everyday menu.")
        try expect(app.setting == .system && app.target == .both, "Advanced defaults must remain System and Both.")
        try expect(!app.menu.items.contains(app.settingItems[0]), "The explicit setting selector belongs in Advanced.")
        app.panel.setting.selectItem(at: 1)
        app.panel.setting.sendAction(app.panel.setting.action, to: app.panel.setting.target)
        try expect(app.setting == .display && app.settingItems[1].state == .on, "The native details popup must select Display and update Advanced.")
        try selectSetting(.system, in: app)

        try select(.battery, in: app)
        try activate(app.displayItem)
        try expect(app.message == "Keeping display awake on battery…", "Display progress must identify the selected target.")
        try expect(!app.preventItem.isEnabled && !app.displayItem.isEnabled, "All writes stay disabled while the worker is busy.")
        app.panel.prevent.sendAction(app.panel.prevent.action, to: app.panel.prevent.target)
        try await settle(app)
        try profile(app, .battery, actual: 0, original: 2, setting: .display)
        try profile(app, .adapter, actual: 10, original: nil, setting: .display)
        try profile(app, .battery, actual: 5, original: nil)
        try expect(runner.writes(for: .system).isEmpty, "Display must not automatically change System, even through a directly dispatched busy action.")
        try expect(app.setting == .system, "Main menu actions must name their setting, not borrow Advanced's selection.")
        try selectSetting(.display, in: app)
        try expect(app.panel.actualLabels[.battery]?.stringValue.contains("No idle display timeout") == true, "Details must describe the selected Display setting.")
        try select(.adapter, in: app)
        try expect(app.displayItem.title == "Keep display awake", "Unselected battery ownership must not turn the adapter action into Restore.")
        try activate(app.displayItem)
        try await settle(app)
        try profile(app, .adapter, actual: 0, original: 10, setting: .display)
        try select(.battery, in: app)
        try activate(app.displayItem)
        try await settle(app)
        try profile(app, .battery, actual: 2, original: nil, setting: .display)
        try profile(app, .adapter, actual: 0, original: 10, setting: .display)
        try expect(!app.restoreItem.isEnabled && !app.panel.restore.isEnabled, "Restore must require ownership in the selected setting and target.")
        try select(.both, in: app)
        try activate(app.restoreItem)
        try await settle(app)
        try profile(app, .adapter, actual: 10, original: nil, setting: .display)
        try expect(runner.writes(for: .system).isEmpty, "Display prevent and restore must never write System.")

        runner.changeExternally(.battery, minutes: 0, setting: .display)
        runner.changeExternally(.adapter, minutes: 0, setting: .display)
        app.pollStatus()
        try await settle(app)
        try expect(!app.displayItem.isEnabled && !app.panel.prevent.isEnabled && !app.restoreItem.isEnabled, "Unmanaged never-display must not offer a meaningless keep-awake or guessed restore.")
        try expect(app.timeoutItem.isEnabled, "A permanent timeout must remain available for unmanaged never-display.")
        try select(.adapter, in: app)
        enter("7", in: app)
        app.panel.setTimeout.performClick(nil)
        try await settle(app)
        try expect(app.lastRequest?.setting == .display && app.lastRequest?.target == .adapter, "The explicit timeout must use Advanced's setting and power target.")
        try profile(app, .adapter, actual: 7, original: nil, setting: .display)
        try profile(app, .battery, actual: 0, original: nil, setting: .display)
        try profile(app, .adapter, actual: 0, original: nil)

        runner.changeExternally(.adapter, minutes: 8)
        app.pollStatus()
        try await settle(app)
        try activate(app.preventItem)
        try await settle(app)
        try profile(app, .adapter, actual: 0, original: 8)
        try profile(app, .adapter, actual: 7, original: nil, setting: .display)
        try activate(app.displayItem)
        try await settle(app)
        enter("9", in: app)
        app.panel.setTimeout.performClick(nil)
        try await settle(app)
        try profile(app, .adapter, actual: 9, original: nil, setting: .display)
        try profile(app, .adapter, actual: 0, original: 8)
        try activate(app.preventItem)
        try await settle(app)
        try profile(app, .adapter, actual: 8, original: nil)
        try profile(app, .adapter, actual: 9, original: nil, setting: .display)
        print("smoke: System/Display actions, timeouts and restores preserve selected-only ownership and targets")

        runner.changeExternally(.battery, minutes: nil, setting: .display)
        try select(.both, in: app)
        app.pollStatus()
        try await settle(app)
        try expect(!app.displayItem.isEnabled && app.preventItem.isEnabled, "Unavailable Display must not disable known System values.")
        try select(.adapter, in: app)
        try expect(app.displayItem.isEnabled, "Unavailable unselected Display battery must not disable the available adapter.")
        runner.changeExternally(.battery, minutes: 2, setting: .display)
        runner.changeExternally(.battery, minutes: nil)
        try select(.both, in: app)
        app.pollStatus()
        try await settle(app)
        try expect(!app.preventItem.isEnabled && app.displayItem.isEnabled, "Unavailable System must not disable known Display values.")
        runner.changeExternally(.battery, minutes: 5)
        app.pollStatus()
        try await settle(app)

        try activate(app.preventItem)
        try await settle(app)
        try activate(app.displayItem)
        try await settle(app)
        try select(.battery, in: app)
        let beforeQuit = terminationCount
        app.smokeQuitChoice = .restoreAndQuit
        runner.configure(failedProfile: .adapter, failedSetting: .display)
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit, "A Display restore failure must keep Hearth open after System succeeded.")
        try expect(app.lastActionSucceeded == false && app.message.contains("still open"), "Partial restore-and-quit must not claim completion.")
        try expect(app.lastRestoreRequests.map(\.setting) == [.system, .display], "Restore-and-quit must cover both managed settings.")
        try expect(app.lastRestoreRequests.allSatisfy { $0.target == .both }, "Quit restoration ignores the Advanced target.")
        try profile(app, .battery, actual: 5, original: nil)
        try profile(app, .adapter, actual: 8, original: nil)
        try profile(app, .battery, actual: 2, original: nil, setting: .display)
        try profile(app, .adapter, actual: 0, original: 9, setting: .display)
        try expect(app.panel.details.string.contains("System ·") && app.panel.details.string.contains("Display ·"), "Retain the outcome of each independent quit restoration.")

        runner.configure()
        try select(.both, in: app)
        try activate(app.displayItem)
        try await settle(app)
        try activate(app.preventItem)
        try await settle(app)
        try activate(app.displayItem)
        try await settle(app)
        runner.configure(failedProfile: .battery)
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit, "An earlier System failure must not be hidden by later Display success.")
        try expect(app.lastActionSucceeded == false && app.lastRestoreRequests.count == 2, "Independent restoration must attempt Display and retain the System failure.")
        try profile(app, .battery, actual: 0, original: 5)
        try profile(app, .battery, actual: 2, original: nil, setting: .display)
        try profile(app, .adapter, actual: 9, original: nil, setting: .display)

        runner.configure(failReadsAfterApply: true)
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit && app.lastActionSucceeded == false, "Unconfirmed read-back must never allow restore-and-quit.")
        try expect(app.message.contains("still open") && !app.preventItem.isEnabled && !app.displayItem.isEnabled, "Failed verification must leave both controls safely disabled.")
        runner.configure()
        app.pollStatus()
        try await settle(app)
        try expect(app.currentStatus?.hasManagedChanges == false, "A fresh read may reconcile the completed restoration.")

        try activate(app.preventItem)
        try await settle(app)
        try activate(app.displayItem)
        try await settle(app)
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 1 && app.lastActionSucceeded == true, "Verified restoration of both settings should allow quitting.")
        try expect(app.currentStatus?.hasManagedChanges == false, "No setting may retain ownership after successful restore-and-quit.")
        try expect(runner.maximumConcurrency == 1, "Quit must use the existing serialized worker, not overlapping core calls.")
        print("smoke: quit restores both settings sequentially; first, second and verification failures keep Hearth open")

        runner.simulateMissingBatteryAfterWrite(true, setting: .display)
        try select(.battery, in: app)
        try activate(app.displayItem)
        try await settle(app)
        try expect(app.currentStatus?.displayProfiles.first { $0.profile == .battery }?.phase?.hasPrefix("pending") == true, "Unconfirmed Display writes must retain pending state.")
        let pendingWrites = runner.writeCount
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 1 && runner.writeCount == pendingWrites, "Pending Display must block unsafe restore-and-quit without a new write.")
        app.smokeQuitChoice = .cancel
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 1, "Cancel must retain Display state.")
        app.smokeQuitChoice = .keepSettings
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 2 && runner.writeCount == pendingWrites, "Keep settings may quit with pending Display without changing anything.")
        runner.simulateMissingBatteryAfterWrite(false)
        runner.changeExternally(.battery, minutes: 0, setting: .display)
        app.pollStatus()
        try await settle(app)
        app.smokeQuitChoice = .restoreAndQuit
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 3, "Display-only managed state must offer and complete restore-and-quit.")
        try expect(app.lastRestoreRequests.map(\.setting) == [.display], "Display-only restoration must not request unrelated System work.")
        print("smoke: unavailable and pending Display states stay truthful; display-only quit handles all choices")
    }

    private func exerciseAdapterOnlyQuit(in directory: URL) async throws {
        let runner = SmokePowerRunner()
        runner.changeExternally(.battery, minutes: nil)
        runner.changeExternally(.battery, minutes: nil, setting: .display)
        runner.changeExternally(.adapter, minutes: 8)
        let saver = SmokeScreenSaver()
        let lock = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        let app = HearthAppController(
            service: HearthService(runner: runner, stateDirectory: directory, idleLockController: lock),
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
        try expect(!app.preventItem.isEnabled && !app.displayItem.isEnabled, "Both requires both selected profiles to be available for ordinary actions.")
        try select(.adapter, in: app)
        try activate(app.preventItem)
        try await settle(app)
        try activate(app.displayItem)
        try await settle(app)
        try profile(app, .adapter, actual: 0, original: 8)
        try profile(app, .adapter, actual: 0, original: 10, setting: .display)

        let beforeQuit = terminationCount
        let beforeWrites = runner.writeCount
        app.smokeQuitChoice = .restoreAndQuit
        runner.changeExternally(.adapter, minutes: nil, setting: .display)
        app.pollStatus()
        try await settle(app)
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit && runner.writeCount == beforeWrites, "An unavailable managed adapter must still block restore-and-quit.")
        try expect(app.currentStatus?.displayProfiles.first { $0.profile == .adapter }?.isManaged == true, "Unavailable managed Display state must be retained.")

        runner.changeExternally(.adapter, minutes: 0, setting: .display)
        app.pollStatus()
        try await settle(app)
        try select(.battery, in: app)
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 1 && app.lastActionSucceeded == true, "Adapter-only Macs must restore both managed settings and quit.")
        try expect(app.lastRestoreRequests.map(\.setting) == [.system, .display], "Adapter-only quit must restore System and Display.")
        try expect(app.lastRestoreRequests.allSatisfy { $0.target == .adapter }, "Quit must not include an absent, unmanaged battery in either restore call.")
        try expect(app.currentStatus?.hasManagedChanges == false, "Adapter-only quit must verify that no records remain.")
        try profile(app, .adapter, actual: 8, original: nil)
        try profile(app, .adapter, actual: 10, original: nil, setting: .display)
        try expect(runner.maximumConcurrency == 1, "Adapter-only quit calls must remain sequential.")
        print("smoke: adapter-only quit restores managed System/Display; unavailable managed records still block quit")
        try expect(app.target == .battery && app.lockItem.isEnabled, "Lock must ignore an unavailable selected power target.")
        try activate(app.lockItem)
        try await settle(app)
        try expect(app.currentStatus?.idleLock?.phase == .active && app.currentStatus?.idleLock?.dependencies.count == 2, "Adapter-only Lock must coordinate exactly the two available settings.")
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 2 && app.lastActionSucceeded == true, "Lock-only restore-and-quit must succeed on an adapter-only Mac.")
        try expect(app.lastRestoreRequests.isEmpty && app.currentStatus?.hasManagedChanges == false, "Lock-only quit must not invent independent restores.")
        print("smoke: adapter-only Lock ignores the selected target; Lock-only restore-and-quit completes")
    }

    private func exerciseActionErrors(in directory: URL) async throws {
        let runner = SmokePowerRunner()
        let app = HearthAppController(
            service: HearthService(runner: runner, stateDirectory: directory),
            smokeTest: true,
            onTermination: {}
        )
        defer {
            app.stop()
            app.panel.window.close()
            app.setupPanel.window.close()
        }
        app.start()
        try await settle(app)
        try select(.battery, in: app)
        runner.configure(failedProfile: .battery, failedSetting: .display)
        try activate(app.displayItem)
        try await settle(app)
        try expect(app.lastActionSucceeded == false, "The Display failure fixture must fail.")
        runner.configure()
        try activate(app.preventItem)
        try await settle(app)
        try expect(app.lastActionSucceeded == true, "An independent System action may still succeed.")
        try expect(app.panel.details.string.contains("Display action — not confirmed") && app.panel.details.string.contains("Fake write failure."), "System success must retain unresolved Display diagnostics.")
        try expect(app.panel.details.string.contains("System — last action"), "Show the independent System result alongside Display's error.")
        try expect(app.menu.items.contains { !$0.isHidden && $0.title == "Display action needs attention…" }, "Retain one compact Display error entry in the main menu.")
        app.pollStatus()
        try await settle(app)
        try expect(app.panel.details.string.contains("Display action — not confirmed"), "A successful status refresh must not erase Display action failure.")
        try activate(app.displayItem)
        try await settle(app)
        try expect(!app.panel.details.string.contains("Display action — not confirmed"), "A successful Display action may resolve its own failure.")

        runner.configure(failedProfile: .battery)
        try activate(app.preventItem)
        try await settle(app)
        try expect(app.lastActionSucceeded == false, "The System failure fixture must fail.")
        runner.configure()
        try activate(app.displayItem)
        try await settle(app)
        try expect(app.lastActionSucceeded == true && app.panel.details.string.contains("System action — not confirmed"), "Display success must likewise retain System's failure.")
        try expect(app.menu.items.contains { !$0.isHidden && $0.title == "System action needs attention…" }, "Retain compact System error feedback.")
        try activate(app.preventItem)
        try await settle(app)
        try expect(!app.panel.details.string.contains("action — not confirmed"), "Successful actions resolve only their own outstanding failures.")
        try expect(!app.menu.items.contains { !$0.isHidden && $0.title.contains("action needs attention") }, "Remove the error entry once both settings have succeeded.")
        print("smoke: action errors survive other-setting success and refresh, with compact setting-specific feedback")
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
            try expect(!app.preventItem.isEnabled && !app.displayItem.isEnabled && !app.restoreItem.isEnabled && !app.timeoutItem.isEnabled, "Both settings require a ready helper.")
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
        try expect(app.message == "Keeping system awake on battery…", "Battery progress must not claim both profiles.")
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

    private func exerciseLock(in directory: URL) async throws {
        let runner = SmokePowerRunner()
        runner.changeExternally(.battery, minutes: 1)
        let saver = SmokeScreenSaver()
        let lock = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        let service = HearthService(runner: runner, stateDirectory: directory, idleLockController: lock)
        let app = HearthAppController(service: service, smokeTest: true) { [weak self] in
            self?.terminationCount += 1
        }
        defer {
            app.stop()
            app.panel.window.close()
            app.setupPanel.window.close()
        }
        app.start()
        try await settle(app)
        try expect(app.lockItem.title == "Prevent idle lock" && app.lockItem.isEnabled, "Lock needs one explicit current-user action.")
        try expect(saver.writeCount == 0 && runner.writeCount == 0, "Startup must never enable Lock.")
        try expect(!app.advancedMenu.items.contains { $0.title == "Enable Lock controls" }, "Obsolete Automation setup must not be offered.")
        try activate(app.preventItem)
        try await settle(app)
        try profile(app, .battery, actual: 0, original: 1)
        try select(.battery, in: app)
        try activate(app.lockItem)
        try expect(app.isBusy && !app.displayItem.isEnabled, "Lock writes must use the same busy controls.")
        try await settle(app)
        try expect(app.lastLockRequest == IdleLockRequest(action: .on), "Lock action must have no target.")
        try expect(app.currentStatus?.idleLock?.phase == .active && app.lastActionSucceeded == true, "Confirmed settings must complete the Lock action.")
        try expect(app.panel.lockStatus.stringValue == "Lock · Configured", "Preference readback must say Configured, not Active.")
        try expect(app.panel.details.string.contains("do not prove immediate macOS timer adoption"), "Configured settings must not imply immediate runtime protection.")
        try expect(app.currentStatus?.idleLock?.dependencies.count == 4, "Lock must cover all available profiles, not selected battery only.")
        try expect(app.currentStatus?.idleLock?.dependencies.filter { $0.setting == .system }.allSatisfy { !$0.acquired } == true, "Existing System zero settings must be borrowed.")
        try expect(app.preventItem.title.contains("Required by Lock") && !app.preventItem.isEnabled, "Required System must direct users to Restore Lock.")
        try expect(app.displayItem.title.contains("Required by Lock") && !app.displayItem.isEnabled, "Required Display must not be independently restored.")
        try expect(app.panel.ownershipLabels[.battery]?.stringValue.contains("Borrowed") == true, "Borrowed original settings must remain visible.")
        enter("9", in: app)
        let writes = runner.writeCount
        app.panel.setTimeout.sendAction(app.panel.setTimeout.action, to: app.panel.setTimeout.target)
        app.panel.prevent.sendAction(app.panel.prevent.action, to: app.panel.prevent.target)
        app.panel.restore.sendAction(app.panel.restore.action, to: app.panel.restore.target)
        try expect(runner.writeCount == writes && !app.isBusy, "Directly dispatched normal actions must not change Lock dependencies.")
        try activate(app.lockItem)
        try await settle(app)
        try expect(app.currentStatus?.idleLock?.phase == .off && app.lastActionSucceeded == true, "Restore Lock must release its transaction.")
        try profile(app, .battery, actual: 0, original: 1)
        try profile(app, .battery, actual: 2, original: nil, setting: .display)
        try profile(app, .adapter, actual: 10, original: nil, setting: .display)

        try activate(app.lockItem)
        try await settle(app)
        let beforeQuit = terminationCount
        app.smokeQuitChoice = .keepSettings
        let descriptor = open(directory.appendingPathComponent("state.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try expect(descriptor >= 0, "Could not open isolated shared core lock.")
        defer { close(descriptor) }
        try expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Could not hold isolated shared core lock.")
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit && app.message.contains("in progress"), "An external in-flight Lock request must block even Keep-and-quit through the shared core lock.")
        try expect(flock(descriptor, LOCK_UN) == 0, "Could not release isolated shared core lock.")
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 1 && app.currentStatus?.idleLock?.phase == .active, "Keep settings must keep Lock and its dependencies.")
        app.smokeQuitChoice = .restoreAndQuit
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit + 2 && app.lastActionSucceeded == true, "Restore-and-quit must restore Lock then pre-existing System.")
        try expect(app.lastLockRequest?.action == .restore && app.lastRestoreRequests.map(\.setting) == [.system], "Quit must release Lock before restoring the borrowed override.")
        try profile(app, .battery, actual: 1, original: nil)
        try expect(app.currentStatus?.hasManagedChanges == false, "Full quit restoration must leave no managed state.")
        print("smoke: global Lock borrows System0/orig1, requires both settings, restores only acquired values; quit restores Lock then all remaining overrides")
    }

    private func exerciseLockFailures(in directory: URL) async throws {
        let runner = SmokePowerRunner()
        let saver = SmokeScreenSaver()
        saver.configure(availability: .unavailable)
        let lock = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        let app = HearthAppController(
            service: HearthService(runner: runner, stateDirectory: directory, idleLockController: lock),
            smokeTest: true
        ) { [weak self] in self?.terminationCount += 1 }
        defer {
            app.stop()
            app.panel.window.close()
            app.setupPanel.window.close()
        }
        app.start()
        try await settle(app)
        try expect(!app.lockItem.isEnabled && app.currentStatus?.idleLock?.phase == .unavailable, "Unavailable preferences must disable Lock without affecting ordinary controls.")
        try expect(app.preventItem.isEnabled, "Independent power controls must remain available.")
        app.panel.lockAction.sendAction(app.panel.lockAction.action, to: app.panel.lockAction.target)
        try expect(!app.isBusy && saver.writeCount == 0, "Unavailable Lock must not write.")
        saver.configure(readFailure: "Synthetic preference synchronization failure.")
        app.pollStatus()
        try await settle(app)
        try expect(app.currentStatus?.idleLock?.phase == .unavailable, "Unavailable preferences must remain visible.")
        try expect(!app.advancedMenu.items.contains { $0.title == "Enable Lock controls" }, "Read failures must not offer Automation setup.")
        try expect(app.preventItem.isEnabled && app.displayItem.isEnabled, "A failed Lock getter must not disable safe independent power controls.")
        try expect(app.panel.details.string.contains("Synthetic preference synchronization failure"), "The actual read failure must remain visible.")
        saver.configure()
        app.pollStatus()
        try await settle(app)
        try expect(saver.writeCount == 0 && app.lockItem.isEnabled, "Readable preferences allow ordinary Lock without setup.")
        try activate(app.lockItem)
        try await settle(app)
        runner.configure(failedProfile: .adapter, failedSetting: .display)
        app.smokeQuitChoice = .restoreAndQuit
        let beforeQuit = terminationCount
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit && app.lastActionSucceeded == false, "Partial Lock restore must keep Hearth open.")
        try expect(app.currentStatus?.idleLock?.phase == .needsRestore && app.lockItem.title == "Restore Lock", "Partial restoration must not say protected or re-enable Lock.")
        try expect(app.lastRestoreRequests.isEmpty, "Quit cannot restore borrowed settings until Lock fully releases.")
        runner.configure()
        try activate(app.lockItem)
        try await settle(app)
        saver.configure(failure: .completionUnknown("Sample preference write completion unknown."))
        try activate(app.lockItem)
        try await settle(app)
        try expect(app.currentStatus?.idleLock?.phase == .uncertain && !app.lockItem.isEnabled, "Unknown completion must remain blocked, with no blind retry.")
        try expect(app.panel.lockStatus.stringValue.contains("Configuration unconfirmed") && app.lastActionSucceeded == false, "Unknown completion must not claim configured settings.")
        try expect(app.panel.details.string.contains("Saved effective screen-saver idle delay: 300 seconds"), "Unconfirmed state must expose its retained effective saver original in Advanced.")
        try expect(app.panel.details.string.contains("Restore Lock and required System/Display changes are blocked"), "Advanced must identify all blocked controls.")
        try expect(app.panel.details.string.contains("hearth status --json") && app.panel.details.string.contains("does not mean cancelled"), "Advanced must provide diagnostics without implying cancellation or replay.")
        try expect(app.preventItem.toolTip?.contains("changes are blocked") == true, "Unconfirmed dependency hints must not recommend a blocked Restore Lock.")
        try expect(app.panel.ownershipLabels[.battery]?.stringValue.contains("Use Restore Lock") != true, "Unconfirmed ownership must direct recovery review, not restoration.")
        try activate(app.quitItem)
        try await settle(app)
        try expect(terminationCount == beforeQuit, "Uncertain Lock must block Restore-and-quit.")
        print("smoke: fake-only preference failure, unavailable, partial restore and uncertain Lock remain truthful without Automation setup")
    }

    private func exerciseRegistrationRefresh(in directory: URL) async throws {
        let runner = SmokePowerRunner()
        let saver = SmokeScreenSaver()
        let registration = SmokeLockRegistration()
        let lock = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        let app = HearthAppController(
            service: HearthService(runner: runner, stateDirectory: directory, idleLockController: lock),
            smokeTest: true,
            refreshLockRegistration: { try registration.refresh() },
            onTermination: {}
        )
        defer {
            app.stop()
            app.panel.window.close()
            app.setupPanel.window.close()
        }
        app.start()
        try await settle(app)
        app.menuWillOpen(app.menu)
        app.pollStatus()
        try await settle(app)
        try expect(registration.callCount == 0, "Startup status, menu opening and periodic refresh must not republish automatically.")
        app.reportLockServiceError("Sample publication unavailable.")
        try expect(app.panel.details.string.contains("Sample publication unavailable."), "Publication startup failure must be visible.")
        app.panel.refresh.performClick(nil)
        try expect(app.isBusy && !app.lockItem.isEnabled, "Explicit registration refresh must be asynchronous with busy controls.")
        try await settle(app)
        try expect(registration.callCount == 1 && !app.panel.details.string.contains("Sample publication unavailable."), "Successful explicit refresh must clear only the service error.")
        try expect(runner.writeCount == 0 && saver.writeCount == 0, "Registration refresh cannot enable Lock.")

        registration.setFailure(true)
        app.refreshAfterReopen()
        try await settle(app)
        try expect(registration.callCount == 2 && app.panel.details.string.contains("Sample Lock registration failed."), "Reopen must surface registration failure without hiding native status.")
        try expect(app.currentStatus?.idleLock?.phase == .off && app.preventItem.isEnabled, "Publication failure must not disable valid local controls.")
        app.pollStatus()
        try await settle(app)
        try expect(registration.callCount == 2 && app.panel.details.string.contains("Sample Lock registration failed."), "Ordinary status reads must not silently retry or clear publication failures.")
        registration.setFailure(false)
        try activate(app.preventItem)
        app.refreshAfterReopen()
        app.refreshAfterReopen()
        try await settle(app)
        try expect(registration.callCount == 3, "Reopens during work must queue one registration refresh, not overlap or duplicate it.")
        try expect(!app.panel.details.string.contains("Sample Lock registration failed."), "Successful reopen may resolve the publication error.")
        try expect(runner.writeCount == 1 && saver.writeCount == 0, "Queued registration must not replay power/Lock actions.")
        print("smoke: explicit Refresh/reopen registration runs off-main, queues while busy, preserves local controls, and never authorizes or replays actions")
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

    private func selectSetting(_ setting: PowerSetting, in app: HearthAppController) throws {
        guard let index = PowerSetting.allCases.firstIndex(of: setting) else {
            throw SmokeFailure(message: "Unknown test setting.")
        }
        try activate(app.settingItems[index])
        try expect(app.setting == setting && app.settingItems[index].state == .on, "Setting menu must select and check \(setting.label).")
        try expect(app.panel.setting.indexOfSelectedItem == index, "Details selector must match Advanced's setting.")
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

    private func profile(
        _ app: HearthAppController, _ profile: PowerProfile, actual: Int, original: Int?,
        setting: PowerSetting = .system
    ) throws {
        let status = app.currentStatus?.profiles(for: setting).first { $0.profile == profile }
        try expect(status?.actualMinutes == actual, "\(setting.label) · \(profile.label): expected actual \(actual), got \(String(describing: status?.actualMinutes)).")
        try expect(status?.originalMinutes == original, "\(setting.label) · \(profile.label): incorrect restore baseline.")
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SmokeFailure(message: message) }
    }
}
