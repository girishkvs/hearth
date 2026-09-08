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
    let preventItem = NSMenuItem(title: "Prevent idle sleep", action: nil, keyEquivalent: "")
    let restoreItem = NSMenuItem(title: "Restore previous settings", action: nil, keyEquivalent: "")
    let timeoutItem = NSMenuItem(title: "Set sleep timeout…", action: nil, keyEquivalent: "")
    let quitItem = NSMenuItem(title: "Quit Hearth…", action: nil, keyEquivalent: "q")
    private(set) var targetItems: [NSMenuItem] = []
    private(set) var target: PowerTarget = .both
    private(set) var currentStatus: HearthStatus?
    private(set) var lastResult: OperationResult?
    private(set) var lastActionSucceeded: Bool?
    private(set) var lastRequest: PowerRequest?
    private(set) var message = "Reading power settings…"
    private(set) var completedRefreshes = 0
    private(set) var isBusy = false
    var smokeQuitChoice: QuitChoice = .cancel

    private let worker: HearthWorker
    private let smokeTest: Bool
    private let onTermination: @MainActor () -> Void
    private let presentation = HearthPresentation()
    private let statusItem: NSStatusItem
    private let sourceItem = NSMenuItem(title: "Reading power settings…", action: nil, keyEquivalent: "")
    private let summaryItem = NSMenuItem(title: "Checking settings…", action: nil, keyEquivalent: "")
    private let activityItem = NSMenuItem(title: "Reading power settings…", action: nil, keyEquivalent: "")
    private let warningsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh", action: nil, keyEquivalent: "")
    private var profileItems: [PowerProfile: (NSMenuItem, NSMenuItem)] = [:]
    private var periodicRefresh: Task<Void, Never>?
    private var pendingRefresh = false
    private var pendingQuit = false
    private var quitPromptOpen = false
    private var readError: String?
    private var operationDetails = ""

    init(service: HearthService, smokeTest: Bool = false, onTermination: @escaping @MainActor () -> Void) {
        worker = HearthWorker(service: service)
        self.smokeTest = smokeTest
        self.onTermination = onTermination
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
        connect(preventItem, action: #selector(primaryAction))
        activityItem.isEnabled = false
        menu.addItem(activityItem)
        connect(warningsItem, action: #selector(openControls))
        menu.addItem(.separator())
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advanced.submenu = advancedMenu
        menu.addItem(advanced)
        advancedMenu.addItem(sourceItem)
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
        let note = NSMenuItem(title: "Display can turn off.", action: nil, keyEquivalent: "")
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
    }

    @objc private func selectTarget(_ sender: Any) {
        guard !isBusy && !quitPromptOpen else { return }
        let index = (sender as? NSMenuItem)?.tag ?? panel.target.indexOfSelectedItem
        let targets: [PowerTarget] = [.both, .battery, .adapter]
        guard targets.indices.contains(index) else { return }
        target = targets[index]
        render()
    }

    @objc private func primaryAction() {
        beginAction(action: selectedProfiles.contains(where: \.isManaged) ? .restore : .on)
    }

    @objc private func preventIdleSleep() {
        beginAction(action: .on)
    }

    @objc private func restorePreviousSettings() {
        beginAction(action: .restore)
    }

    @objc private func setSleepTimeout() {
        guard canWrite else { return }
        do {
            let minutes = try presentation.minutes(panel.minutes.stringValue)
            beginAction(action: .sleep, minutes: minutes)
        } catch {
            message = error.localizedDescription
            lastActionSucceeded = false
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
        requestRefresh()
    }

    @objc private func quitClicked() {
        requestQuit()
    }

    private var canWrite: Bool {
        !isBusy &&
            !quitPromptOpen &&
            !pendingQuit &&
            currentStatus?.helper.isReady == true &&
            readError == nil &&
            currentStatus?.warnings.isEmpty == true &&
            currentStatus?.profiles.contains(where: { $0.phase?.hasPrefix("pending") == true }) == false &&
            !selectedProfiles.isEmpty &&
            selectedProfiles.allSatisfy { $0.actualMinutes != nil && $0.phase?.hasPrefix("pending") != true }
    }

    private var selectedProfiles: [ProfileStatus] {
        currentStatus?.profiles.filter { target.profiles.contains($0.profile) } ?? []
    }

    private var canRestoreToQuit: Bool {
        currentStatus?.helper.isReady == true &&
            readError == nil &&
            currentStatus?.warnings.isEmpty == true &&
            currentStatus?.profiles.allSatisfy { $0.actualMinutes != nil && $0.phase?.hasPrefix("pending") != true } == true
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

    private func beginAction(action: PowerAction, minutes: Int? = nil, restoringToQuit: Bool = false) {
        guard restoringToQuit || canWrite else { return }
        if restoringToQuit {
            guard canRestoreToQuit else {
                pendingQuit = false
                lastActionSucceeded = false
                message = "Hearth is still open. Restoration needs a ready helper and current status. Review setup / repair instructions, then Refresh. Keep settings can still quit without restoring."
                finishWork()
                return
            }
        }
        do {
            let request = try PowerRequest(action: action, target: restoringToQuit ? .both : target, minutes: minutes)
            isBusy = true
            lastRequest = request
            lastResult = nil
            lastActionSucceeded = nil
            operationDetails = ""
            message = restoringToQuit
                ? "Restoring battery and power adapter settings before quitting…"
                : presentation.progress(request)
            if restoringToQuit { showPanel() }
            render()
            Task { @MainActor [weak self, worker] in
                let update = await worker.perform(request)
                guard let self else { return }
                self.acceptAction(update, request: request)
                if restoringToQuit {
                    let safeToQuit = update.result?.succeeded == true &&
                        update.refresh.status?.hasManagedChanges == false &&
                        update.refresh.status?.warnings.isEmpty == true &&
                        update.refresh.error == nil
                    if safeToQuit {
                        self.finishQuitting()
                        return
                    }
                    self.message = "Hearth is still open. Restoration was not fully confirmed, or restore records or warnings remain."
                    self.pendingQuit = false
                }
                self.finishWork()
            }
        } catch {
            message = error.localizedDescription
            lastActionSucceeded = false
            finishWork()
        }
    }

    private func accept(_ update: StatusUpdate) {
        readError = update.error
        if let status = update.status {
            currentStatus = status
            if lastRequest == nil {
                message = ""
            }
        }
    }

    private func acceptAction(_ update: ActionUpdate, request: PowerRequest) {
        lastResult = update.result
        lastActionSucceeded = update.result?.succeeded == true &&
            update.error == nil &&
            update.refresh.error == nil
        if let error = update.error {
            message = "Change not confirmed. Refresh status in Advanced."
            operationDetails = error
        } else if let result = update.result {
            message = presentation.actionSummary(result, request: request)
            operationDetails = presentation.outcomes(result)
            if !result.status.warnings.isEmpty {
                operationDetails += "\n\nAction warnings\n" + result.status.warnings.joined(separator: "\n")
            }
            currentStatus = result.status
        } else {
            message = "Change not confirmed. Refresh status in Advanced."
        }
        accept(update.refresh)
        completedRefreshes += 1
    }

    private func finishWork() {
        isBusy = false
        render()
        if pendingQuit {
            pendingQuit = false
            requestQuit()
        } else if pendingRefresh {
            pendingRefresh = false
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
        message = "Checking restore records before quitting…"
        render()
        Task { @MainActor [weak self, worker] in
            let update = await worker.read()
            guard let self else { return }
            self.accept(update)
            self.completedRefreshes += 1
            self.isBusy = false
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
        alert.informativeText = "Hearth has managed or pending records, or could not confirm their state. Keep settings quits without changing anything. Restore and quit attempts both power profiles and quits only after successful, verified restoration with no remaining records or warnings."
        let canRestore = canRestoreToQuit
        if !canRestore {
            alert.informativeText += "\n\nRestoration is unavailable until the helper is ready and status is current. Cancel to review setup / repair instructions and Refresh, or Keep settings to quit without restoring."
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
            beginAction(action: .restore, restoringToQuit: true)
        case .cancel:
            pendingQuit = false
            message = "Quit cancelled. No restoration was requested."
            finishWork()
        }
    }

    private func finishQuitting() {
        isBusy = false
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
            let status = currentStatus?.profiles.first { $0.profile == profile }
            let actual = "\(profile.label): \(presentation.timeout(status?.actualMinutes))"
            let ownershipUnconfirmed = status?.isManaged != true &&
                status?.phase == nil &&
                !warnings.isEmpty
            let ownership = ownershipUnconfirmed
                ? "Restore ownership is uncertain. Review the warnings; no baseline will be guessed."
                : presentation.ownership(status)
            profileItems[profile]?.0.title = actual
            profileItems[profile]?.0.isEnabled = false
            profileItems[profile]?.1.title = ownership
            profileItems[profile]?.1.isEnabled = false
            panel.actualLabels[profile]?.stringValue = actual
            panel.ownershipLabels[profile]?.stringValue = ownership
        }
        let displayedMessage = readError == nil ? message : "Status refresh failed. Values shown may be out of date."
        summaryItem.title = presentation.compactStatus(currentStatus, target: target, unavailable: readError != nil)
        activityItem.title = isBusy ? "Working…" : (readError == nil ? message : "Status unavailable. Refresh in Advanced.")
        activityItem.isHidden = !isBusy && readError == nil && message.isEmpty
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
        if !operationDetails.isEmpty {
            sections.append("Last action\n" + operationDetails)
        }
        panel.details.string = sections.isEmpty ? "No reported warnings. Review the actual values and restore information above before choosing an action." : sections.joined(separator: "\n\n")
        warningsItem.isHidden = warnings.isEmpty && readError == nil && lastActionSucceeded != false
        warningsItem.title = "Show diagnostic details…"
        statusItem.button?.toolTip = ([sourceItem.title, helperItem.title] + PowerProfile.allCases.compactMap { profileItems[$0]?.0.title }).joined(separator: "\n")
        renderControls()
    }

    private func renderControls() {
        let managed = selectedProfiles.contains(where: \.isManaged)
        let alreadyNever = !selectedProfiles.isEmpty && selectedProfiles.allSatisfy { $0.actualMinutes == 0 }
        preventItem.title = managed ? "Restore previous settings" : "Keep awake"
        preventItem.isEnabled = canWrite && (managed || !alreadyNever)
        restoreItem.isEnabled = canWrite
        panel.prevent.isEnabled = canWrite
        panel.restore.isEnabled = canWrite
        panel.setTimeout.isEnabled = canWrite && !panel.minutes.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        panel.minutes.isEnabled = canWrite
        panel.target.isEnabled = !isBusy && !quitPromptOpen && !pendingQuit
        let targets: [PowerTarget] = [.both, .battery, .adapter]
        for (index, item) in targetItems.enumerated() {
            item.state = targets[index] == target ? .on : .off
            item.isEnabled = panel.target.isEnabled
        }
        panel.target.selectItem(at: targets.firstIndex(of: target) ?? 0)
        refreshItem.isEnabled = !isBusy && !quitPromptOpen
        panel.refresh.isEnabled = refreshItem.isEnabled
        quitItem.isEnabled = !quitPromptOpen
        timeoutItem.isEnabled = canWrite
        setupItem.isEnabled = !quitPromptOpen
        panel.setup.isEnabled = setupItem.isEnabled
    }
}
