import Foundation
import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// Records what would have been posted; nothing reaches the system.
final class RecordingNotifier: Notifier, @unchecked Sendable {
    private let lock = NSLock()
    private var notices: [Notice] = []
    var result = PostResult.posted
    var posted: [Notice] { lock.withLock { notices } }
    func post(_ notice: Notice) async -> PostResult {
        lock.withLock { notices.append(notice) }
        return result
    }
}

@MainActor @Suite struct NotificationRuleTests {
    private struct Rig {
        var center: AttentionCenter
        var notifier: RecordingNotifier
        var prefs: MemoryPreferences
    }

    private func rig(paused: Bool = false) -> Rig {
        let prefs = MemoryPreferences()
        prefs.notificationsPaused = paused
        let notifier = RecordingNotifier()
        return Rig(center: AttentionCenter(preferences: prefs, notifier: notifier), notifier: notifier, prefs: prefs)
    }

    private func failed(_ name: String, at seconds: TimeInterval) async throws -> TaskEntry {
        let (_, entries) = try await AttentionItemsTests.entries()
        let base = try #require(entries.first { $0.id == "weekly-report" })
        var entry = AttentionItemsTests.task(base, runs: [AttentionItemsTests.run(.failed, at: seconds)])
        entry.summary.name = name
        return entry
    }

    private func look(
        _ center: AttentionCenter, _ project: String, thread: ThreadAttention? = nil, tasks: [TaskEntry]?
    ) async {
        await center.observe(project: "/work/\(project)", projectName: project, thread: thread, tasks: tasks)
    }

    @Test func replay() async throws {
        let r = rig()
        let (center, notifier) = (r.center, r.notifier)
        let a = try await failed("alpha", at: 100)
        let b = try await failed("beta", at: 200)
        let review = AttentionItemsTests.thread("Review · turn 2 done", since: 7)
        // The app opens on a state that already needs you: counted, never announced.
        await look(center, "proj", thread: review, tasks: [a])
        #expect(center.items.count == 2 && notifier.posted.isEmpty)
        // A second poll, a wake from sleep, a relaunch of the same look: nothing.
        await look(center, "proj", thread: review, tasks: [a])
        #expect(notifier.posted.isEmpty)
        // A task breaks overnight: one notice, naming the project and the reason.
        await look(center, "proj", thread: review, tasks: [a, b])
        #expect(notifier.posted.count == 1)
        let notice = try #require(notifier.posted.first)
        #expect(notice.title == "proj" && notice.body.hasPrefix("beta failed: the check failed") && notice.route == .task("beta"))
        #expect(notice.id.hasPrefix("task:beta:"))
        // The same failure seen again, and a failed read: nothing more, and the count holds.
        await look(center, "proj", thread: review, tasks: [a, b])
        await look(center, "proj", thread: review, tasks: nil)
        #expect(notifier.posted.count == 1 && center.items.count == 3)
        // The thread moves on to a new reason (a new turn ended): that is news.
        let again = AttentionItemsTests.thread("Review · turn 3 done", since: 12)
        await look(center, "proj", thread: again, tasks: [a, b])
        #expect(notifier.posted.count == 2 && notifier.posted.last?.route == .thread("t1"))
        // The same CI failure on the same commit twice is one notice; another commit is another.
        let ci = AttentionItemsTests.thread("CI failed: unit", since: 20, commit: "abc")
        await look(center, "proj", thread: ci, tasks: [a, b])
        await look(center, "proj", thread: again, tasks: [a, b])
        await look(center, "proj", thread: ci, tasks: [a, b])
        #expect(notifier.posted.count == 3)
        let newer = AttentionItemsTests.thread("CI failed: unit", since: 20, commit: "def")
        await look(center, "proj", thread: newer, tasks: [a, b])
        #expect(notifier.posted.count == 4)
    }

    @Test func theFirstReadOfTheTasksIsStillTheBaseline() async throws {
        // The window opens before the first poll of the tasks: the first look has only the thread, the next has the tasks. What
        // already failed yesterday is counted and not announced; the next failure is.
        let r = rig()
        let (center, notifier) = (r.center, r.notifier)
        let review = AttentionItemsTests.thread("Review · turn 2 done", since: 7)
        let yesterday = try await failed("alpha", at: 100)
        await look(center, "proj", thread: review, tasks: nil)
        #expect(center.items.count == 1)
        await look(center, "proj", thread: review, tasks: [yesterday])
        #expect(center.items.count == 2 && notifier.posted.isEmpty)
        await look(center, "proj", thread: review, tasks: [yesterday, try await failed("beta", at: 200)])
        #expect(notifier.posted.count == 1 && notifier.posted[0].route == .task("beta"))
        #expect(notifier.posted[0].project == "/work/proj")
    }

    @Test func aCIFailureThatArrivesAfterTheThreadIsStillThePastWhenTheAppOpened() async throws {
        let r = rig()
        let (center, notifier) = (r.center, r.notifier)
        let waiting = ThreadAttention(id: "t1", title: "Paginate", attention: .none, ciLoaded: false)
        await look(center, "proj", thread: waiting, tasks: [])
        // GitHub answers: the pull request's CI was already failing when the app opened.
        var failing = AttentionItemsTests.thread("CI failed: unit", since: 20, commit: "abc")
        failing.ciLoaded = true
        await look(center, "proj", thread: failing, tasks: [])
        #expect(center.items.count == 1 && notifier.posted.isEmpty)
        // A new commit failing is news.
        var next = AttentionItemsTests.thread("CI failed: unit", since: 20, commit: "def")
        next.ciLoaded = true
        await look(center, "proj", thread: next, tasks: [])
        #expect(notifier.posted.count == 1)
    }

