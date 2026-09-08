import Darwin
import Foundation
import HearthIPC
import MachO

@main
struct HearthHelperMain {
    static func main() {
        do {
            try HearthHelperDaemon().run()
        } catch {
            let message = "Hearth helper refused to start: \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
}

private struct HearthHelperDaemon {
    func run() throws {
        guard CommandLine.arguments.count == 1, getuid() == 0, geteuid() == 0 else {
            throw HelperClientError.setupRequired("Only the installed root launch daemon may run this executable; no arguments are accepted.")
        }
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0,
              String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) ==
                HelperInstallation.executablePath else {
            throw HelperClientError.setupRequired("Hearth helper must run from its fixed protected installation path.")
        }
        let installation = ProtectedHelperInstallation()
        let policy = try installation.loadPolicy()
        try installation.validateDaemonFiles(policy: policy)
        let worker = HelperWorker(backend: PMSetBackend(), maintenance: ProtectedMaintenanceLock())
        let delegate = HelperListenerDelegate(worker: worker, requirement: policy.clientsRequirement)
        let listener = NSXPCListener(machServiceName: HelperInstallation.serviceName)
        listener.setConnectionCodeSigningRequirement(policy.clientsRequirement.text)
        listener.delegate = delegate
        listener.activate()
        withExtendedLifetime((delegate, listener)) { RunLoop.current.run() }
    }
}
