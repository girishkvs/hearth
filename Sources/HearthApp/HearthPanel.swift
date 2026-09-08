import AppKit
import HearthCore

// Native system controls keep actual settings and restore ownership separate.
@MainActor
final class HearthPanel {
    let window: NSPanel
    let target = NSPopUpButton()
    let prevent = NSButton(title: "Prevent idle sleep", target: nil, action: nil)
    let restore = NSButton(title: "Restore previous settings", target: nil, action: nil)
    let minutes = NSTextField()
    let setTimeout = NSButton(title: "Set sleep timeout", target: nil, action: nil)
    let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    let setup = NSButton(title: "Setup / repair instructions…", target: nil, action: nil)
    let currentSource = NSTextField(labelWithString: "Reading power settings…")
    let helperStatus = NSTextField(wrappingLabelWithString: "Helper: Not yet checked")
    let activity = NSTextField(wrappingLabelWithString: "Reading power settings…")
    let details = NSTextView()
    let displayNote = NSTextField(labelWithString: "Display may still turn off.")
    private(set) var actualLabels: [PowerProfile: NSTextField] = [:]
    private(set) var ownershipLabels: [PowerProfile: NSTextField] = [:]

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 570, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hearth Advanced"
        window.minSize = NSSize(width: 530, height: 780)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()

        let content = NSView()
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
        ])

        let title = NSTextField(labelWithString: "Idle sleep settings")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)
        currentSource.textColor = .secondaryLabelColor
        add(currentSource, to: stack)
        stack.setCustomSpacing(20, after: currentSource)

        for profile in PowerProfile.allCases {
            let actual = NSTextField(wrappingLabelWithString: "\(profile.label): Reading…")
            actual.font = .systemFont(ofSize: 13, weight: .semibold)
            let ownership = NSTextField(wrappingLabelWithString: "Restore information unavailable.")
            ownership.textColor = .secondaryLabelColor
            ownership.font = .systemFont(ofSize: 12)
            ownership.isSelectable = true
            add(actual, to: stack)
            stack.setCustomSpacing(4, after: actual)
            add(ownership, to: stack)
            actualLabels[profile] = actual
            ownershipLabels[profile] = ownership
        }

        add(separator(), to: stack)
        helperStatus.font = .systemFont(ofSize: 13, weight: .medium)
        helperStatus.isSelectable = true
        helperStatus.setAccessibilityLabel("Helper status")
        add(helperStatus, to: stack)
        target.addItems(withTitles: ["Both", "Battery", "Power adapter"])
        target.setAccessibilityLabel("Power target")
        target.toolTip = "Choose which power profiles the action affects."
        let targetRow = NSStackView(views: [NSTextField(labelWithString: "Power target:"), target])
        targetRow.spacing = 10
        stack.addArrangedSubview(targetRow)

        for button in [prevent, restore, setTimeout, refresh, setup] {
            button.bezelStyle = .rounded
        }
        let actions = NSStackView(views: [prevent, restore])
        actions.spacing = 8
        stack.addArrangedSubview(actions)

        minutes.placeholderString = "Minutes"
        minutes.setAccessibilityLabel("Sleep timeout in minutes")
        minutes.toolTip = "A positive whole number. This becomes your new setting and clears the selected restore record after success."
        minutes.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let timeoutRow = NSStackView(views: [minutes, NSTextField(labelWithString: "minutes"), setTimeout])
        timeoutRow.spacing = 8
        stack.addArrangedSubview(timeoutRow)

        let timeoutNote = NSTextField(wrappingLabelWithString: "Set sleep timeout saves a new setting, not a temporary override.")
        timeoutNote.font = .systemFont(ofSize: 12)
        timeoutNote.textColor = .secondaryLabelColor
        add(timeoutNote, to: stack)
        add(displayNote, to: stack)
        let limits = NSTextField(wrappingLabelWithString: "Lid closure, manual sleep, and system safety behavior are unchanged. Closing this window does not restore settings.")
        limits.font = .systemFont(ofSize: 12)
        limits.textColor = .secondaryLabelColor
        add(limits, to: stack)
        add(separator(), to: stack)

        activity.font = .systemFont(ofSize: 13, weight: .medium)
        activity.setAccessibilityLabel("Operation status")
        add(activity, to: stack)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        details.isEditable = false
        details.isSelectable = true
        details.font = .systemFont(ofSize: 12)
        details.textColor = .labelColor
        details.backgroundColor = .textBackgroundColor
        details.textContainerInset = NSSize(width: 8, height: 8)
        details.isVerticallyResizable = true
        details.isHorizontallyResizable = false
        details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        details.setAccessibilityLabel("Operation details and warnings")
        scroll.documentView = details
        add(scroll, to: stack)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 105).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let footer = NSStackView(views: [refresh, setup])
        footer.spacing = 8
        stack.addArrangedSubview(footer)
    }

    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
