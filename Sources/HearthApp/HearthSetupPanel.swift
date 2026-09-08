import AppKit

@MainActor
final class HearthSetupPanel {
    let window: NSPanel
    let instructions = NSTextView()

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hearth — Setup / repair instructions"
        window.minSize = NSSize(width: 460, height: 360)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()
        let content = NSView()
        window.contentView = content
        instructions.string = HearthPresentation().setupInstructions
        instructions.isEditable = false
        instructions.isSelectable = true
        instructions.font = .systemFont(ofSize: 13)
        instructions.textColor = .labelColor
        instructions.backgroundColor = .windowBackgroundColor
        instructions.isVerticallyResizable = true
        instructions.isHorizontallyResizable = false
        instructions.autoresizingMask = [.width]
        instructions.textContainer?.widthTracksTextView = true
        instructions.setAccessibilityLabel("Setup and repair instructions")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = instructions
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
    }
}
