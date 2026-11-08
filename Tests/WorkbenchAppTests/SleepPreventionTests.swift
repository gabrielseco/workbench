import AppKit
import Foundation
import IOKit.pwr_mgt
import Testing

@testable import WorkbenchApp

/// A stand-in for IOKit: counts what was asked, and fails when told to.
private final class FakeAssertions: SleepAssertionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Set<SleepAssertionID> = []
    private var next: SleepAssertionID = 1
    private var creates = 0
    let createError: SleepAssertionError?
    let releaseError: SleepAssertionError?

    init(createError: SleepAssertionError? = nil, releaseError: SleepAssertionError? = nil) {
        self.createError = createError
        self.releaseError = releaseError
    }

    var heldCount: Int { lock.withLock { held.count } }
    var createCount: Int { lock.withLock { creates } }

    func create(reason: String) throws -> SleepAssertionID {
        try lock.withLock {
            creates += 1
            if let createError { throw createError }
            let id = next
            next += 1
            held.insert(id)
            return id
        }
    }

    func release(_ id: SleepAssertionID) throws {
        try lock.withLock {
            held.remove(id)
            if let releaseError { throw releaseError }
        }
    }
}

/// The names of the idle-sleep assertions this process holds, as the power-management daemon reports them.
private func systemAssertionsOfThisProcess() -> [String] {
    var unmanaged: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess, let dict = unmanaged?.takeRetainedValue() as NSDictionary?
    else { return [] }
    let pid = ProcessInfo.processInfo.processIdentifier
    let mine = dict.first { ($0.key as? NSNumber)?.int32Value == pid }?.value as? [NSDictionary] ?? []
    return mine.compactMap { entry in
        guard entry["AssertType"] as? String == IOKitSleepAssertions.type else { return nil }
        return entry["AssertName"] as? String
    }
}

@MainActor @Suite(.serialized) struct SleepPreventionTests {
    @Test func activeWhileAppIsOpen() {
        // The real IOKit assertion: the system sees it held by this process, and it stays held whatever the app's activation is.
        let prevention = SleepPrevention()
        defer { prevention.stop() }
        prevention.start()
        #expect(prevention.isActive)
        #expect(prevention.failure == nil)
        #expect(systemAssertionsOfThisProcess().contains(SleepPrevention.reason))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
        #expect(prevention.isActive)
        #expect(systemAssertionsOfThisProcess().contains(SleepPrevention.reason))

        // A second start does not take a second assertion.
        let fake = FakeAssertions()
        let held = SleepPrevention(backend: fake)
        held.start()
        held.start()
        #expect(fake.heldCount == 1)
        #expect(fake.createCount == 1)
        held.stop()
    }

    @Test func releasesOnQuit() {
        // The quit path the app runs: the delegate's willTerminate lets the assertion go, and nothing of it is left in the system.
        let delegate = AppDelegate(sleepPrevention: SleepPrevention())
        delegate.sleepPrevention.start()
        #expect(systemAssertionsOfThisProcess().contains(SleepPrevention.reason))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(!delegate.sleepPrevention.isActive)
        #expect(!systemAssertionsOfThisProcess().contains(SleepPrevention.reason))

        let fake = FakeAssertions()
        let fakeDelegate = AppDelegate(sleepPrevention: SleepPrevention(backend: fake))
        fakeDelegate.sleepPrevention.start()
        #expect(fake.heldCount == 1)
        fakeDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(fake.heldCount == 0)
        // A second quit notification, or one with nothing held, is harmless.
        fakeDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(fake.heldCount == 0)
    }

    @Test func setupFailure() {
        let refused = SleepAssertionError(call: "IOPMAssertionCreateWithName", code: Int32(bitPattern: 0xE00002C2))
        let fake = FakeAssertions(createError: refused)
        let prevention = SleepPrevention(backend: fake)
        prevention.start()  // does not throw or trap
        #expect(!prevention.isActive)
        // The failure says which call failed and with what code.
        #expect(prevention.failure?.contains(refused.description) == true)
        #expect(refused.description.contains("e00002c2"))
        prevention.stop()  // nothing held: no release asked for
        #expect(fake.heldCount == 0)

        // A release that fails is kept for diagnosis too, and does not leave the app thinking it still holds one.
        let badRelease = SleepAssertionError(call: "IOPMAssertionRelease", code: 1)
        let releasing = SleepPrevention(backend: FakeAssertions(releaseError: badRelease))
        releasing.start()
        releasing.stop()
        #expect(!releasing.isActive)
        #expect(releasing.failure?.contains(badRelease.description) == true)
    }
}
