import AppKit
import HearthCore

private struct DocumentationCaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Captures only this isolated app's real primary menu and Advanced content views.
@MainActor
final class HearthDocumentationCapture: NSObject {
    private var trackedMenu: NSMenu?
    private var visibleBeforeTracking: Set<ObjectIdentifier> = []
    private var menuBitmap: NSBitmapImageRep?
    private var menuFailure: Error?

    func run(outputDirectory: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HearthApp-docs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        // Both the runner and the restore journal are isolated from the installed app.
        let runner = SmokePowerRunner()
        runner.changeExternally(.adapter, minutes: 10)
        let saver = SmokeScreenSaver(storedValue: .absent)
        let lock = IdleLockService(runner: runner, screenSaver: saver, stateDirectory: directory)
        let app = HearthAppController(
            service: HearthService(runner: runner, stateDirectory: directory, idleLockController: lock),
            smokeTest: true,
            onTermination: {}
        )
        defer {
            app.menu.cancelTracking()
            app.stop()
            app.panel.window.close()
            app.setupPanel.window.close()
        }
        app.start()
        try await settle(app)
        guard app.currentStatus != nil,
              runner.writeCount == 0,
              app.preventItem.title == "Keep system awake",
              app.displayItem.title == "Keep display awake",
              app.lockItem.title == "Prevent idle lock",
              app.menu.items.contains(where: { $0.submenu === app.advancedMenu }) else {
            throw DocumentationCaptureFailure(message: "The actual native menu did not reach the expected sample state.")
        }

        let appearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        defer { NSApplication.shared.appearance = appearance }
        let defaultBitmap = try capture(app.panel)
        let defaultMenuBitmap = try await capturePrimaryMenu(app.menu)

        // This existing menu action is connected only to the fake runner above.
        app.menu.performActionForItem(at: app.menu.index(of: app.preventItem))
        try await settle(app)
        guard runner.writeCount == 1,
              app.currentStatus?.hasManagedChanges == true,
              app.preventItem.title == "Restore system settings",
              runner.writes(for: .display).isEmpty else {
            throw DocumentationCaptureFailure(message: "The actual native menu did not reach the expected managed sample state.")
        }
        app.menu.performActionForItem(at: app.menu.index(of: app.displayItem))
        try await settle(app)
        guard runner.writeCount == 2,
              app.preventItem.title == "Restore system settings",
              app.displayItem.title == "Restore display settings" else {
            throw DocumentationCaptureFailure(message: "Both independent sample controls did not become managed.")
        }
        let displayChoice = app.settingItems[1]
        guard let settingMenu = displayChoice.menu else {
            throw DocumentationCaptureFailure(message: "The actual Display setting menu is unavailable.")
        }
        settingMenu.performActionForItem(at: settingMenu.index(of: displayChoice))
        app.menu.performActionForItem(at: app.menu.index(of: app.preventItem))
        try await settle(app)
        guard runner.writeCount == 3,
              app.preventItem.title == "Keep system awake",
              app.displayItem.title == "Restore display settings",
              app.currentStatus?.profiles.allSatisfy({ !$0.isManaged }) == true,
              app.currentStatus?.displayProfiles.allSatisfy(\.isManaged) == true else {
            throw DocumentationCaptureFailure(message: "Restoring sample System settings affected independent Display ownership.")
        }
        let displayActiveBitmap = try capture(app.panel)
        app.menu.performActionForItem(at: app.menu.index(of: app.lockItem))
        try await settle(app)
        guard app.currentStatus?.idleLock?.phase == .active,
              app.lockItem.title == "Restore Lock",
              app.preventItem.title.contains("Required by Lock"),
              app.displayItem.title.contains("Required by Lock"),
              app.panel.lockStatus.stringValue == "Lock · Configured" else {
            throw DocumentationCaptureFailure(message: "The isolated coordinated Lock sample did not become configured.")
        }
        guard app.menu.size.width <= 500 else {
            throw DocumentationCaptureFailure(message: "The sample Lock menu expanded beyond its compact width.")
        }
        let configuredMenuBitmap = try await capturePrimaryMenu(app.menu)
        app.menu.performActionForItem(at: app.menu.index(of: app.lockItem))
        try await settle(app)
        guard try saver.observe().configuration?.storedValue == .absent else {
            throw DocumentationCaptureFailure(message: "The isolated Lock sample did not restore exact timer absence.")
        }
        saver.configure(readFailure: "Synthetic preference synchronization failure.")
        app.pollStatus()
        try await settle(app)
        guard app.currentStatus?.idleLock?.phase == .unavailable,
              !app.lockItem.isEnabled,
              app.preventItem.isEnabled,
              app.displayItem.isEnabled else {
            throw DocumentationCaptureFailure(message: "Preference failure did not retain independent controls.")
        }
        let unavailableBitmap = try capture(app.panel)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try write(defaultMenuBitmap, to: outputDirectory.appendingPathComponent("native-menu-default.png"))
        try write(configuredMenuBitmap, to: outputDirectory.appendingPathComponent("native-menu-lock-configured.png"))
        try write(defaultBitmap, to: outputDirectory.appendingPathComponent("native-controls-default.png"))
        try write(displayActiveBitmap, to: outputDirectory.appendingPathComponent("native-controls-display-active.png"))
        try write(unavailableBitmap, to: outputDirectory.appendingPathComponent("native-controls-lock-unavailable.png"))
    }

