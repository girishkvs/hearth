import Foundation
import XCTest
@testable import HearthHelper
@testable import HearthIPC

final class FakePMSetProcess: PMSetProcessRunning, @unchecked Sendable {
    enum Failure {
        case beforeLaunch
        case afterLaunch
    }

    private let lock = NSLock()
    private var commands: [PMSetCommand] = []
    private let output: String
    private let readExitCode: Int32
    private let writeExitCode: Int32
    private let failure: Failure?

    init(output: String, readExitCode: Int32 = 0, writeExitCode: Int32 = 0, failure: Failure? = nil) {
        self.output = output
        self.readExitCode = readExitCode
        self.writeExitCode = writeExitCode
        self.failure = failure
    }

    func run(_ command: PMSetCommand, lease: FileHandle, maintenance: FileHandle) throws -> PMSetResult {
        lock.withLock { commands.append(command) }
        switch command {
        case .read:
            return PMSetResult(exitCode: readExitCode, output: output)
        case .write:
            switch failure {
            case .beforeLaunch: throw HelperClientError.unavailable("Fake spawn failure")
            case .afterLaunch: throw LaunchedPMSetFailure(message: "Fake failure after launch")
            case nil: return PMSetResult(exitCode: writeExitCode, output: "Fake write result")
            }
        }
    }

    func recorded() -> [PMSetCommand] { lock.withLock { commands } }
}

final class PMSetBackendTests: XCTestCase {
    func testReadsSelectExactSettingAndProfileFromSameFixedObservation() throws {
        let process = FakePMSetProcess(output: fixture)
        let backend = PMSetBackend(process: process)
        XCTAssertEqual(try read(backend, profile: .battery, setting: .system), 1)
        XCTAssertEqual(try read(backend, profile: .adapter, setting: .system), 5)
        XCTAssertEqual(try read(backend, profile: .battery, setting: .display), 2)
        XCTAssertEqual(try read(backend, profile: .adapter, setting: .display), 10)
        XCTAssertEqual(process.recorded(), [.read, .read, .read, .read])
        XCTAssertEqual(PMSetCommand.read.arguments, ["-g", "custom"])
    }

    func testMissingDisplayValueNeverFallsBackToSystemValue() throws {
        let process = FakePMSetProcess(output: """
        Battery Power:
         sleep 7
        AC Power:
         sleep 9
         displaysleep 12
        """)
        let backend = PMSetBackend(process: process)
        XCTAssertEqual(try read(backend, profile: .battery, setting: .system), 7)
        XCTAssertThrowsError(try read(backend, profile: .battery, setting: .display))
        XCTAssertEqual(try read(backend, profile: .adapter, setting: .display), 12)
        XCTAssertTrue(process.recorded().allSatisfy { $0 == .read })
    }

    func testReadCommandFailureCannotProduceAnExpectedValue() {
        let process = FakePMSetProcess(output: fixture, readExitCode: 1)
        XCTAssertThrowsError(try read(PMSetBackend(process: process), profile: .adapter, setting: .display))
        XCTAssertEqual(process.recorded(), [.read])
    }

    func testWritesUseOnlyFixedProfileFlagSettingKeyAndValidatedInteger() {
        let process = FakePMSetProcess(output: fixture)
        let backend = PMSetBackend(process: process)
        var expected: [PMSetCommand] = []
        for setting in HelperPowerSetting.allCases {
            for profile in HelperPowerProfile.allCases {
                for minutes in [0, 30, Int(Int32.max)] {
                    let change = IdleSleepChange(profile: profile, minutes: minutes, expectedMinutes: 2, setting: setting)
                    let command = PMSetCommand.write(change)
                    expected.append(command)
                    XCTAssertEqual(command.arguments, [profile.flag, setting.pmsetKey, String(minutes)])
                    let result = backend.write(change, lease: .nullDevice, maintenance: .nullDevice)
                    XCTAssertEqual(result.profile, profile)
                    XCTAssertEqual(result.setting, setting)
                    XCTAssertEqual(result.exitCode, 0)
                    XCTAssertTrue(result.didExecute)
                }
            }
        }
        XCTAssertEqual(process.recorded(), expected)
    }

    func testInvalidValuesCannotReachEvenFakeProcess() {
        let process = FakePMSetProcess(output: fixture)
        let backend = PMSetBackend(process: process)
        for invalid in [-1, Int(Int32.max) + 1] {
            for change in [
                IdleSleepChange(profile: .adapter, minutes: invalid, expectedMinutes: 10, setting: .display),
                IdleSleepChange(profile: .adapter, minutes: 0, expectedMinutes: invalid, setting: .display),
            ] {
                let result = backend.write(change, lease: .nullDevice, maintenance: .nullDevice)
                XCTAssertEqual(result.setting, .display)
                XCTAssertEqual(result.exitCode, 1)
                XCTAssertFalse(result.didExecute)
            }
        }
        XCTAssertTrue(process.recorded().isEmpty)
    }

    func testDisplayFailuresKeepSettingAndReportWhetherLaunchHappened() {
        let change = IdleSleepChange(profile: .adapter, minutes: 0, expectedMinutes: 10, setting: .display)
        let cases: [(FakePMSetProcess, Int32, Bool)] = [
            (FakePMSetProcess(output: fixture, writeExitCode: 7), 7, true),
            (FakePMSetProcess(output: fixture, failure: .beforeLaunch), 1, false),
            (FakePMSetProcess(output: fixture, failure: .afterLaunch), 1, true),
        ]
        for (process, exitCode, didExecute) in cases {
            let result = PMSetBackend(process: process).write(change, lease: .nullDevice, maintenance: .nullDevice)
            XCTAssertEqual(result.profile, .adapter)
            XCTAssertEqual(result.setting, .display)
            XCTAssertEqual(result.exitCode, exitCode)
            XCTAssertEqual(result.didExecute, didExecute)
        }
    }

    private func read(
        _ backend: PMSetBackend, profile: HelperPowerProfile, setting: HelperPowerSetting
    ) throws -> Int {
        try backend.readMinutes(profile: profile, setting: setting, lease: .nullDevice, maintenance: .nullDevice)
    }

    private var fixture: String {
        """
        Battery Power:
         sleep 1
         displaysleep 2
         disksleep 3
        AC Power:
         sleep 5
         displaysleep 10
         disksleep 8
        UPS Power:
         sleep 99
         displaysleep 98
        """
    }
}
