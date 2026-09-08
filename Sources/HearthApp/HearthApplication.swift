import AppKit
import Darwin
import HearthCore
import HearthAutomation
import HearthLockIPC

@main
struct HearthApplication {
    @MainActor
    static func main() {
        guard getuid() != 0 && geteuid() != 0 else {
            FileHandle.standardError.write(Data("Hearth must run as your normal user, not root. Open it without sudo.\n".utf8))
            exit(1)
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        let captureDirectory = arguments.count == 2 && arguments.first == "--capture-docs"
            ? URL(fileURLWithPath: arguments[1], isDirectory: true)
            : nil
        guard arguments.isEmpty ||
                arguments == ["--smoke-test"] ||
                captureDirectory != nil else {
            FileHandle.standardError.write(Data("Usage: HearthApp [--smoke-test | --capture-docs OUTPUT_DIRECTORY]\n".utf8))
            exit(64)
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = HearthApplicationDelegate(
            smokeTest: arguments == ["--smoke-test"],
            captureDirectory: captureDirectory
        )
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class HearthApplicationDelegate: NSObject, NSApplicationDelegate {
    private let smokeTest: Bool
    private let captureDirectory: URL?
    private var controller: HearthAppController?
    private var allowsTermination = false
    private var lockListener: IdleLockListener?

    init(smokeTest: Bool, captureDirectory: URL? = nil) {
        self.smokeTest = smokeTest
        self.captureDirectory = captureDirectory
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let captureDirectory {
            Task { @MainActor in
                do {
                    try await HearthDocumentationCapture().run(outputDirectory: captureDirectory)
                    print("HEARTH_DOCS_CAPTURE: PASS — actual primary menu and Advanced controls, isolated sample data")
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("HEARTH_DOCS_CAPTURE: FAIL — \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            return
        }
        if smokeTest {
            Task { @MainActor in
                do {
                    try await HearthSmokeTest().run()
                    print("HEARTH_APP_SMOKE_TEST: PASS — native controls, fake power operations, refresh, and quit safety")
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("HEARTH_APP_SMOKE_TEST: FAIL — \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            return
        }

        let power = SystemPowerRunner()
        let screenSaver = SystemScreenSaverController()
        let lockService = IdleLockService(runner: power, screenSaver: screenSaver)
        let service = HearthService(runner: power, idleLockController: lockService)
        let listener = IdleLockListener(controller: lockService)
        self.lockListener = listener
        let controller = HearthAppController(
            service: service,
            refreshLockRegistration: { try listener.ensureRegistration() }
        ) { [weak self] in
            guard self?.lockListener?.stop() != false else {
                self?.controller?.reportQuitBlocked("A Lock request is still running. Wait for it to finish before quitting.")
                return
            }
            self?.allowsTermination = true
            NSApplication.shared.terminate(nil)
        }
        self.controller = controller
        Task { @MainActor [weak self] in
            do {
                try await Task.detached { try listener.start() }.value
            } catch {
                self?.controller?.reportLockServiceError(error.localizedDescription)
            }
        }
        controller.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowsTermination {
            return .terminateNow
        }
        controller?.requestQuit()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.refreshAfterReopen()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = lockListener?.stop()
        controller?.stop()
    }
}
