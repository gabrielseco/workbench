// swift-tools-version: 6.0
import PackageDescription

// Swift 6.2.1's optimizer pass `JumpThreadSimplifyCFG` (`simplify-cfg`) produces invalid SIL for some async functions: with
// `-Xfrontend -sil-verify-all` the compiler aborts with "branch argument types do not match arguments for dest bb"; without it the
// invalid code is compiled and a release build misbehaves (a Claude review was refused for a dollar limit Claude does not have; a
// debug build was fine). `docs/swift-bugs/simplify-cfg-async.swift` is a 60-line case, `scripts/swift-bug-repro.sh` tells whether
// the installed toolchain still has it. Remove this when it prints "fixed". The flag cannot be used by a package that depends on
// WorkbenchCore (SwiftPM refuses unsafe flags in dependencies): the app (P3) must build it from this package or wait for the fix.
let simplifyCFGWorkaround: [SwiftSetting] = [
    .unsafeFlags(["-Xllvm", "-sil-disable-pass=simplify-cfg"], .when(configuration: .release))
]

let package = Package(
    name: "workbench",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkbenchCore", targets: ["WorkbenchCore"]),
        .executable(name: "workbench", targets: ["workbench"]),
    ],
    dependencies: [
        // Same API as CryptoKit on every platform (it wraps CryptoKit on Apple ones), so no `#if` at the call sites.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "WorkbenchCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: simplifyCFGWorkaround),
        .executableTarget(name: "workbench", dependencies: ["WorkbenchCore"], swiftSettings: simplifyCFGWorkaround),
        // Test double for `claude`. Standalone on purpose: no dependency on WorkbenchCore.
        .executableTarget(name: "fake-claude"),
        .testTarget(name: "WorkbenchCoreTests", dependencies: [
            "WorkbenchCore", "fake-claude", "workbench",
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ]
)
