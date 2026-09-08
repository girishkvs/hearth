import AppKit
import HearthCore

enum QuitChoice {
    case keepSettings
    case restoreAndQuit
    case cancel
}

@MainActor
final class HearthAppController: NSObject, NSMenuDelegate, NSTextFieldDelegate {
    let menu = NSMenu(title: "Hearth")
    let advancedMenu = NSMenu(title: "Advanced")
    let panel = HearthPanel()
    let setupPanel = HearthSetupPanel()
    let helperItem = NSMenuItem(title: "Helper: Not yet checked", action: nil, keyEquivalent: "")
    let setupItem = NSMenuItem(title: "Setup / repair instructions…", action: nil, keyEquivalent: "")
    let preventItem = NSMenuItem(title: "Keep system awake", action: nil, keyEquivalent: "")
    let displayItem = NSMenuItem(title: "Keep display awake", action: nil, keyEquivalent: "")
    let lockItem = NSMenuItem(title: "Prevent idle lock", action: nil, keyEquivalent: "")
    let restoreItem = NSMenuItem(title: "Restore previous settings", action: nil, keyEquivalent: "")
    let timeoutItem = NSMenuItem(title: "Set sleep timeout…", action: nil, keyEquivalent: "")
    let quitItem = NSMenuItem(title: "Quit Hearth…", action: nil, keyEquivalent: "q")
    private(set) var targetItems: [NSMenuItem] = []
    private(set) var settingItems: [NSMenuItem] = []
    private(set) var target: PowerTarget = .both
    private(set) var setting: PowerSetting = .system
    private(set) var currentStatus: HearthStatus?
    private(set) var lastResult: OperationResult?
    private(set) var lastActionSucceeded: Bool?
    private(set) var lastRequest: PowerRequest?
    private(set) var lastRestoreRequests: [PowerRequest] = []
    private(set) var lastLockRequest: IdleLockRequest?
    private(set) var lastLockResult: IdleLockResult?
    private(set) var message = "Reading power settings…"
    private(set) var completedRefreshes = 0
    private(set) var isBusy = false
    var smokeQuitChoice: QuitChoice = .cancel

    private let worker: HearthWorker
    private let smokeTest: Bool
    private let onTermination: @MainActor () -> Void
    private let refreshLockRegistration: (@Sendable () throws -> Void)?
    private let presentation = HearthPresentation()
    private let statusItem: NSStatusItem
    private let sourceItem = NSMenuItem(title: "Reading power settings…", action: nil, keyEquivalent: "")
    private let summaryItem = NSMenuItem(title: "Checking settings…", action: nil, keyEquivalent: "")
    private let displaySummaryItem = NSMenuItem(title: "Checking display settings…", action: nil, keyEquivalent: "")
    private let lockSummaryItem = NSMenuItem(title: "Checking Lock settings…", action: nil, keyEquivalent: "")
    private let activityItem = NSMenuItem(title: "Reading power settings…", action: nil, keyEquivalent: "")
    private let warningsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh", action: nil, keyEquivalent: "")
    private var profileItems: [PowerProfile: (NSMenuItem, NSMenuItem)] = [:]
    private var periodicRefresh: Task<Void, Never>?
    private var pendingRefresh = false
    private var pendingRegistrationRefresh = false
    private var pendingQuit = false
    private var quitPromptOpen = false
    private var readError: String?
    private var actionDetails: [PowerSetting: String] = [:]
    private var actionFailures: Set<PowerSetting> = []
    private var lockDetails: String?
    private var lockFailed = false
    private var lockWorking = false
    private var lockServiceError: String?

    init(
        service: HearthService, smokeTest: Bool = false,
        refreshLockRegistration: (@Sendable () throws -> Void)? = nil,
        onTermination: @escaping @MainActor () -> Void
    ) {
        worker = HearthWorker(service: service)
        self.smokeTest = smokeTest
        self.onTermination = onTermination
        self.refreshLockRegistration = refreshLockRegistration
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        connectPanel()
        render()
    }

