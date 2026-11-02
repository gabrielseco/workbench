import AppKit
import SwiftUI
import Testing

@testable import WorkbenchApp
@testable import WorkbenchCore

@MainActor private var keptAdviceFixtures: [AppFixture] = []

/// The Run settings' switch for the advice (P22 slice 4b): what it shows comes from the function a run asks, and a press writes the edit
/// that leaves the goal saying only what differs from the project.
@MainActor @Suite struct AutoAdviceSettingTests {
    private func goal(_ key: Bool?) throws -> Goal {
        let line = key.map { "auto_advance: \($0)\n" } ?? ""
        return try GoalFile.parse(
            """
            ---
            id: g-1
            title: A goal
            status: draft
            base: main
            budget_usd: 5.00
            turn_timeout_min: 30
            \(line)---

            ## Request

            Do it.

            ## Criteria

            - [c1] It works.
              - proof: test: Thing/works
            """
        ).goal
    }

    private func config(_ review: String) throws -> Config {
        try Config.parse(
            "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n[review]\nstages = [\"pr-review\", \"design\"]\n\(review)\n"
                + "[review.stage.design]\nskill = \"d.md\"\n")
    }

    // MARK: What it says

    @Test func theLineSaysWhatARunWillDoAndWhereItComesFrom() throws {
        let off = AutoAdviceSetting.read(goal: try goal(nil), config: try config(""))
        #expect(!off.on && off.line == "Off" && off.source == "From the project's config." && off.adjustable)

        let project = AutoAdviceSetting.read(goal: try goal(nil), config: try config("auto_advance = true"))
        #expect(project.on && project.steps == ["judge", "design"])
        #expect(project.line == "Runs: judge, design" && project.source == "From the project's config.")

        let own = AutoAdviceSetting.read(goal: try goal(true), config: try config(""))
        #expect(own.on && own.line == "Runs: judge, design" && own.source == "Set for this goal.")

        let overridden = AutoAdviceSetting.read(goal: try goal(false), config: try config("auto_advance = true"))
        #expect(!overridden.on && overridden.line == "Off" && overridden.source == "Set for this goal.")
    }

    @Test func aProjectsOwnAutoListDecidesAndTheSwitchSaysItAddsNothing() throws {
        let listed = AutoAdviceSetting.read(goal: try goal(nil), config: try config("auto = [\"design\"]"))
        #expect(listed.steps == ["design"] && listed.on && !listed.adjustable)
        #expect(listed.line == "The project's [review] auto lists design: the switch adds nothing.")
        let both = try config("auto = [\"judge\", \"design\"]")
        let stillListed = AutoAdviceSetting.read(goal: try goal(false), config: both)
        #expect(stillListed.steps == ["judge", "design"] && !stillListed.adjustable, "a goal's false does not beat a list")
        #expect(stillListed.source == "From the project's config.")
    }

    @Test func withoutAConfigNothingRuns() throws {
        let none = AutoAdviceSetting.read(goal: try goal(nil), config: nil)
        #expect(!none.on && none.line == "Off")
    }

    // MARK: What a press writes

    @Test func aPressWritesTheEditThatSaysOnlyWhatDiffersFromTheProject() throws {
        struct Case {
            var goal: Bool?
            var project: String
            var edit: GoalEdit
        }
        let cases = [
            Case(goal: nil, project: "", edit: .setAutoAdvance(true)),  // off -> on, the project is off: say it
            Case(goal: nil, project: "auto_advance = true", edit: .setAutoAdvance(false)),  // on -> off, the project is on
            Case(goal: true, project: "", edit: .setAutoAdvance(nil)),  // on -> off, the project is off: the key says nothing
            Case(goal: false, project: "auto_advance = true", edit: .setAutoAdvance(nil)),  // off -> on, project on: clear
            Case(goal: false, project: "", edit: .setAutoAdvance(true)),  // a goal's false, the project off: on needs the key
            Case(goal: true, project: "auto_advance = true", edit: .setAutoAdvance(false)),  // on by both: off needs the key
        ]
        for item in cases {
            let setting = AutoAdviceSetting.read(goal: try goal(item.goal), config: try config(item.project))
            #expect(setting.toggled() == item.edit, "goal \(String(describing: item.goal)), project '\(item.project)'")
        }
    }

    // MARK: Through the store

    private func store(_ review: String) async throws -> (ProjectStore, [GoalEdit]) {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var edits: [GoalEdit] = []
        }
        let fixture = try await AppFixture()
        keptAdviceFixtures.append(fixture)
        try await fixture.addThread("t1", approved: false)
        let text = "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n[review]\n\(review)\n"
        try text.write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        let seen = Seen()
        let actions = GoalActions(editGoal: { _, _, edit in seen.lock.withLock { seen.edits.append(edit) } })
        let preferences = MemoryPreferences()
        preferences.chatFeed = true
        let store = ProjectStore(preferences: preferences, actions: actions)
        #expect(await store.open(fixture.root))
        await store.editGoal { $0.advice.toggled() }
        return (store, seen.lock.withLock { seen.edits })
    }

    @Test func theSwitchWritesItsEditThroughTheStoreLikeTheOtherSwitches() async throws {
        let (off, offEdits) = try await store("")
        #expect(off.goal?.advice.on == false && offEdits == [.setAutoAdvance(true)])
        let (on, onEdits) = try await store("auto_advance = true")
        #expect(on.goal?.advice.steps == ["judge"] && onEdits == [.setAutoAdvance(false)])
    }

    // MARK: What it draws

    private func image<V: View>(_ view: V) throws -> CGImage {
        let framed = view.frame(width: 260, height: 760).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.feedDrawsEagerly, true)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    @Test func theInspectorDrawsTheSwitchTheLineAndTheSource() async throws {
        let (store, _) = try await store("")
        guard case .thread(let shown) = store.screen, let base = store.goal else { throw Failure.notAThread }
        func drawn(_ advice: AutoAdviceSetting, named name: String? = nil) throws -> Data? {
            var goal = base
            goal.advice = advice
            let drawn = try image(RunSettingsInspector(snapshot: shown, goal: goal, store: store))
            if let name, let png = NSBitmapImageRep(cgImage: drawn).representation(using: .png, properties: [:]) {
                let path = ProcessInfo.processInfo.environment["WORKBENCH_RENDER_DIR"] ?? NSTemporaryDirectory()
                let folder = URL(fileURLWithPath: path).appendingPathComponent("workbench-app-renders")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("\(name).png"))
            }
            return drawn.dataProvider?.data as Data?
        }
        typealias Advice = AutoAdviceSetting
        let both = ["judge", "design"]
        let off = try drawn(Advice(goalSays: nil, projectSwitch: false, projectList: [], steps: []), named: "advice-off")
        let on = try drawn(Advice(goalSays: nil, projectSwitch: true, projectList: [], steps: both), named: "advice-on")
        let own = try drawn(Advice(goalSays: true, projectSwitch: false, projectList: [], steps: both), named: "advice-own")
        let project = Advice(goalSays: nil, projectSwitch: false, projectList: both, steps: both)
        let listed = try drawn(project, named: "advice-project-list")
        #expect(off != on, "the switch and the line")
        #expect(on != own, "where it comes from")
        #expect(on != listed, "the project's own list")
    }

    private enum Failure: Error { case notAThread }
}
