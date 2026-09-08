import Darwin
import Foundation

do {
    #if HEARTH_REPAIR_CAPTURE
    guard getuid() != 0,
          CommandLine.arguments.count == 2 else {
        throw InstallFailure.refused("Read-only repair capture requires a new output path as a normal user")
    }
    let coordinator = Maintenance(validator: Validator(root: "/"), extraction: URL(fileURLWithPath: "/"))
    let approval = try coordinator.captureSupportRepair()
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    let descriptor = open(CommandLine.arguments[1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw InstallFailure.refused("Repair capture output must not already exist") }
    defer { close(descriptor) }
    try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: encoder.encode(approval))
    print("Captured read-only empty-folder fingerprint. No repair was performed or approved by this command.")
    #elseif HEARTH_PACKAGE_BUILD
    guard getuid() != 0,
          CommandLine.arguments.count == 3 else {
        throw InstallFailure.refused("Build-only tool requires a payload path and build identifier as a normal user")
    }
    let validator = Validator(root: CommandLine.arguments[1])
    let build = CommandLine.arguments[2]
    let authorization = Authorization(
        FormatVersion: 1, ProtocolVersion: 1,
        AppCodeHash: try validator.codeHash(validator.app + "/Contents/MacOS/HearthApp", identifier: "dev.girishkvs.hearth"),
        CLICodeHash: try validator.codeHash(validator.app + "/Contents/MacOS/hearth", identifier: "dev.girishkvs.hearth.cli"),
        HelperCodeHash: try validator.codeHash(validator.helper, identifier: "dev.girishkvs.hearth.helper"),
        BuildIdentifier: build)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    try encoder.encode(authorization).write(to: URL(fileURLWithPath: validator.path(validator.policy)))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: validator.path(validator.policy))
    let inventory = try validator.inventory(build: build, enforceOwnership: false)
    try encoder.encode(inventory).write(to: URL(fileURLWithPath: validator.path(validator.receipt)))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: validator.path(validator.receipt))
    try validator.validateSignatures()
    print("Enrolled finalized 20-byte CDHashes and \(inventory.entries.count) payload entries for \(build).")
    #elseif HEARTH_INSTALLER_TESTS
    try InstallerTests().run()
    #else
    guard getuid() == 0,
          geteuid() == 0,
          CommandLine.arguments.count == 2 else {
        throw InstallFailure.refused("Only Apple Installer may run this fixed-path maintenance tool")
    }
    let extraction = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
    try Maintenance(validator: Validator(root: "/"), extraction: extraction).run(CommandLine.arguments[1])
    #endif
} catch {
    FileHandle.standardError.write(Data("Hearth: \(error)\nSetup/removal did not complete. Partial setup may remain; repair is needed. No power settings were changed by the installer.\n".utf8))
    exit(1)
}
