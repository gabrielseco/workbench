import AppKit
import SwiftUI
import Testing
import WorkbenchCore

@testable import WorkbenchApp

@MainActor private var keptRenderFixtures: [AppFixture] = []

/// Draws the Goal screen's blocks with `ImageRenderer` for a draft (editable) and an approved goal (read-only). The PNGs land in
/// `WORKBENCH_RENDER_DIR` (else the temp folder); a blank render fails.
@MainActor @Suite struct GoalBlocksRenderTests {
    private let goalBody = """

        ## Request

        Add exponential retry with jitter to the sync client, at most five attempts.

        ## Criteria

        - [c1] The client retries on 5xx and network errors, not on 4xx.
          - proof: test: SyncClientTests/retries
        - [c2] The delay grows exponentially with jitter and is capped at 30 seconds.
          - proof: `swift test` passes
        - [c3] The settings screen shows no change.
          - proof: screenshot: settings

        ## Out of scope

        - Changing the request timeout.
        - Retrying uploads.

        """

    private func render(_ name: String, approved: Bool) async throws -> ProjectStore {
        let fixture = try await AppFixture()
        keptRenderFixtures.append(fixture)
        try await fixture.addThread("t1", approved: false)
        let front = """
            ---
            id: t1
            title: Retry with backoff
            base: main
            budget_usd: 5
            turn_timeout_min: 30
            skip: judge
            read_also: ../api
            ---
            """
        var file = try GoalFile.parse(front + goalBody)
        if approved { file = try file.approving() }
        try file.text.write(to: fixture.project.goalURL("t1"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: fixture.project.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            read_also = ["../backend"]
            [tools]
            available = ["Read", "Bash"]
            allowed = ["Read", "Bash(swift test:*)"]
            [review]
            stages = ["pr-review", "design"]
            [review.stage.design]
            skill = "d.md"
            """.write(to: fixture.project.configURL, atomically: true, encoding: .utf8)
        let store = ProjectStore(preferences: MemoryPreferences(projectPath: nil))
        #expect(await store.open(fixture.root))
        let goal = try #require(store.goal)
        guard case .thread(let snapshot) = store.screen else {
            Issue.record("\(store.screen)")
            return store
        }
        #expect(goal.editable == !approved)
        let view = GoalView(snapshot: snapshot, goal: goal, store: store).content.frame(width: 760, height: 1000, alignment: .top)
            .background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "\(name) did not render")
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let base = ProcessInfo.processInfo.environment["WORKBENCH_RENDER_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: base).appendingPathComponent("workbench-app-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        return store
    }

    @Test func aDraftShowsItsBlocksForEditing() async throws { _ = try await render("goal-blocks-draft", approved: false) }

    @Test func anApprovedGoalShowsTheSameBlocksReadOnly() async throws {
        _ = try await render("goal-blocks-approved", approved: true)
    }
}
