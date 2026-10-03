// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionBar",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that reads Claude Code's files or builds `claude` commands. No UI, fully unit-tested.
        .target(name: "SessionBarCore"),
        .executableTarget(name: "SessionBar", dependencies: ["SessionBarCore"]),
        .testTarget(
            name: "SessionBarCoreTests",
            dependencies: ["SessionBarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
