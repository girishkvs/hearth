// swift-tools-version: 6.0
import PackageDescription
import Foundation

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let releaseVersion = try String(contentsOf: repository.appendingPathComponent("VERSION"), encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let generatedVersion = """
// Generated from VERSION by scripts/sync-version.sh.
public enum HearthVersion {
    public static let current = "\(releaseVersion)"
}

"""
let checkedVersion = try String(
    contentsOf: repository.appendingPathComponent("Sources/HearthCore/HearthVersion.swift"), encoding: .utf8)
guard releaseVersion.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
      checkedVersion == generatedVersion else {
    fatalError("Version drift: update VERSION and run scripts/sync-version.sh before building.")
}

let package = Package(
    name: "Hearth",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HearthCore", targets: ["HearthCore"]),
        .executable(name: "hearth", targets: ["HearthCLI"]),
        .executable(name: "HearthApp", targets: ["HearthApp"]),
        .executable(name: "HearthHelper", targets: ["HearthHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.85.0"),
    ],
    targets: [
        .target(name: "HearthIPC"),
        .target(name: "HearthCore", dependencies: ["HearthIPC"]),
        .target(
            name: "HearthWeb",
            dependencies: [
                "HearthCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            resources: [.copy("Resources/index.html")]
        ),
        .executableTarget(name: "HearthCLI", dependencies: ["HearthCore", "HearthWeb"]),
        .executableTarget(name: "HearthApp", dependencies: ["HearthCore"]),
        .executableTarget(name: "HearthHelper", dependencies: ["HearthCore", "HearthIPC"]),
        .testTarget(name: "HearthCoreTests", dependencies: ["HearthCore"]),
        .testTarget(name: "HearthCLITests", dependencies: ["HearthCLI", "HearthCore"]),
        .testTarget(name: "HearthWebTests", dependencies: ["HearthWeb", "HearthCore"]),
        .testTarget(name: "HearthHelperTests", dependencies: ["HearthHelper", "HearthIPC", "HearthCore"]),
    ]
)