    func start() {
        requestRefresh()
        guard periodicRefresh == nil else { return }
        periodicRefresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                self?.pollStatus()
            }
        }
    }

    func stop() {
        periodicRefresh?.cancel()
        periodicRefresh = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func reportQuitBlocked(_ reason: String) {
        isBusy = false
        lockWorking = false
        pendingQuit = false
        readError = reason
        message = "Hearth is still open. \(reason)"
        lastActionSucceeded = false
        lockFailed = true
        lockDetails = reason
        render()
    }

    func reportLockServiceError(_ reason: String) {
        message = "CLI/web Lock service is unavailable. See Advanced."
        lockServiceError = reason
        render()
    }

    func refreshAfterReopen() {
        requestRegistrationRefresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        requestRefresh()
    }

    func pollStatus() {
        requestRefresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        renderControls()
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        advancedMenu.autoenablesItems = false
        menu.delegate = self
        let icon = NSImage(systemSymbolName: "flame", accessibilityDescription: "Hearth")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        if icon == nil {
            statusItem.button?.title = "Hearth"
        }
        statusItem.button?.setAccessibilityLabel("Hearth idle sleep settings")
        statusItem.menu = menu
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        connect(preventItem, action: #selector(systemPrimaryAction))
        menu.addItem(.separator())
        displaySummaryItem.isEnabled = false
        menu.addItem(displaySummaryItem)
        connect(displayItem, action: #selector(displayPrimaryAction))
        menu.addItem(.separator())
        lockSummaryItem.isEnabled = false
        menu.addItem(lockSummaryItem)
        connect(lockItem, action: #selector(lockPrimaryAction))
        let lockScope = NSMenuItem(title: "Current user · all sources · keeps System/Display awake", action: nil, keyEquivalent: "")
        lockScope.isEnabled = false
        menu.addItem(lockScope)
        let timerNote = NSMenuItem(title: "macOS may adopt or restore the timer later.", action: nil, keyEquivalent: "")
        timerNote.isEnabled = false
        menu.addItem(timerNote)
        activityItem.isEnabled = false
        menu.addItem(activityItem)
        connect(warningsItem, action: #selector(openControls))
        menu.addItem(.separator())
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advanced.submenu = advancedMenu
        menu.addItem(advanced)
        advancedMenu.addItem(sourceItem)
        let settingMenu = NSMenu(title: "Setting")
        settingMenu.autoenablesItems = false
        for (index, setting) in PowerSetting.allCases.enumerated() {
            let item = NSMenuItem(title: setting.label, action: #selector(selectSetting(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            settingMenu.addItem(item)
            settingItems.append(item)
        }
        let settingItem = NSMenuItem(title: "Setting", action: nil, keyEquivalent: "")
        settingItem.submenu = settingMenu
        advancedMenu.addItem(settingItem)
        for profile in PowerProfile.allCases {
            let actual = NSMenuItem(title: "\(profile.label): Reading…", action: nil, keyEquivalent: "")
            let ownership = NSMenuItem(title: "Restore information unavailable", action: nil, keyEquivalent: "")
            ownership.indentationLevel = 1
            advancedMenu.addItem(actual)
            advancedMenu.addItem(ownership)
            profileItems[profile] = (actual, ownership)
        }
        advancedMenu.addItem(.separator())
        helperItem.isEnabled = false
        advancedMenu.addItem(helperItem)
        connect(setupItem, action: #selector(openSetupInstructions), in: advancedMenu)
        advancedMenu.addItem(.separator())
        let targetMenu = NSMenu(title: "Power target")
        targetMenu.autoenablesItems = false
        for (index, title) in ["Both", "Battery", "Power adapter"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            targetMenu.addItem(item)
            targetItems.append(item)
        }
        let targetItem = NSMenuItem(title: "Power target", action: nil, keyEquivalent: "")
        targetItem.submenu = targetMenu
        advancedMenu.addItem(targetItem)
        connect(restoreItem, action: #selector(restorePreviousSettings), in: advancedMenu)
        connect(timeoutItem, action: #selector(openTimeout), in: advancedMenu)
        let controls = NSMenuItem(title: "Details and controls…", action: nil, keyEquivalent: ",")
        connect(controls, action: #selector(openControls), in: advancedMenu)
        connect(refreshItem, action: #selector(refreshClicked), in: advancedMenu)
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Manual lock and passwords stay unchanged.", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        connect(quitItem, action: #selector(quitClicked))
    }

    private func connect(_ item: NSMenuItem, action: Selector, in destination: NSMenu? = nil) {
        item.target = self
        item.action = action
        (destination ?? menu).addItem(item)
    }

    private func connectPanel() {
        panel.setting.target = self
        panel.setting.action = #selector(selectSetting(_:))
        panel.target.target = self
        panel.target.action = #selector(selectTarget(_:))
        panel.prevent.target = self
        panel.prevent.action = #selector(preventIdleSleep)
        panel.restore.target = self
        panel.restore.action = #selector(restorePreviousSettings)
        panel.setTimeout.target = self
        panel.setTimeout.action = #selector(setSleepTimeout)
        panel.minutes.delegate = self
        panel.minutes.target = self
        panel.minutes.action = #selector(setSleepTimeout)
        panel.refresh.target = self
        panel.refresh.action = #selector(refreshClicked)
        panel.setup.target = self
        panel.setup.action = #selector(openSetupInstructions)
        panel.lockAction.target = self
        panel.lockAction.action = #selector(lockPrimaryAction)
    }

    @objc private func selectTarget(_ sender: Any) {
        guard !isBusy && !quitPromptOpen && !pendingQuit else { return }
        let index = (sender as? NSMenuItem)?.tag ?? panel.target.indexOfSelectedItem
        let targets: [PowerTarget] = [.both, .battery, .adapter]
        guard targets.indices.contains(index) else { return }
        target = targets[index]
        render()
    }

    @objc private func selectSetting(_ sender: Any) {
        guard !isBusy && !quitPromptOpen && !pendingQuit else { return }
        let index = (sender as? NSMenuItem)?.tag ?? panel.setting.indexOfSelectedItem
        guard PowerSetting.allCases.indices.contains(index) else { return }
        setting = PowerSetting.allCases[index]
        render()
    }

    @objc private func systemPrimaryAction() {
        primaryAction(for: .system)
    }

    @objc private func displayPrimaryAction() {
        primaryAction(for: .display)
    }

    @objc private func lockPrimaryAction() {
        guard canChangeLock, let lock = currentStatus?.idleLock else { return }
        let request = IdleLockRequest(action: lock.hasManagedChanges ? .restore : .on)
        isBusy = true
        lockWorking = true
        lastLockRequest = request
        lastLockResult = nil
        lastActionSucceeded = nil
        message = request.action == .on ? "Configuring Lock for the current user…" : "Restoring Lock-owned settings…"
        render()
        Task { @MainActor [weak self, worker] in
            let update = await worker.performLock(request)
            guard let self else { return }
            self.acceptLockAction(update)
            self.finishWork()
        }
    }

    private func primaryAction(for setting: PowerSetting) {
        let managed = selectedProfiles(for: setting).contains(where: \.isManaged)
        beginAction(action: managed ? .restore : .on, setting: setting)
    }

    @objc private func preventIdleSleep() {
        beginAction(action: .on, setting: setting)
    }

    @objc private func restorePreviousSettings() {
        beginAction(action: .restore, setting: setting)
    }

    @objc private func setSleepTimeout() {
        guard canWrite(setting) else { return }
        do {
            let minutes = try presentation.minutes(panel.minutes.stringValue)
            beginAction(action: .sleep, setting: setting, minutes: minutes)
        } catch {
            message = error.localizedDescription
            lastActionSucceeded = false
            actionDetails[setting] = message
            actionFailures.insert(setting)
            render()
        }
    }

    @objc private func openControls() {
        showPanel()
        requestRefresh()
    }

    @objc private func openTimeout() {
        showPanel()
        panel.window.makeFirstResponder(panel.minutes)
    }

    @objc private func openSetupInstructions() {
        guard !smokeTest else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        setupPanel.window.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshClicked() {
        requestRegistrationRefresh()
    }

    @objc private func quitClicked() {
        requestQuit()
    }

    private func canWrite(_ setting: PowerSetting) -> Bool {
        let profiles = selectedProfiles(for: setting)
        return !isBusy &&
            !quitPromptOpen &&
            !pendingQuit &&
            currentStatus?.helper.isReady == true &&
            readError == nil &&
            !requiredByLock(setting) &&
            currentStatus?.warnings.isEmpty == true &&
            profiles.count == target.profiles.count &&
            profiles.allSatisfy { $0.actualMinutes != nil && $0.phase?.hasPrefix("pending") != true }
    }

    private func requiredByLock(_ setting: PowerSetting) -> Bool {
        target.profiles.contains { currentStatus?.idleLock?.requires(setting, profile: $0) == true }
    }

    private var canChangeLock: Bool {
        guard !isBusy,
              !quitPromptOpen,
              !pendingQuit,
              readError == nil,
              let lock = currentStatus?.idleLock else { return false }
        return lock.hasManagedChanges ? lock.canRestore : lock.canEnable
    }

    private func selectedProfiles(for setting: PowerSetting) -> [ProfileStatus] {
        currentStatus?.profiles(for: setting).filter { target.profiles.contains($0.profile) } ?? []
    }

    private var managedSettings: [PowerSetting] {
        PowerSetting.allCases.filter { setting in
            currentStatus?.profiles(for: setting).contains { $0.isManaged || $0.phase != nil } == true
        }
    }

    private var canRestoreToQuit: Bool {
        let lock = currentStatus?.idleLock
        let hasLock = lock?.hasManagedChanges == true
        return (!managedSettings.isEmpty || hasLock) &&
            (!hasLock || lock?.canRestore == true) &&
            currentStatus?.helper.isReady == true &&
            readError == nil &&
            currentStatus?.warnings.isEmpty == true &&
            managedSettings.allSatisfy { setting in
                let profiles = currentStatus?.profiles(for: setting).filter { $0.isManaged || $0.phase != nil } ?? []
                return profiles.allSatisfy { $0.actualMinutes != nil && $0.phase?.hasPrefix("pending") != true }
            }
    }

    private func showPanel() {
        guard !smokeTest else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.window.makeKeyAndOrderFront(nil)
    }

    private func requestRefresh() {
        if isBusy || quitPromptOpen {
            pendingRefresh = true
            return
        }
        isBusy = true
        render()
        Task { @MainActor [weak self, worker] in
            let update = await worker.read()
            guard let self else { return }
            self.accept(update)
            self.completedRefreshes += 1
            self.finishWork()
        }
    }

    private func requestRegistrationRefresh() {
        guard let refreshLockRegistration else {
            requestRefresh()
            return
        }
        if isBusy || quitPromptOpen || pendingQuit {
            pendingRegistrationRefresh = true
            return
        }
        isBusy = true
        message = "Refreshing Lock service and current settings…"
        render()
        Task { @MainActor [weak self, worker] in
            let update = await worker.refreshLockRegistration(refreshLockRegistration)
            guard let self else { return }
            self.accept(update.refresh)
            self.completedRefreshes += 1
            if let error = update.error {
                self.reportLockServiceError(error)
            } else {
                self.lockServiceError = nil
                self.message = "Current settings refreshed."
            }
            self.finishWork()
        }
    }

    private func beginAction(action: PowerAction, setting: PowerSetting, minutes: Int? = nil) {
        guard canWrite(setting) else { return }
        do {
            let request = try PowerRequest(action: action, target: target, minutes: minutes, setting: setting)
            isBusy = true
            lastRequest = request
            lastResult = nil
            lastActionSucceeded = nil
            message = presentation.progress(request)
            render()
            Task { @MainActor [weak self, worker] in
                let update = await worker.perform(request)
                guard let self else { return }
                self.acceptAction(update, request: request)
                self.finishWork()
            }
        } catch {
            message = error.localizedDescription
            lastActionSucceeded = false
            actionDetails[setting] = message
            actionFailures.insert(setting)
            finishWork()
        }
    }

    private func beginRestoreAndQuit() {
        guard canRestoreToQuit, let status = currentStatus else {
            pendingQuit = false
            lastActionSucceeded = false
            message = "Hearth is still open. Refresh or repair setup before restoring."
            finishWork()
            return
        }
        let settings = managedSettings
        let names = (status.idleLock?.hasManagedChanges == true ? ["Lock"] : []) + settings.map(\.label)
        let settingNames = names.joined(separator: " and ")
        isBusy = true
        lockWorking = status.idleLock?.hasManagedChanges == true
        lastResult = nil
        lastActionSucceeded = nil
        lastRestoreRequests = []
        message = "Restoring saved \(settingNames) settings…"
        showPanel()
        render()
        Task { @MainActor [weak self, worker] in
            let update = await worker.restoreManagedSettings(status)
            guard let self else { return }
            self.lastRestoreRequests = update.actions.map(\.request)
            self.lastRequest = update.actions.last?.request
            self.lastResult = update.actions.last?.update.result
            self.lastActionSucceeded = update.succeeded
            if let lock = update.lock {
                self.lastLockRequest = IdleLockRequest(action: .restore)
                self.lastLockResult = lock.result
                self.lockFailed = !lock.succeeded
                self.lockDetails = lock.error ?? lock.result?.message ?? lock.refresh.error
            }
            for action in update.actions {
                self.recordAction(action.update, setting: action.request.setting)
            }
            self.accept(update.refresh)
            self.completedRefreshes += update.actions.count + 1
            self.pendingQuit = false
            if update.succeeded {
                self.message = "Saved \(settingNames) settings restored."
                self.finishQuitting()
                return
            }
            self.message = "Hearth is still open. Restoration was not fully confirmed. See Advanced."
            self.finishWork()
        }
    }

    private func accept(_ update: StatusUpdate) {
        readError = update.error
        if let status = update.status {
            currentStatus = status
            if lastRequest == nil && lastLockRequest == nil {
                message = ""
            }
        }
    }

    private func acceptLockAction(_ update: LockActionUpdate) {
        lastLockResult = update.result
        lastActionSucceeded = update.succeeded
        lockFailed = !update.succeeded
        var details = update.result?.message ?? "Lock change not confirmed."
        if let error = update.error { details += "\n" + error }
        if let error = update.refresh.error { details += "\nStatus: " + error }
        lockDetails = details
        accept(update.refresh)
        message = update.succeeded
            ? (lastLockRequest?.action == .restore ? "Lock settings restored. macOS adoption may follow later." : "Lock configured. macOS adoption may follow later.")
            : "Lock change not confirmed. See Advanced."
        completedRefreshes += 1
    }

    private func acceptAction(_ update: ActionUpdate, request: PowerRequest) {
        lastResult = update.result
        lastActionSucceeded = update.succeeded
        recordAction(update, setting: request.setting)
        if update.error != nil {
            message = "\(request.setting.label) change not confirmed. Refresh in Advanced."
        } else if let result = update.result {
            message = presentation.actionSummary(result, request: request)
            currentStatus = result.status
        } else {
            message = "\(request.setting.label) change not confirmed. Refresh in Advanced."
        }
        accept(update.refresh)
        completedRefreshes += 1
    }

    private func recordAction(_ update: ActionUpdate, setting: PowerSetting) {
        var details = update.result.map(presentation.outcomes) ?? "Change not confirmed."
        if let error = update.error {
            details += "\n" + error
        }
        if let result = update.result, !result.status.warnings.isEmpty {
            details += "\n\nAction warnings\n" + result.status.warnings.joined(separator: "\n")
        }
        if let error = update.refresh.error {
            details += "\nStatus: \(error)"
        }
        actionDetails[setting] = details
        if update.succeeded {
            actionFailures.remove(setting)
        } else {
            actionFailures.insert(setting)
        }
    }

    private func finishWork() {
        isBusy = false
        lockWorking = false
        render()
        if pendingQuit {
            pendingQuit = false
            requestQuit()
        } else if pendingRegistrationRefresh {
            pendingRegistrationRefresh = false
            requestRegistrationRefresh()
        } else if pendingRefresh {
            pendingRefresh = false
            pendingRegistrationRefresh = false
            requestRefresh()
        }
    }

    func requestQuit() {
        guard !quitPromptOpen else { return }
        if isBusy {
            pendingQuit = true
            renderControls()
            return
        }
        isBusy = true
        message = "Checking saved settings before quitting…"
        render()
        Task { @MainActor [weak self, worker] in
            let update = await worker.read()
            guard let self else { return }
            self.accept(update)
            self.completedRefreshes += 1
            self.isBusy = false
            if update.busy {
                self.pendingQuit = false
                self.message = "Hearth is still open. A change is in progress; wait before quitting."
                self.render()
                return
            }
            let canQuitWithoutPrompt = update.status?.hasManagedChanges == false &&
                update.status?.warnings.isEmpty == true &&
                update.error == nil
            if canQuitWithoutPrompt {
                self.finishQuitting()
                return
            }
            self.presentQuitChoice()
        }
    }

    private func presentQuitChoice() {
        quitPromptOpen = true
        render()
        if smokeTest {
            resolveQuit(smokeQuitChoice)
            return
        }
        showPanel()
        let alert = NSAlert()
        alert.messageText = "What should Hearth do before quitting?"
        alert.informativeText = "Keep settings leaves Lock, System, and Display as they are. Restore and quit first restores Lock, then all other settings saved by Hearth, regardless of the selected power source. If restoration cannot be confirmed, Hearth stays open."
        let canRestore = canRestoreToQuit
        if !canRestore {
            alert.informativeText += "\n\nRestoration is unavailable. Cancel to refresh status or review setup / repair."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep settings")
        alert.addButton(withTitle: "Restore and quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].isEnabled = canRestore
        alert.buttons[2].keyEquivalent = "\r"
        alert.beginSheetModal(for: panel.window) { [weak self] response in
            let choice: QuitChoice
            switch response {
            case .alertFirstButtonReturn: choice = .keepSettings
            case .alertSecondButtonReturn: choice = .restoreAndQuit
            default: choice = .cancel
            }
            self?.resolveQuit(choice)
        }
    }

    private func resolveQuit(_ choice: QuitChoice) {
        quitPromptOpen = false
        switch choice {
        case .keepSettings:
            finishQuitting()
        case .restoreAndQuit:
            pendingQuit = false
            beginRestoreAndQuit()
        case .cancel:
            pendingQuit = false
            message = "Quit cancelled. No restoration was requested."
            finishWork()
        }
    }

    private func finishQuitting() {
        isBusy = false
        lockWorking = false
        pendingQuit = false
        pendingRefresh = false
        render()
        onTermination()
    }

    private func render() {
        let source = currentStatus.map { "Current power source: \($0.currentSource)" } ?? "Power source unavailable"
        sourceItem.title = readError == nil ? source : "Status read failed — values below are last known"
        sourceItem.isEnabled = false
        panel.currentSource.stringValue = sourceItem.title
        helperItem.title = readError == nil
            ? presentation.helperSummary(currentStatus?.helper)
            : "Helper: Status unconfirmed — refresh before making changes"
        helperItem.toolTip = currentStatus?.helper.message
        panel.helperStatus.stringValue = helperItem.title
        panel.helperStatus.toolTip = helperItem.toolTip
        let warnings = currentStatus?.warnings ?? []
        for profile in PowerProfile.allCases {
            let status = currentStatus?.profiles(for: setting).first { $0.profile == profile }
            let actual = "\(setting.label) · \(profile.label): \(presentation.timeout(status?.actualMinutes, setting: setting))"
            let ownershipUnconfirmed = status?.isManaged != true &&
                status?.phase == nil &&
                !warnings.isEmpty
            var ownership = ownershipUnconfirmed
                ? "Saved settings are uncertain. Review the warnings."
                : presentation.ownership(status)
            if currentStatus?.idleLock?.requires(setting, profile: profile) == true {
                let dependency = currentStatus?.idleLock?.dependencies.first { $0.setting == setting && $0.profile == profile }
                let instruction = currentStatus?.idleLock?.phase == .uncertain
                    ? "Blocked while Lock completion is unconfirmed. "
                    : "Required by Lock. Use Restore Lock. "
                ownership = instruction +
                    (dependency?.acquired == true ? "Acquired by Lock. " : "Borrowed; pre-existing settings retained. ") + ownership
            }
            profileItems[profile]?.0.title = actual
            profileItems[profile]?.0.isEnabled = false
            profileItems[profile]?.1.title = ownership
            profileItems[profile]?.1.isEnabled = false
            panel.actualLabels[profile]?.stringValue = actual
            panel.ownershipLabels[profile]?.stringValue = ownership
        }
        let displayedMessage = readError == nil ? message : "Status refresh failed. Values shown may be out of date."
        summaryItem.title = presentation.compactStatus(currentStatus, setting: .system, target: target, unavailable: readError != nil)
        displaySummaryItem.title = presentation.compactStatus(currentStatus, setting: .display, target: target, unavailable: readError != nil)
        lockSummaryItem.title = lockWorking
            ? "Lock · Configuration in progress"
            : presentation.lockSummary(currentStatus?.idleLock, unavailable: readError != nil)
        lockSummaryItem.toolTip = currentStatus?.idleLock?.message
        panel.lockStatus.stringValue = lockSummaryItem.title
        panel.lockStatus.toolTip = lockSummaryItem.toolTip
        let readiness = currentStatus?.helper.isReady == false ? "Setup or repair needed. See Advanced." : ""
        activityItem.title = isBusy ? "Working…" : (readError == nil ? (message.isEmpty ? readiness : message) : "Status unavailable. Refresh in Advanced.")
        activityItem.isHidden = !isBusy && readError == nil && activityItem.title.isEmpty
        activityItem.toolTip = displayedMessage
        panel.activity.stringValue = displayedMessage

        var sections: [String] = []
        if let readError {
            sections.append("Status error: \(readError)\nUse Refresh to retry. No restore values will be guessed.")
        }
        if !warnings.isEmpty {
            sections.append("Warnings\n" + warnings.joined(separator: "\n"))
        }
        if let helper = currentStatus?.helper,
           !helper.isReady {
            sections.append("Helper\n\(helper.message)\nPower changes are disabled. Actual settings and Refresh remain available. Open Setup / repair instructions for the explicit installation workflow.")
        }
        if let lock = currentStatus?.idleLock {
            var details = ["Lock", lockSummaryItem.title, lock.message,
                           "Current user · all sources · keeps System/Display awake",
                           presentation.lockTimingDisclosure,
                           "Effective screen-saver idle delay: \(lock.saverDelaySeconds.map { "\($0) seconds" } ?? "unavailable")."]
            if let original = lock.originalSaverDelaySeconds {
                details.append("Saved effective screen-saver idle delay: \(original) seconds.")
            }
            if let guidance = lock.recoveryGuidance { details.append(guidance) }
            sections.append(details.joined(separator: "\n"))
        }
        if let lockDetails {
            sections.append("Lock \(lockFailed ? "action — not confirmed" : "— last action")\n\(lockDetails)")
        }
        if let lockServiceError {
            sections.append("CLI/web Lock service\n\(lockServiceError)\nNative controls use the local Lock service. Use Refresh to retry registration.")
        }
        for setting in PowerSetting.allCases {
            if let details = actionDetails[setting] {
                let heading = actionFailures.contains(setting) ? "\(setting.label) action — not confirmed" : "\(setting.label) — last action"
                sections.append("\(heading)\n\(details)")
            }
        }
        panel.details.string = sections.isEmpty ? "No reported warnings." : sections.joined(separator: "\n\n")
        warningsItem.isHidden = warnings.isEmpty &&
            readError == nil &&
            lastActionSucceeded != false &&
            actionFailures.isEmpty &&
            !lockFailed &&
            lockServiceError == nil
        let failedSettings = PowerSetting.allCases.filter { actionFailures.contains($0) }.map(\.label).joined(separator: " and ")
        warningsItem.title = failedSettings.isEmpty ? "Show diagnostic details…" : "\(failedSettings) action needs attention…"
        statusItem.button?.toolTip = [sourceItem.title, summaryItem.title, displaySummaryItem.title, lockSummaryItem.title, helperItem.title].joined(separator: "\n")
        renderControls()
    }

    private func renderControls() {
        for (setting, item) in [(PowerSetting.system, preventItem), (.display, displayItem)] {
            let profiles = selectedProfiles(for: setting)
            let managed = profiles.contains(where: \.isManaged)
            let alreadyNever = !profiles.isEmpty && profiles.allSatisfy { $0.actualMinutes == 0 }
            item.title = managed ? "Restore \(setting.rawValue) settings" : "Keep \(setting.rawValue) awake"
            if requiredByLock(setting) { item.title = "\(setting.label) · Required by Lock" }
            item.isEnabled = canWrite(setting) && (managed || !alreadyNever)
            item.toolTip = requiredByLock(setting)
                ? (currentStatus?.idleLock?.phase == .uncertain
                   ? "Lock completion is unconfirmed. See Advanced for recovery diagnostics; changes are blocked."
                   : "Use Restore Lock first. Pre-existing overrides are kept.")
                : "Only \(setting.label) on \(presentation.targetName(target))."
        }
        let profiles = selectedProfiles(for: setting)
        let managed = profiles.contains(where: \.isManaged)
        let alreadyNever = !profiles.isEmpty && profiles.allSatisfy { $0.actualMinutes == 0 }
        let writable = canWrite(setting)
        restoreItem.title = "Restore \(setting.rawValue) settings"
        timeoutItem.title = "Set \(setting.rawValue) timeout…"
        restoreItem.isEnabled = writable && managed
        panel.prevent.title = "Keep \(setting.rawValue) awake"
        panel.restore.title = restoreItem.title
        panel.setTimeout.title = "Set \(setting.rawValue) timeout"
        panel.prevent.isEnabled = writable && !alreadyNever
        panel.restore.isEnabled = restoreItem.isEnabled
        panel.setTimeout.isEnabled = writable && !panel.minutes.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        panel.minutes.isEnabled = writable
        panel.minutes.setAccessibilityLabel("\(setting.label) sleep timeout in minutes")
        panel.target.isEnabled = !isBusy && !quitPromptOpen && !pendingQuit
        panel.setting.isEnabled = panel.target.isEnabled
        let targets: [PowerTarget] = [.both, .battery, .adapter]
        for (index, item) in targetItems.enumerated() {
            item.state = targets[index] == target ? .on : .off
            item.isEnabled = panel.target.isEnabled
        }
        panel.target.selectItem(at: targets.firstIndex(of: target) ?? 0)
        for (index, item) in settingItems.enumerated() {
            item.state = PowerSetting.allCases[index] == setting ? .on : .off
            item.isEnabled = panel.setting.isEnabled
        }
        panel.setting.selectItem(at: PowerSetting.allCases.firstIndex(of: setting) ?? 0)
        lockItem.title = currentStatus?.idleLock?.hasManagedChanges == true ? "Restore Lock" : "Prevent idle lock"
        lockItem.isEnabled = canChangeLock
        lockItem.toolTip = "Current user · keeps System and Display awake on all available power profiles."
        panel.lockAction.title = lockItem.title
        panel.lockAction.isEnabled = lockItem.isEnabled
        refreshItem.isEnabled = !isBusy && !quitPromptOpen
        panel.refresh.isEnabled = refreshItem.isEnabled
        quitItem.isEnabled = !quitPromptOpen
        timeoutItem.isEnabled = writable
        setupItem.isEnabled = !quitPromptOpen
        panel.setup.isEnabled = setupItem.isEnabled
    }
}
