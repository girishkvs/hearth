import AppKit
import Darwin
import Foundation
import HearthCore
import HearthLockIPC
import HearthWeb

@main
struct HearthCLI {
    static func main() {
        exit(HearthCLI().run())
    }

    private func run() -> Int32 {
        guard getuid() != 0, geteuid() != 0 else {
            error("Run hearth as your normal user, without sudo. Use 'hearth setup' for explicit helper setup / repair instructions.")
            return 1
        }
        do {
            switch try CommandLineParser().parse(Array(CommandLine.arguments.dropFirst())) {
            case .help:
                print(help)
            case .version:
                print("Hearth \(HearthVersion.current)")
            case .setup:
                print(SetupInstructions().text)
            case .status(let json):
                let status = try HearthService(idleLockController: IdleLockClient()).status()
                print(try json ? StatusPrinter().json(status) : StatusPrinter().text(status))
                status.warnings.forEach { error($0) }
            case .lockStatus:
                let status = try HearthService(idleLockController: IdleLockClient()).status()
                print(StatusPrinter().lockText(status.idleLock))
                status.warnings.forEach { error($0) }
            case .lock(let request):
                let service = HearthService(idleLockController: IdleLockClient())
                let result = try service.performIdleLock(request)
                print(StatusPrinter().lockText(result.status))
                if result.succeeded { print(result.message) }
                else { error(result.message) }
                return result.succeeded ? 0 : 1
            case .power(let request):
                let runner = SystemPowerRunner()
                let service = HearthService(runner: runner, idleLockController: IdleLockClient())
                guard runner.helperAvailability().isReady else {
                    let status = try service.status()
                    print(StatusPrinter().text(status))
                    status.warnings.forEach { error($0) }
                    error("No power change requested. Run 'hearth setup' for setup / repair instructions, then retry when the helper is ready.")
                    return 1
                }
                let result = try service.perform(request)
                for outcome in result.outcomes {
                    let text = "\(outcome.setting.label) — \(outcome.profile.label): \(outcome.message)"
                    if outcome.kind == .failed || outcome.kind == .preserved {
                        error(text)
                    } else {
                        print(text)
                    }
                }
                let status = try service.status()
                result.status.warnings.forEach { error($0) }
                status.warnings.filter { !result.status.warnings.contains($0) }.forEach { error($0) }
                print(StatusPrinter().text(status))
                return result.succeeded ? 0 : 1
            case .web(let port, let openBrowser):
                try runWeb(port: port, openBrowser: openBrowser)
            }
            return 0
        } catch {
            self.error(error.localizedDescription)
            return 1
        }
    }

    private func runWeb(port: Int, openBrowser: Bool) throws {
        let service = HearthService(idleLockController: IdleLockClient())
        let server = HearthWebServer(service: service)
        let url = try server.start(port: port)
        let finished = DispatchSemaphore(value: 0)
        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousTerminate = signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { finished.signal() }
        terminate.setEventHandler { finished.signal() }
        interrupt.resume()
        terminate.resume()
        defer {
            interrupt.cancel()
            terminate.cancel()
            signal(SIGINT, previousInterrupt)
            signal(SIGTERM, previousTerminate)
        }
        print("Hearth web: \(url.absoluteString)")
        print("Keep this URL private. Ctrl+C stops the server; power settings stay unchanged.")
        fflush(nil)
        if openBrowser, !NSWorkspace.shared.open(url) {
            error("Could not open the browser. Open the printed URL on this Mac.")
        }
        finished.wait()
        try server.stop()
    }

    private func error(_ message: String) {
        FileHandle.standardError.write(Data("hearth: \(message)\n".utf8))
    }

    private var help: String {
        """
        Hearth - persistent macOS idle-sleep control

        Usage:
          hearth                         Show actual settings and Hearth restore state
          hearth status [--json]
          hearth lock on|restore|status   Current user; all available power profiles
          hearth on [--setting system|display] [--power battery|adapter|both]
          hearth restore [--setting system|display] [--power battery|adapter|both]
          hearth off [--setting system|display] [--power battery|adapter|both]
          hearth sleep --minutes N [--setting system|display] [--power battery|adapter|both]
          hearth web [--no-open] [--port 0..65535]
          hearth setup                   Print explicit helper setup / repair instructions
          hearth --version

        System sleep and both power sources are selected by default.
        Use --setting display explicitly to change idle display sleep.
        N must be a positive integer. off is an alias for restore.
        Restore changes only settings owned by Hearth, never guesses a timeout,
        and preserves detected external changes. Use sleep for a new permanent timeout.

        Run hearth as your normal user. Power changes require a ready, explicitly
        installed helper. Normal actions never request administrator permission
        or start an installer. Run hearth setup for setup / repair instructions.
        Lock coordinates System and Display awake on all available power profiles,
        regardless of --power selection. Restore Lock releases only its changes;
        pre-existing overrides are kept. Required by Lock settings cannot be changed
        until Lock is restored. No Automation setup is needed. CLI and web use
        the verified Hearth app as one serialized current-user preference writer.
        Configured settings and readback do not prove immediate macOS timer adoption.
        macOS may adopt or restore the timer later.
        Manual lock, passwords, and authentication are unchanged.
        Settings persist after exit and reboot.
        This does not prevent lid-close sleep, manual sleep, critical-battery sleep,
        system safety behavior, or control other apps' sleep assertions.
        """
    }
}
