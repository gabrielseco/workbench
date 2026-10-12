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
        .testTarget(name: "WorkbenchCoreTests", dependencies: ["WorkbenchCore"]),
    ]
)