    private func settle(_ app: HearthAppController) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while app.isBusy {
            guard clock.now < deadline else {
                throw DocumentationCaptureFailure(message: "Timed out reading isolated sample status.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func write(_ bitmap: NSBitmapImageRep, to output: URL) throws {
        let opaque = try withSystemBackground(bitmap)
        guard let png = opaque.representation(using: .png, properties: [:]) else {
            throw DocumentationCaptureFailure(message: "AppKit could not encode the native control pixels.")
        }
        guard png.count < 500_000 else {
            throw DocumentationCaptureFailure(message: "Native control capture exceeded the documentation image size limit.")
        }
        let pixelsOnly = try removingMetadata(png)
        try pixelsOnly.write(to: output, options: .atomic)
        print("Captured \(output.lastPathComponent) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh), \(pixelsOnly.count) bytes); isolated sample data.")
    }

    private func withSystemBackground(_ source: NSBitmapImageRep) throws -> NSBitmapImageRep {
        // Keep the actual native control pixels on a solid system-color canvas.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: source.pixelsWide,
            pixelsHigh: source.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap),
           let image = source.cgImage else {
            throw DocumentationCaptureFailure(message: "Could not create the native controls' opaque pixel canvas.")
        }
        let bounds = NSRect(x: 0, y: 0, width: source.pixelsWide, height: source.pixelsHigh)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.cgContext.fill(bounds)
            context.cgContext.draw(image, in: bounds)
        }
        return bitmap
    }

    private func removingMetadata(_ png: Data) throws -> Data {
        // AppKit adds EXIF/resolution/color-profile chunks even with empty properties.
        // Keep only the required true-color PNG chunks; their bytes and CRCs stay intact.
        var result = Data(png.prefix(8))
        var offset = 8
        while offset + 12 <= png.count {
            let length = png[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let end = offset + 12 + length
            guard end <= png.count else {
                throw DocumentationCaptureFailure(message: "AppKit returned an invalid PNG chunk.")
            }
            let name = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if ["IHDR", "IDAT", "IEND"].contains(name) {
                result.append(png[offset..<end])
            }
            offset = end
        }
        guard offset == png.count else {
            throw DocumentationCaptureFailure(message: "AppKit returned incomplete PNG data.")
        }
        return result
    }

    private func capture(_ panel: HearthPanel) throws -> NSBitmapImageRep {
        guard let view = panel.window.contentView,
              view.bounds.width > 100,
              view.bounds.height > 50 else {
            throw DocumentationCaptureFailure(message: "The actual native Advanced content view is unavailable.")
        }
        panel.window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw DocumentationCaptureFailure(message: "The native controls do not support AppKit bitmap caching.")
        }
        panel.window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        return bitmap
    }

    private func capturePrimaryMenu(_ menu: NSMenu) async throws -> NSBitmapImageRep {
        let application = NSApplication.shared
        application.activate(ignoringOtherApps: true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !application.isActive {
            guard clock.now < deadline else {
                throw DocumentationCaptureFailure(
                    message: "The isolated sample app (PID \(ProcessInfo.processInfo.processIdentifier)) did not become active. Actual primary-menu capture needs a foreground GUI context; no screen capture, input event or permission request was attempted."
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        trackedMenu = menu
        visibleBeforeTracking = Set(application.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        menuBitmap = nil
        menuFailure = nil
        let delegate = menu.delegate
        menu.delegate = nil
        let timer = Timer(timeInterval: 0.8, target: self, selector: #selector(captureTrackedMenu), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer {
            timer.invalidate()
            menu.cancelTracking()
            menu.delegate = delegate
            trackedMenu = nil
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let mouse = NSEvent.mouseLocation
        let x = mouse.x < screen.midX ? screen.maxX - menu.size.width - 40 : screen.minX + 40
        let started = ProcessInfo.processInfo.systemUptime
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: screen.maxY - 60), in: nil)
        if let menuFailure { throw menuFailure }
        guard let menuBitmap else {
            throw DocumentationCaptureFailure(
                message: "The actual sample menu closed after \(ProcessInfo.processInfo.systemUptime - started) seconds before its own-view capture ran (sample active: \(application.isActive)). No image was written."
            )
        }
        return menuBitmap
    }

    @objc private func captureTrackedMenu() {
        defer { trackedMenu?.cancelTracking() }
        let windows = NSApplication.shared.windows.filter {
            $0.isVisible && !visibleBeforeTracking.contains(ObjectIdentifier($0)) &&
                $0.level == .popUpMenu && $0.contentView != nil
        }
        guard windows.count == 1, let view = windows.first?.contentView,
              view.bounds.width > 100, view.bounds.width <= 500, view.bounds.height > 50 else {
            menuFailure = DocumentationCaptureFailure(
                message: "AppKit exposed \(windows.count) unambiguous in-process popup-menu views. The actual menu cannot be captured through its own public NSView; no desktop or permission fallback was used."
            )
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            menuFailure = DocumentationCaptureFailure(message: "The actual primary-menu content view refused bitmap caching.")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        menuBitmap = bitmap
    }
}
