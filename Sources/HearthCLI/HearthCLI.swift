import AppKit
import Darwin
import Foundation
import HearthCore
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
                let status = try HearthService().status()
                print(try json ? StatusPrinter().json(status) : StatusPrinter().text(status))
                status.warnings.forEach { error($0) }
            case .power(let request):
                let runner = SystemPowerRunner()
                let service = HearthService(runner: runner)
                guard runner.helperAvailability().isReady else {
                    let status = try service.status()
                    print(StatusPrinter().text(status))
                    status.warnings.forEach { error($0) }
                    error("No power change requested. Run 'hearth setup' for setup / repair instructions, then retry when the helper is ready.")
                    return 1
                }
                let result = try service.perform(request)
                for outcome in result.outcomes {
                    let text = "\(outcome.profile.label): \(outcome.message)"
                    if outcome.kind == .failed || outcome.kind == .preserved {
                        error(text)
                    } else {
                        print(text)
                    }
                }
                result.status.warnings.forEach { error($0) }
                print(StatusPrinter().text(result.status))
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
        let service = HearthService()
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
          hearth on [--power battery|adapter|both]
          hearth restore [--power battery|adapter|both]
          hearth off [--power battery|adapter|both]     Alias for restore
          hearth sleep --minutes N [--power battery|adapter|both]
          hearth web [--no-open] [--port 0..65535]
          hearth setup                   Print explicit helper setup / repair instructions
          hearth --version

        Both power sources are selected by default. N must be a positive integer.
        Restore changes only settings owned by Hearth, never guesses a timeout,
        and preserves detected external changes. Use sleep for a new permanent timeout.

        Run hearth as your normal user. Power changes require a ready, explicitly
        installed helper. Normal actions never request administrator permission
        or start an installer. Run hearth setup for setup / repair instructions.
        Display may still turn off. Settings persist after exit and reboot.
        This does not prevent lid-close sleep, manual sleep, critical-battery sleep,
        system safety behavior, or control other apps' sleep assertions.
        """
    }
}
