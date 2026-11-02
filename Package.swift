// swift-tools-version: 6.0
import PackageDescription

// Swift 6.2.1's optimizer pass `JumpThreadSimplifyCFG` (`simplify-cfg`) produces invalid SIL for some async functions: with
// `-Xfrontend -sil-verify-all` the compiler aborts with "branch argument types do not match arguments for dest bb"; without it the
// invalid code is compiled and a release build misbehaves (a Claude review was refused for a dollar limit Claude does not have; a
// debug build was fine). `docs/swift-bugs/simplify-cfg-async.swift` is a 60-line case, `scripts/swift-bug-repro.sh` tells whether
// the installed toolchain still has it. Remove this when it prints "fixed". The flag cannot be used by a package that depends on
// WorkbenchCore (SwiftPM refuses unsafe flags in dependencies): the app (P3) must build it from this package or wait for the fix.
//
// Xcode 27.2 (Swift 6.4.2) has a second, different optimizer bug: the release build aborts in the `Simplification` pass with
// "SIL/BorrowUtils.swift: cannot get borrow introducers for unknown guaranteed value", on `ThreadService.planLocked` (and, when that is
// cut short, on `plan`). Restructuring the function did not avoid it (docs/swift-bugs/simplification-borrow.md), so that pass is
// disabled in release builds on a 6.4 or newer compiler. CI does not have it (see below). Remove `simplification` when a release build of this package
// with the flag taken out compiles on the newest Xcode.
#if compiler(>=6.4)
// Only on a compiler that has the bug: on Swift 6.1.2 (the runner's default Xcode) a pipeline without `Simplification` crashes in
// `CodeSinking` instead.
let releaseDisabledPasses = ["-Xllvm", "-sil-disable-pass=simplify-cfg", "-Xllvm", "-sil-disable-pass=simplification"]
#else
let releaseDisabledPasses = ["-Xllvm", "-sil-disable-pass=simplify-cfg"]
#endif
let simplifyCFGWorkaround: [SwiftSetting] = [
    .unsafeFlags(releaseDisabledPasses, .when(configuration: .release))
]

// The app is SwiftUI and AppKit, which only macOS has; Linux builds the library and the CLI only (the PR gate's job).
var appProducts: [Product] = []
var appTargets: [Target] = []
#if os(macOS)
appProducts = [.executable(name: "WorkbenchApp", targets: ["WorkbenchApp"])]
appTargets = [
    // No process code lives here: the app calls WorkbenchCore (`scripts/check-banned-apis.sh` covers it).
    .executableTarget(name: "WorkbenchApp", dependencies: ["WorkbenchCore"], swiftSettings: simplifyCFGWorkaround),
    .testTarget(name: "WorkbenchAppTests", dependencies: ["WorkbenchApp", "WorkbenchCore"]),
]
#endif

let package = Package(
    name: "workbench",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkbenchCore", targets: ["WorkbenchCore"]),
        .executable(name: "workbench", targets: ["workbench"]),
    ] + appProducts,
    targets: [
        // zlib is on macOS and Linux alike; Apple's `Compression` framework is not.
        .systemLibrary(name: "CZlib"),
        .target(
            name: "WorkbenchCore",
            dependencies: ["CZlib", "CShim"],
            swiftSettings: simplifyCFGWorkaround),
        // The few C calls Swift cannot make itself: a variadic `prctl`, and `stdout` (Swift 6 rejects reading the C global on glibc).
        .target(name: "CShim"),
        .executableTarget(name: "workbench", dependencies: ["WorkbenchCore", "CShim"], swiftSettings: simplifyCFGWorkaround),
        // Test double for `claude`. Standalone on purpose: no dependency on WorkbenchCore.
        .executableTarget(name: "fake-claude"),
        .testTarget(
            name: "WorkbenchCoreTests",
            dependencies: ["WorkbenchCore", "fake-claude", "workbench"]),
    ] + appTargets
)
