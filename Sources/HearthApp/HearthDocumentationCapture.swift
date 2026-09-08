import AppKit
import HearthCore

private struct DocumentationCaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Captures only AppKit-owned menu views. No screen capture or accessibility APIs.
@MainActor
final class HearthDocumentationCapture: NSObject {
    private var menu: NSMenu?
    private var priorWindows: Set<ObjectIdentifier> = []
    private var capturedBitmap: NSBitmapImageRep?
    private var captureFailure: Error?

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
        let app = HearthAppController(
            service: HearthService(runner: runner, stateDirectory: directory),
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
              app.preventItem.title == "Keep awake",
              app.menu.items.contains(where: { $0.submenu === app.advancedMenu }) else {
            throw DocumentationCaptureFailure(message: "The actual native menu did not reach the expected sample state.")
        }

        let appearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        defer { NSApplication.shared.appearance = appearance }
        let defaultBitmap = try capture(app.menu)

        // This existing menu action is connected only to the fake runner above.
        app.menu.performActionForItem(at: app.menu.index(of: app.preventItem))
        try await settle(app)
        guard runner.writeCount == 1,
              app.currentStatus?.hasManagedChanges == true,
              app.preventItem.title == "Restore previous settings" else {
            throw DocumentationCaptureFailure(message: "The actual native menu did not reach the expected managed sample state.")
        }
        let activeBitmap = try capture(app.menu)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try write(defaultBitmap, to: outputDirectory.appendingPathComponent("native-menu-default.png"))
        try write(activeBitmap, to: outputDirectory.appendingPathComponent("native-menu-active.png"))
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
            throw DocumentationCaptureFailure(message: "AppKit could not encode the native menu pixels.")
        }
        guard png.count < 500_000 else {
            throw DocumentationCaptureFailure(message: "Native menu capture exceeded the documentation image size limit.")
        }
        let pixelsOnly = try removingMetadata(png)
        try pixelsOnly.write(to: output, options: .atomic)
        print("Captured \(output.lastPathComponent) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh), \(pixelsOnly.count) bytes); isolated sample data.")
    }

    private func withSystemBackground(_ source: NSBitmapImageRep) throws -> NSBitmapImageRep {
        // WindowServer owns the translucent backdrop, not NSView.cacheDisplay.
        // Keep the actual native control pixels, with a solid system-color canvas.
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
            throw DocumentationCaptureFailure(message: "Could not create the native menu's opaque pixel canvas.")
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

    private func capture(_ menu: NSMenu) throws -> NSBitmapImageRep {
        self.menu = menu
        priorWindows = Set(NSApplication.shared.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        capturedBitmap = nil
        captureFailure = nil
        // Status is already settled. A menu-open async refresh cannot finish while
        // NSMenu's synchronous tracking loop owns the main thread.
        let delegate = menu.delegate
        menu.delegate = nil
        let timer = Timer(timeInterval: 0.8, target: self, selector: #selector(captureVisibleMenu), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer {
            timer.invalidate()
            menu.cancelTracking()
            menu.delegate = delegate
            self.menu = nil
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let mouse = NSEvent.mouseLocation
        let x = mouse.x < screen.midX
            ? screen.maxX - menu.size.width - 40
            : screen.minX + 40
        NSApplication.shared.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: screen.maxY - 60), in: nil)
        if let captureFailure { throw captureFailure }
        guard let capturedBitmap else {
            throw DocumentationCaptureFailure(message: "The native menu closed before AppKit exposed its own content view. No image was written.")
        }
        return capturedBitmap
    }

    @objc private func captureVisibleMenu() {
        defer { menu?.cancelTracking() }
        let windows = NSApplication.shared.windows.filter {
            !priorWindows.contains(ObjectIdentifier($0)) &&
                $0.isVisible &&
                $0.contentView != nil
        }
        guard windows.count == 1,
              let view = windows.first?.contentView,
              view.bounds.width > 100,
              view.bounds.height > 50 else {
            captureFailure = DocumentationCaptureFailure(
                message: "NSMenu.popUp exposed \(windows.count) new visible in-process content views through NSApplication.windows on macOS \(ProcessInfo.processInfo.operatingSystemVersionString). The native menu is not available for unambiguous public NSView.cacheDisplay capture. No screen-capture permission was requested and no image was written."
            )
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            captureFailure = DocumentationCaptureFailure(message: "The native menu content view does not support AppKit bitmap caching. No image was written.")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        capturedBitmap = bitmap
    }
}
