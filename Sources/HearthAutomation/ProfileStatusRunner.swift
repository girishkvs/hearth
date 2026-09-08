import Darwin
import Foundation
import HearthCore

enum ProfileStatusQuery: Equatable, Sendable {
    case configuration
    case enrollment

    var arguments: [String] {
        switch self {
        case .configuration: ["status", "-type", "configuration"]
        case .enrollment: ["status", "-type", "enrollment"]
        }
    }
}

struct ProfileStatusResult: Sendable {
    let exitCode: Int32
    let output: String
}

protocol ProfileStatusRunning: Sendable {
    func run(_ query: ProfileStatusQuery) throws -> ProfileStatusResult
}

struct NativeProfileStatusRunner: ProfileStatusRunning {
    func run(_ query: ProfileStatusQuery) throws -> ProfileStatusResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
        process.arguments = query.arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw ScreenSaverError.unavailable("Cannot prepare the read-only profile status query.")
        }
        do {
            try process.run()
        } catch {
            throw ScreenSaverError.unavailable("Cannot launch the read-only profile status query.")
        }
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 {
                output.append(contentsOf: bytes.prefix(count))
                if output.count > 8192 {
                    stop(process)
                    throw ScreenSaverError.unavailable("The profile status response exceeded its size limit.")
                }
            } else if count == 0 {
                if !process.isRunning { break }
            } else if errno != EAGAIN &&
                errno != EINTR {
                stop(process)
                throw ScreenSaverError.unavailable("Cannot read the profile status response.")
            }
            if count <= 0 &&
                !process.isRunning {
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stop(process)
                throw ScreenSaverError.unavailable("The read-only profile status query timed out.")
            }
            if count <= 0 {
                var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&event, 1, 25)
            }
        }
        process.waitUntilExit()
        guard let text = String(data: output, encoding: .utf8) else {
            throw ScreenSaverError.unavailable("The profile status response was not UTF-8.")
        }
        return ProfileStatusResult(exitCode: process.terminationStatus, output: text)
    }

    private func stop(_ process: Process) {
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
