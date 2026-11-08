import Foundation
import IOKit.pwr_mgt
import os

/// Keeps the Mac from going to sleep on its own while Workbench is open, so a run left going overnight is not cut off by idle sleep.
///
/// It holds one power-management assertion of the kind `PreventUserIdleSystemSleep`, the same `caffeinate -i` takes, but in this process:
/// no helper process to leave behind, and the system drops the assertion by itself if the app dies without releasing it. It is held for
/// the app's lifetime, not its activation, so it holds in the background and with the window closed. The display still sleeps and the
/// screen still locks, and the user can still put the Mac to sleep from the menu or the lid.
///
/// Setting it up can fail (the power-management daemon refuses): that is logged and kept in `failure`, and the app goes on without it.
@MainActor final class SleepPrevention {
    /// The name the assertion carries in `pmset -g assertions`.
    static let reason = "Workbench is open: keeping the Mac awake for runs in progress"

    private let backend: any SleepAssertionBackend
    private let log = Logger(subsystem: "dev.rogal.workbench", category: "sleep-prevention")
    private var assertion: SleepAssertionID?
    /// Why the last start or stop failed, for a diagnosis; nil after one that worked.
    private(set) var failure: String?

    init(backend: any SleepAssertionBackend = IOKitSleepAssertions()) {
        self.backend = backend
    }

    /// Whether the assertion is held right now.
    var isActive: Bool { assertion != nil }

    /// Takes the assertion, once: a second call while it is held does nothing. A failure is logged and kept, never thrown.
    func start() {
        guard assertion == nil else { return }
        do {
            assertion = try backend.create(reason: Self.reason)
            failure = nil
            log.info("idle system sleep prevented while Workbench is open")
        } catch {
            failure = "could not keep the Mac awake: \(error)"
            log.error("could not keep the Mac awake: \(String(describing: error), privacy: .public)")
        }
    }

    /// Lets the assertion go (a quit). Safe to call when none is held.
    func stop() {
        guard let held = assertion else { return }
        assertion = nil
        do {
            try backend.release(held)
            log.info("idle system sleep allowed again")
        } catch {
            failure = "could not release the keep-awake assertion: \(error)"
            log.error("could not release the keep-awake assertion: \(String(describing: error), privacy: .public)")
        }
    }
}

typealias SleepAssertionID = UInt32

/// Where the assertion comes from: IOKit in the app, a stand-in in tests.
protocol SleepAssertionBackend: Sendable {
    func create(reason: String) throws -> SleepAssertionID
    func release(_ id: SleepAssertionID) throws
}

/// A power-management call that did not return `kIOReturnSuccess`, with its code.
struct SleepAssertionError: Error, CustomStringConvertible, Equatable {
    let call: String
    let code: Int32
    var description: String { "\(call) returned 0x\(String(UInt32(bitPattern: code), radix: 16))" }
}

struct IOKitSleepAssertions: SleepAssertionBackend {
    /// `kIOPMAssertionTypePreventUserIdleSystemSleep`, a `CFSTR` macro Swift does not import.
    static let type = "PreventUserIdleSystemSleep"

    func create(reason: String) throws -> SleepAssertionID {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            Self.type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else { throw SleepAssertionError(call: "IOPMAssertionCreateWithName", code: result) }
        return id
    }

    func release(_ id: SleepAssertionID) throws {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else { throw SleepAssertionError(call: "IOPMAssertionRelease", code: result) }
    }
}