    @Test func aReasonAnnouncedBeforeIsNotAnnouncedAgainAfterARelaunch() async throws {
        let prefs = MemoryPreferences()
        let notifier = RecordingNotifier()
        let first = AttentionCenter(preferences: prefs, notifier: notifier)
        let failing = AttentionItemsTests.thread("CI failed: unit", since: 20, commit: "abc")
        let green = ThreadAttention(id: "t1", title: "Paginate", attention: .none)
        await look(first, "proj", thread: green, tasks: [])
        await look(first, "proj", thread: failing, tasks: [])
        #expect(notifier.posted.count == 1)
        #expect(prefs.announcedAttention == ["/work/proj|thread:t1:20:abc"])
        // CI goes green, the app is relaunched (a new centre, the same preferences), and the same commit fails again.
        let second = AttentionCenter(preferences: prefs, notifier: notifier)
        await look(second, "proj", thread: green, tasks: [])
        await look(second, "proj", thread: failing, tasks: [])
        #expect(notifier.posted.count == 1, "one notification per reason per commit, past a relaunch")
        // Another commit is another reason.
        await look(second, "proj", thread: AttentionItemsTests.thread("CI failed: unit", since: 20, commit: "def"), tasks: [])
        #expect(notifier.posted.count == 2)
    }

    @Test func theAnnouncedMemoryIsPerProjectAndBounded() async throws {
        let prefs = MemoryPreferences()
        let notifier = RecordingNotifier()
        let center = AttentionCenter(preferences: prefs, notifier: notifier)
        let a = try await failed("alpha", at: 100)
        await look(center, "one", tasks: [])
        await look(center, "one", tasks: [a])
        // The same task and run in another project is its own reason.
        await look(center, "two", tasks: [])
        await look(center, "two", tasks: [a])
        #expect(notifier.posted.count == 2)
        #expect(Set(prefs.announcedAttention) == ["/work/one|task:alpha:100", "/work/two|task:alpha:100"])
        prefs.announcedAttention = (0..<300).map { "p|task:t:\($0)" }
        let (_, entries) = try await AttentionItemsTests.entries()
        var next = try #require(entries.first { $0.id == "weekly-report" })
        next = AttentionItemsTests.task(next, runs: [AttentionItemsTests.run(.failed, at: 500)])
        next.summary.name = "beta"
        await look(center, "two", tasks: [a, next])
        #expect(prefs.announcedAttention.count == AttentionCenter.seenLimit)
        #expect(prefs.announcedAttention.last == "/work/two|task:beta:500")
    }

    @Test func seenBelongsToItsProject() async throws {
        let r = rig()
        let (center, prefs) = (r.center, r.prefs)
        let a = try await failed("alpha", at: 100)
        await look(center, "one", tasks: [a])
        center.markSeen(shown: a)
        #expect(center.items.isEmpty)
        // Another project with a task of the same name and the same run is another reason.
        await look(center, "two", tasks: [a])
        #expect(center.items.count == 1)
        #expect(prefs.seenAttention.count == 1 && prefs.seenAttention[0].hasPrefix("/work/one|"))
    }

    @Test func switchingProjectIsANewBaseline() async throws {
        let r = rig()
        let (center, notifier) = (r.center, r.notifier)
        let a = try await failed("alpha", at: 100)
        await look(center, "one", tasks: [a])
        let b = try await failed("beta", at: 200)
        await look(center, "one", tasks: [a, b])
        #expect(notifier.posted.count == 1)
        // Another project: what is already there is its baseline, and the old one's items are not counted.
        await look(center, "two", tasks: [b])
        #expect(notifier.posted.count == 1 && center.items.count == 1)
        await look(center, "two", tasks: [])
        #expect(center.items.isEmpty)
        // No project at all.
        await center.observe(project: nil, projectName: "", thread: nil, tasks: nil)
        #expect(center.items.isEmpty)
    }

    @Test func pausedPostsNothing() async throws {
        let r = rig(paused: true)
        let (center, notifier, prefs) = (r.center, r.notifier, r.prefs)
        let a = try await failed("alpha", at: 100)
        await look(center, "proj", tasks: [])
        await look(center, "proj", tasks: [a])
        #expect(notifier.posted.isEmpty && center.items.count == 1, "the count shows, nothing is posted")
        // Unpausing does not announce what happened while paused.
        center.paused = false
        _ = prefs
        await look(center, "proj", tasks: [a])
        #expect(notifier.posted.isEmpty)
        let b = try await failed("beta", at: 200)
        await look(center, "proj", tasks: [a, b])
        #expect(notifier.posted.count == 1)
    }

    @Test func deniedIsSaidOnce() async throws {
        let r = rig()
        let (center, notifier) = (r.center, r.notifier)
        notifier.result = .denied
        let a = try await failed("alpha", at: 100)
        await look(center, "proj", tasks: [])
        await look(center, "proj", tasks: [a])
        #expect(center.notificationsDenied && center.items.count == 1)
        #expect(!center.deniedWasShown)
        center.sayDeniedOnce()
        #expect(center.deniedWasShown)
    }

    @Test func noBundleNoCenter() async {
        // This test process is not an app bundle: the system centre must not be asked for (it ends the process).
        #expect(!SystemNotifier.hasBundle)
        let result = await SystemNotifier().post(Notice(id: "x", title: "t", body: "b", route: .task("x"), project: "/p"))
        #expect(result == .denied)
    }
}
