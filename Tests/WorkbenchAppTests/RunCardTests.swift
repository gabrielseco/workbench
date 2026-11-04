import Foundation
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

/// The live run card, the pending steps under it, the Verify screenshots and the ship bar (design parity 8).
@MainActor @Suite struct RunCardTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func snapshot(_ scenario: AppScenario, feed: [FeedItem], limitMin: Int? = 30) throws -> ThreadSnapshot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".workbench"), withIntermediateDirectories: true)
        let source = repositoryRoot.appendingPathComponent("Fixtures/app/\(scenario.rawValue)/threads")
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(".workbench/threads"))
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .thread(var shown) = ProjectLoader.load(project: Project(root: root)).screen else {
            throw CocoaError(.fileReadUnknown)
        }
        shown.feed = feed
        shown.turnTimeoutMin = limitMin
        return shown
    }

    private func item(_ id: Int, _ kind: FeedItem.Kind, turn: Int = 1) -> FeedItem {
        FeedItem(id: "\(id)", seq: id, turn: turn, kind: kind)
    }

    private let stop = FeedAction(kind: .stopTurn, title: "Stop run")
    private let working = FeedItem.Kind.turn(number: 1, phase: .working, durationMs: nil, costUSD: nil)

    // MARK: The clock

    @Test func theClockSaysElapsedOfTheLimitAndPastTheLimitTheBarIsFull() {
        #expect(RunCardModel.clock(elapsed: 221, limit: 1800) == "3:41 of 30:00")
        #expect(RunCardModel.clock(elapsed: 221, limit: nil) == "3:41", "no limit: just the time")
        #expect(RunCardModel.clock(elapsed: 3725, limit: 7200) == "1:02:05 of 2:00:00")
        #expect(RunCardModel.clock(elapsed: nil, limit: 1800) == nil, "no start, no clock")
        #expect(RunCardModel.fraction(elapsed: 900, limit: 1800) == 0.5)
        #expect(RunCardModel.fraction(elapsed: 5000, limit: 1800) == 1, "past the limit it is full, never beyond")
        #expect(RunCardModel.fraction(elapsed: -4, limit: 1800) == 0)
        #expect(RunCardModel.fraction(elapsed: 10, limit: nil) == nil && RunCardModel.fraction(elapsed: 10, limit: 0) == nil)
    }

    // MARK: What the card stands for

    @Test func aWorkingTurnBecomesOneCardWithItsTasksAndTheLastThreeCalls() throws {
        let tasks: [FeedItem.PlanTask] = [
            .init(text: "A", state: .done), .init(text: "B", state: .working), .init(text: "C", state: .pending),
        ]
        let feed = [
            item(1, .goalCard(title: "t", approval: nil, criteria: 1, hash: nil), turn: 0), item(2, working),
            item(3, .plan(tasks: tasks)),
            item(4, .toolGroup(count: 2, summaries: ["Read a", "Grep b"])), item(5, .edit(file: "c.swift", tool: "Edit")),
            item(6, .toolGroup(count: 1, summaries: ["Bash build"])), item(7, .denied(tool: "Bash", input: "git push")),
            item(8, .agentText("thinking")),
        ]
        let shown = try snapshot(.running, feed: feed)
        let model = try #require(RunCardModel.make(snapshot: shown, decision: FeedDecision(primary: stop)))
        #expect(model.tasks == tasks && model.done == 1 && model.tasksTitle == "TASKS · 1 OF 3")
        #expect(model.tail == ["Grep b", "Edit c.swift", "Bash build"], "the last three, oldest first")
        #expect(model.stop == stop && model.worktree == nil)
        let open = FeedAction(kind: .openWorktree, title: "Open worktree")
        let withOpen = try #require(RunCardModel.make(snapshot: shown, decision: FeedDecision(primary: stop, secondary: open)))
        #expect(withOpen.worktree == open, "Open worktree sits beside Stop on the card")
        #expect(model.consumed == ["2", "3", "4", "5", "6"], "a refusal and the agent's words stay rows of their own")
    }

    @Test func noWorkingTurnMeansNoCard() throws {
        let ended = FeedItem.Kind.turn(number: 1, phase: .ended(result: "succeeded"), durationMs: 1, costUSD: nil)
        for kind in [ended, .turn(number: 1, phase: .orphaned, durationMs: nil, costUSD: nil)] {
            let shown = try snapshot(.running, feed: [item(2, kind)])
            #expect(RunCardModel.make(snapshot: shown, decision: FeedDecision(primary: stop)) == nil)
        }
    }

    @Test func aLogWithoutATaskListHasNoTaskSection() throws {
        let shown = try snapshot(.running, feed: [item(2, working), item(3, .toolGroup(count: 1, summaries: ["Read a"]))])
        let model = try #require(RunCardModel.make(snapshot: shown, decision: FeedDecision()))
        #expect(model.tasks.isEmpty && model.stop == nil, "no stop in the decision: the card does not pretend to have one")
    }

    @Test func onlyTheNewestWorkingTurnsItemsAreTaken() throws {
        let other = FeedItem.Kind.turn(number: 2, phase: .working, durationMs: nil, costUSD: nil)
        let feed = [
            item(2, working), item(3, .edit(file: "old.swift", tool: "Edit")), item(4, other, turn: 2),
            item(5, .edit(file: "new.swift", tool: "Edit"), turn: 2),
        ]
        let model = try #require(RunCardModel.make(snapshot: snapshot(.running, feed: feed), decision: FeedDecision()))
        #expect(model.number == 2 && model.tail == ["Edit new.swift"] && model.consumed == ["4", "5"])
    }

    // MARK: Judge and Verify, waiting

    private func goal(_ steps: [GoalModel.Step], rows: Int = 0) -> GoalModel {
        var model = GoalModel.invalid(path: "g.md", problems: [])
        model.steps = steps
        return model
    }

    private func step(_ name: String, skipped: Bool = false, unavailable: String? = nil) -> GoalModel.Step {
        GoalModel.Step(name: name, label: name.capitalized, skipped: skipped, known: true, unavailable: unavailable)
    }

    @Test func theStepsStillToComeAreTheOnesThatAreOn() {
        let both = PendingStep.pending(goal: goal([step("verifier"), step("judge")]), criteria: 5, have: [])
        #expect(both.map(\.name) == ["Judge", "Verify"])
        #expect(both[0].detail == "starts when the run ends · 5 criteria")
        #expect(PendingStep.pending(goal: goal([step("judge")]), criteria: 1, have: [])[0].detail.hasSuffix("1 criterion"))
        let judgeOff = PendingStep.pending(goal: goal([step("judge", skipped: true), step("verifier")]), criteria: 2, have: [])
        #expect(judgeOff.map(\.name) == ["Verify"])
        let noJudge = PendingStep.pending(goal: goal([step("judge", unavailable: "no criteria")]), criteria: 0, have: [])
        #expect(noJudge.isEmpty)
        let judged = PendingStep.pending(goal: goal([step("judge"), step("verifier")]), criteria: 2, have: ["judge"])
        #expect(judged.map(\.name) == ["Verify"])
        #expect(PendingStep.pending(goal: nil, criteria: 0, have: []).isEmpty, "no goal read, nothing is promised")
    }

    @Test func theStepsShownAfterTheTurnAreOnlyTheOnesRunningNow() {
        let steps = goal([step("verifier"), step("judge")])
        func shown(working: Bool, judge: Bool = false, verify: Bool = false) -> [PendingStep] {
            PendingStep.shown(goal: steps, criteria: 3, working: working, judgeRunning: judge, verifyRunning: verify)
        }
        #expect(shown(working: true).map(\.name) == ["Judge", "Verify"], "while it works both are still to come")
        #expect(shown(working: false).isEmpty, "turn over, neither started: nothing is promised that may never run")
        #expect(shown(working: false, judge: true).map(\.detail) == ["running now"])
        #expect(shown(working: false, judge: true, verify: true).map(\.name) == ["Judge", "Verify"])
    }

    @Test func theLiveTailTakesAGroupsLatestCallsNotItsFirst() throws {
        let group = item(3, .toolGroup(count: 10, summaries: ["Read 1", "Read 2", "Read 3"]))
        let turn = FeedItem(id: "2", seq: 2, turn: 1, kind: working, latest: ["Read 8", "Read 9", "Read 10"])
        let shown = try snapshot(.running, feed: [turn, group])
        let model = try #require(RunCardModel.make(snapshot: shown, decision: FeedDecision()))
        #expect(model.tail == ["Read 8", "Read 9", "Read 10"])
    }

    // MARK: Screenshots

    private func recorded(_ names: [String], in dir: URL, bytes: Int = 4) throws -> [ProofFile] {
        var events = [Event(seq: 1, ts: "2026-11-02T10:00:00.000Z", turn: 1, kind: .verifierStarted, data: [:])]
        for (index, name) in names.enumerated() {
            let data: JSONValue = [
                "source": "verifier", "name": .string(name), "path": .string("proof/\(name)"), "sha256": "x",
                "bytes": .int(bytes),
            ]
            events.append(Event(seq: 2 + index, ts: "2026-11-02T10:00:01.000Z", turn: 1, kind: .proofAdded, data: data))
        }
        events.append(Event(seq: 9, ts: "2026-11-02T10:00:02.000Z", turn: 1, kind: .verifierEnded, data: ["ok": true]))
        return try #require(ThreadState.derive(from: events, id: "t").review.verifier).proof
    }

    @Test func onlyRecordedPNGsStillAsRecordedAreShownTheFirstThreeWithTheirNamesAsCaptions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proof"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["list-states.png", "notes.txt", "chat_opens.PNG", "c.png", "d.png"]
        for name in names { try Data("abcd".utf8).write(to: dir.appendingPathComponent("proof/\(name)")) }
        let shots = ProofShot.shots(from: try recorded(names, in: dir), threadDirectory: dir)
        #expect(shots.map(\.caption) == ["list states", "chat opens", "c"])
        #expect(shots[0].url.path == dir.appendingPathComponent("proof/list-states.png").path)
    }

    @Test func aProofFileThatChangedOrWasReplacedByALinkIsNotShown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("proof"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["same.png", "grew.png", "link.png", "gone.png"]
        try Data("abcd".utf8).write(to: dir.appendingPathComponent("proof/same.png"))
        try Data("abcdefgh".utf8).write(to: dir.appendingPathComponent("proof/grew.png"))
        try Data("abcd".utf8).write(to: dir.appendingPathComponent("real.png"))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("proof/link.png"), withDestinationURL: dir.appendingPathComponent("real.png"))
        let shots = ProofShot.shots(from: try recorded(names, in: dir), threadDirectory: dir)
        #expect(shots.map(\.caption) == ["same"], "a different size, a link and a missing file are left out")
    }

    @Test func aThumbnailIsDecodedSmallAndAMissingFileIsNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("th-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = try #require(
            CGContext(
                data: nil, width: 2000, height: 1200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let big = try #require(context.makeImage())
        let url = dir.appendingPathComponent("big.png")
        let png = try #require(NSBitmapImageRep(cgImage: big).representation(using: .png, properties: [:]))
        try png.write(to: url)
        let thumb = try #require(ProofThumbnail.decode(url))
        #expect(max(thumb.width, thumb.height) <= ProofShot.thumbnailPixels, "a large screenshot costs a small image")
        #expect(ProofThumbnail.decode(dir.appendingPathComponent("gone.png")) == nil)
    }

    // MARK: Ready to ship

    @Test func theShipBarKeepsEveryOtherActionInItsMenu() {
        let decision = FeedDecision(
            primary: FeedAction(kind: .ship, title: "Ship"),
            more: [
                FeedAction(kind: .sendBack, title: "Send back…"), FeedAction(kind: .openWorktree, title: "Open worktree"),
                FeedAction(kind: .newGoal, title: "New goal"),
            ])
        #expect(DecisionCard.shipMenu(decision).map(\.kind) == [.openWorktree, .newGoal], "Request changes is its own button")
    }

    @Test func theShipBarIsForTheShipStepOnly() {
        #expect(DecisionCard.isReadyToShip(FeedDecision(primary: FeedAction(kind: .ship, title: "Ship"))))
        #expect(!DecisionCard.isReadyToShip(FeedDecision(primary: FeedAction(kind: .accept, title: "Accept work"))))
        #expect(!DecisionCard.isReadyToShip(FeedDecision()))
    }

    // MARK: Drawn

    private func drawn(_ view: some View, dark: Bool) throws -> CGImage {
        let framed = view.frame(width: 640).padding(20).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    @Test func theCardAndTheShipBarDrawInBothAppearances() throws {
        let tasks: [FeedItem.PlanTask] = [.init(text: "Add rows", state: .done), .init(text: "Wire it", state: .working)]
        let started = Event(seq: 1, ts: "2026-11-02T10:00:00.000Z", turn: 1, kind: .turnStarted, data: [:])
        let progress = ThreadState.derive(from: [started], id: "t").progress
        let model = RunCardModel(
            number: 1, progress: progress, limit: 1800, tasks: tasks, tail: ["Read a.swift", "Edit b.swift"], stop: stop,
            worktree: FeedAction(kind: .openWorktree, title: "Open worktree"), consumed: [])
        let decision = FeedDecision(
            primary: FeedAction(kind: .ship, title: "Ship"), more: [FeedAction(kind: .sendBack, title: "Send back…")])
        let ship = DecisionCard(step: .ship, why: "", decision: decision, perform: { _ in }, route: "wb/g-1 → main")
        let directory = ProcessInfo.processInfo.environment["WORKBENCH_RENDER_DIR"]
        for dark in [false, true] {
            let card = AnyView(RunCardView(model: model, perform: { _ in }))
            for (name, view) in [("run-card", card), ("ship-bar", AnyView(ship))] {
                let image = try drawn(view, dark: dark)
                #expect(image.height > 60, "\(name) takes room")
                if let directory {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                    let folder = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }
}
