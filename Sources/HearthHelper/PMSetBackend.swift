import Darwin
import Foundation
import HearthCore
import HearthIPC

struct PMSetBackend: IdleSleepBackend {
    private let process: any PMSetProcessRunning

    init(process: any PMSetProcessRunning = FixedPMSetProcess()) {
        self.process = process
    }

    func readMinutes(
        profile: HelperPowerProfile, setting: HelperPowerSetting, lease: FileHandle, maintenance: FileHandle
    ) throws -> Int {
        let result = try process.run(.read, lease: lease, maintenance: maintenance)
        guard result.exitCode == 0 else {
            throw HelperClientError.unavailable("Cannot read current pmset values: \(result.output)")
        }
        let settings = try PMSetParser().parse(custom: result.output, battery: "")
        guard let coreProfile = PowerProfile(rawValue: profile.rawValue),
              let coreSetting = PowerSetting(rawValue: setting.rawValue),
              let minutes = settings.values(for: coreSetting)[coreProfile] else {
            throw HelperClientError.unavailable("Requested \(setting.rawValue) timeout for \(profile.rawValue) is unavailable.")
        }
        return minutes
    }

    func write(_ change: IdleSleepChange, lease: FileHandle, maintenance: FileHandle) -> HelperCommandOutcome {
        do {
            try HelperWireCodec().validate([change])
            let result = try process.run(.write(change), lease: lease, maintenance: maintenance)
            return HelperCommandOutcome(
                profile: change.profile, exitCode: result.exitCode, message: result.output,
                didExecute: true, setting: change.setting
            )
        } catch let error as LaunchedPMSetFailure {
            return HelperCommandOutcome(
                profile: change.profile, exitCode: 1, message: error.localizedDescription,
                didExecute: true, setting: change.setting
            )
        } catch {
            return HelperCommandOutcome(
                profile: change.profile, exitCode: 1, message: error.localizedDescription,
                didExecute: false, setting: change.setting
            )
        }
    }
}

enum PMSetCommand: Equatable, Sendable {
    case read
    case write(IdleSleepChange)

    var arguments: [String] {
        switch self {
        case .read: ["-g", "custom"]
        case .write(let change): [change.profile.flag, change.setting.pmsetKey, String(change.minutes)]
        }
    }
}

protocol PMSetProcessRunning: Sendable {
    func run(_ command: PMSetCommand, lease: FileHandle, maintenance: FileHandle) throws -> PMSetResult
}

struct LaunchedPMSetFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PMSetResult: Sendable {
    let exitCode: Int32
    let output: String
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    func append(_ part: Data) {
        lock.withLock {
            let remaining = max(0, 4096 - data.count)
            data.append(part.prefix(remaining))
            if part.count > remaining { truncated = true }
        }
    }

    func result() -> String {
        lock.withLock {
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) +
                (truncated ? " [output truncated]" : "")
        }
    }
}

struct FixedPMSetProcess: PMSetProcessRunning {
    private func spawn(_ arguments: [String], lease: FileHandle, maintenance: FileHandle, output: FileHandle) throws -> pid_t {
        let actions = try InheritedLockActions(
            journal: lease.fileDescriptor, maintenance: maintenance.fileDescriptor,
            output: output.fileDescriptor
        )
        try check(posix_spawn_file_actions_addchdir_np(&actions.actions, "/"))
        var argv = (["/usr/bin/pmset"] + arguments).map { strdup($0) } + [nil]
        let environmentValues = ["PATH=/usr/bin:/bin", "HOME=/", "LANG=C", "LC_ALL=C"]
        var environment = environmentValues.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            environment.forEach { free($0) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }),
              environment.dropLast().allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var pid: pid_t = 0
        // fd 0 retains the user's journal lock, fd 3 the root operation lock.
        // Only the fixed OS executable inherits them; no shell or mutable user code.
        try check(posix_spawn(&pid, "/usr/bin/pmset", &actions.actions, &actions.attributes, &argv, &environment))
        return pid
    }

    func run(_ command: PMSetCommand, lease: FileHandle, maintenance: FileHandle) throws -> PMSetResult {
        let pipe = Pipe()
        // Destroy the spawn configuration (and its parent-only writer duplicates)
        // before waiting for EOF. The child retains its own output and lock copies.
        let pid = try spawn(command.arguments, lease: lease, maintenance: maintenance, output: pipe.fileHandleForWriting)
        try? pipe.fileHandleForWriting.close()
        let output = BoundedOutput()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? pipe.fileHandleForReading.close()
                drained.signal()
            }
            while let part = try? pipe.fileHandleForReading.read(upToCount: 4096), !part.isEmpty {
                output.append(part)
            }
        }
        let result: (exitCode: Int32, timedOut: Bool)
        do {
            result = try awaitChild(pid)
        } catch {
            drained.wait()
            throw LaunchedPMSetFailure(message: error.localizedDescription)
        }
        drained.wait()
        return PMSetResult(
            exitCode: result.timedOut ? 124 : result.exitCode,
            output: (result.timedOut ? "pmset timed out; completion was awaited before returning. " : "") + output.result()
        )
    }

    private func awaitChild(_ pid: pid_t) throws -> (exitCode: Int32, timedOut: Bool) {
        let start = DispatchTime.now().uptimeNanoseconds
        var terminated = false
        var killed = false
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, killed ? 0 : WNOHANG)
            if result == pid {
                let signal = status & 0x7f
                return (signal == 0 ? (status >> 8) & 0xff : 128 + signal, terminated)
            }
            if result == -1 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            // The PID cannot be recycled before this method reaps our own child.
            if elapsed >= 12_000_000_000, !killed {
                _ = Darwin.kill(pid, SIGKILL)
                killed = true
                terminated = true
            } else if elapsed >= 10_000_000_000, !terminated {
                _ = Darwin.kill(pid, SIGTERM)
                terminated = true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func check(_ code: Int32) throws {
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
}
