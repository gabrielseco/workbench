// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "workbench",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkbenchCore", targets: ["WorkbenchCore"]),
        .executable(name: "workbench", targets: ["workbench"]),
    ],
    targets: [
        .target(name: "WorkbenchCore"),
        .executableTarget(name: "workbench", dependencies: ["WorkbenchCore"]),
        // Test double for `claude`. Standalone on purpose: no dependency on WorkbenchCore.
        .executableTarget(name: "fake-claude"),
        .testTarget(name: "WorkbenchCoreTests", dependencies: ["WorkbenchCore", "fake-claude", "workbench"]),
    ]
)
