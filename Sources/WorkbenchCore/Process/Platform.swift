import Foundation

// The one place that picks the operating system's implementation of the contract.
#if canImport(Darwin)
typealias CurrentPlatform = DarwinPlatform
#else
#error("Workbench has no platform implementation for this OS yet (Linux arrives with P18 task 3)")
#endif

typealias PlatformServices = ProcessInspecting & SpawnPlatform & ExitNotifying & Subreaping & Sendable

/// What the code calls. Not a global of the concrete type, so a test can run the contract on any conforming value.
let platform: some PlatformServices = CurrentPlatform()
