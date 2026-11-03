import Foundation
import Testing

@testable import WorkbenchCore

/// A chat made into a goal (P22 slice 6b): the conversation is the request, and the goal is written into the same thread.
@Suite(.processGate) struct ChatGoalTests {
    private func chat(
        _ d: Drafting, _ target: ChatTarget = .newThread(name: "idea"), _ message: String = "retry uploads?"
    ) async throws -> ChatResult {
        try await d.fx.service.chat(target: target, message: message, config: d.config, environment: d.environment)
    }

    private func draft(
        _ d: Drafting, _ id: String, timeout: TimeInterval = 30, attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> GoalDraftResult {
        try await d.fx.service.draftGoal(
            target: .fromChat(id: id, base: "main"), request: "", config: d.config, environment: d.environment, timeout: timeout,
            attach: attach)
    }

    /// A chat with one finished exchange whose fake agent answers with a goal when drafting.
    private func conversation() async throws -> (Drafting, String) {
        let d = try await drafting(answer: "What should happen after the fifth try?")
        let first = try await chat(d)
        try d.codex?.put("answer", proposalJSON)
        return (d, first.id)
    }

    private func kinds(_ d: Drafting, _ id: String) throws -> [String] {
        try EventLogReader.read(at: d.fx.project.eventsURL(id)).events.map { $0.kind.rawValue }
    }

    private func state(_ d: Drafting, _ id: String) -> ThreadState { ThreadStore(project: d.fx.project).state(of: id) }

    // MARK: The draft

    @Test func theGoalIsWrittenIntoTheSameThreadAsADraft() async throws {
        let (d, id) = try await conversation()
        let result = try await draft(d, id)
        #expect(result.id == id && result.proposal?.title == "Add retry" && result.failure == nil, "\(result)")
        #expect(d.threads == [id], "no other thread")
        let text = try String(contentsOf: d.fx.project.goalURL(id), encoding: .utf8)
        let goal = try GoalFile.parse(text).goal
        #expect(goal.approval == .draft && goal.title == "Add retry" && goal.base == "main" && goal.criteria.count == 2)
        #expect(!text.contains("approved"), "never approved by the draft")
        let kept = d.fx.project.threadDirectory(id).appendingPathComponent("goal-draft/proposal.json")
        #expect(FileManager.default.fileExists(atPath: kept.path))
        let expected = ["agent.attempt.started", "goal.draft.started", "agent.attempt.ended", "goal.saved", "goal.draft.finished"]
        #expect(Array(try kinds(d, id).suffix(5)) == expected)
        let events = try EventLogReader.read(at: d.fx.project.eventsURL(id)).events
        #expect(events.last { $0.kind == .goalDraftFinished }?.data["from_chat"] == true)
        #expect(events.first { $0.kind == .goalDraftStarted }?.data["from_chat"] == true)
        #expect(state(d, id).isChat && state(d, id).decision == nil, "it began as a chat and is still open")
    }

    @Test func theConversationIsTheRequestQuotedLineByLineWithoutBeingCut() async throws {
        let d = try await drafting(answer: "Anything else?")
        let long = String(repeating: "word ", count: 1_800) + "\n## A heading the person typed"
        let first = try await chat(d, .newThread(name: "idea"), long)
        _ = try await chat(d, .existing(id: first.id), long)
        _ = try await chat(d, .existing(id: first.id), long)
        try d.codex?.put("answer", proposalJSON)
        _ = try await draft(d, first.id)
        let prompt = (d.codex?.calls ?? []).joined(separator: "\n")
        #expect(prompt.contains("The conversation"), "headed as the conversation, not a rough request")
        #expect(prompt.contains("> ## A heading the person typed"), "quoted: a heading in it is not structure")
        #expect(prompt.contains("> The person said:") && prompt.contains("> You said:"), "who said what is quoted with the words")
        #expect(prompt.contains("> Anything else?"), "the agent's own reply is in it")
        #expect(prompt.contains("past the limit") == false)
        #expect(long.utf8.count * 3 > GoalDraft.requestLimit, "longer than a rough request may be")
    }

    @Test func theAgentWorksInAnEmptyFolderOutsideTheCheckoutThatIsRemoved() async throws {
        let (d, id) = try await conversation()
        _ = try await draft(d, id)
        let cwd = try #require(d.codex?.read("cwds")?.split(separator: "\n").last.map(String.init))
        #expect(!cwd.hasPrefix(d.fx.repo.resolvingSymlinksInPath().path), "not in the checkout: \(cwd)")
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: cwd).deletingLastPathComponent().path))
    }

    // MARK: A draft that fails

    @Test func aFailedDraftLeavesTheThreadAChatWithNoGoalAndSaysSoInTheLog() async throws {
        let (d, id) = try await conversation()
        try d.codex?.put("answer", "I would rather not.")
        let result = try await draft(d, id)
        #expect(result.id == nil && result.proposal == nil && result.failure != nil)
        #expect(!FileManager.default.fileExists(atPath: d.fx.project.goalURL(id).path))
        let finished = try EventLogReader.read(at: d.fx.project.eventsURL(id)).events.last { $0.kind == .goalDraftFinished }
        #expect(finished?.data["ok"] == false && finished?.data["from_chat"] == true)
        let again = try await chat(d, .existing(id: id), "so?")
        #expect(again.end == "ok", "the chat can go on")
    }

    @Test func crashTimeoutAndStopEachEndTheDraftAndLeaveNoGoal() async throws {
        for ending in ["crash", "hang", "stop"] {
            let (d, id) = try await conversation()
            if ending == "crash" { try d.codex?.put("crash", "") } else { try d.codex?.put("hang", "") }
            let result = try await draft(d, id, timeout: ending == "hang" ? 1 : 30, attach: { execution in
                if ending == "stop" { Task { try? await Task.sleep(nanoseconds: 300_000_000); execution.stop() } }
            })
            #expect(result.id == nil && result.failure != nil, "\(ending): \(String(describing: result.failure))")
            #expect(!FileManager.default.fileExists(atPath: d.fx.project.goalURL(id).path), "\(ending)")
            let events = try EventLogReader.read(at: d.fx.project.eventsURL(id)).events
            let starts = events.filter { $0.kind == .goalDraftStarted }.count
            let ends = events.filter { $0.kind == .goalDraftFinished }.count
            #expect(starts == 1 && ends == 1, "one end per start: \(ending)")
            #expect(state(d, id).chat?.open == false)
        }
    }

    @Test func aDraftAKilledProcessLeftOpenIsClosedBeforeTheNext() async throws {
        let (d, id) = try await conversation()
        let log = try EventLogWriter.open(at: d.fx.project.eventsURL(id))
        try await log.append(.goalDraftStarted, data: ["provider": "codex", "from_chat": true])
        await log.close()
        let result = try await draft(d, id)
        #expect(result.id == id)
        let events = try EventLogReader.read(at: d.fx.project.eventsURL(id)).events
        #expect(events.contains { $0.kind == .goalDraftFinished && $0.data["synthetic"] == true })
        #expect(events.filter { $0.kind == .goalDraftStarted }.count == events.filter { $0.kind == .goalDraftFinished }.count)
    }

    // MARK: Refusals

    @Test func everyRefusalSpendsAndWritesNothing() async throws {
        let (d, id) = try await conversation()
        let runs = d.codex?.runs
        let before = try Data(contentsOf: d.fx.project.eventsURL(id))
        func refused(_ expected: GoalDraftRefusal, target: GoalDraftTarget, config: Config? = nil) async {
            await #expect(throws: expected) {
                _ = try await d.fx.service.draftGoal(
                    target: target, request: "", config: config ?? d.config, environment: d.environment)
            }
        }
        var noAgent = d.config
        noAgent.agents.goal = nil
        await refused(.noGoalAgent, target: .fromChat(id: id, base: nil), config: noAgent)
        await refused(.noThread("g-nothing"), target: .fromChat(id: "g-nothing", base: nil))
        #expect(d.codex?.runs == runs)
        #expect(try Data(contentsOf: d.fx.project.eventsURL(id)) == before, "nothing was written")
        let other = try await drafting()
        let plain = try await other.fx.service.newThread(name: "plain", config: other.config)
        await #expect(throws: GoalDraftRefusal.notAChat(plain)) {
            _ = try await other.fx.service.draftGoal(
                target: .fromChat(id: plain, base: nil), request: "", config: other.config, environment: other.environment)
        }
        #expect(other.codex?.runs == 0)
    }

    @Test func aChatWithNoFinishedExchangeHasNothingToDraftFrom() async throws {
        let d = try await drafting()
        try d.codex?.put("crash", "")
        let first = try await chat(d)
        #expect(first.end == "failed")
        try d.codex?.put("answer", proposalJSON)
        let runs = d.codex?.runs
        await #expect(throws: GoalDraftRefusal.chatNotStarted(first.id)) { _ = try await draft(d, first.id) }
        #expect(d.codex?.runs == runs)
    }

    @Test func aChatThatHasAGoalIsRefusedAndPointedAtReplace() async throws {
        let (d, id) = try await conversation()
        _ = try await draft(d, id)
        let runs = d.codex?.runs
        await #expect(throws: GoalDraftRefusal.chatHasGoal(id)) { _ = try await draft(d, id) }
        #expect("\(GoalDraftRefusal.chatHasGoal(id))".contains("--replace"))
        #expect(d.codex?.runs == runs)
    }

    @Test func anEndedChatAndADoctorRunAreRefused() async throws {
        let (d, id) = try await conversation()
        let doctor = try ProjectLock.acquire(d.fx.project)
        await #expect(throws: GoalDraftRefusal.doctorRunning) { _ = try await draft(d, id) }
        ProjectLock.release(doctor)
        _ = try await d.fx.service.abandon(id: id)
        await #expect(throws: GoalDraftRefusal.ended("abandoned")) { _ = try await draft(d, id) }
    }

    // MARK: After the draft

    @Test func theThreadIsAGoalThreadNowAndTakesNoMoreChat() async throws {
        let (d, id) = try await conversation()
        _ = try await draft(d, id)
        await #expect(throws: ChatRefusal.hasGoal(id)) { _ = try await chat(d, .existing(id: id), "one more thing") }
        #expect(state(d, id).chat?.messages.count == 2, "the conversation is as it was")
        let approved = try await d.fx.service.approve(id: id, config: d.config)
        #expect(approved.goal.approval == .approved)
        let redrafted = try await d.fx.service.draftGoal(
            target: .replace(id: id), request: "retry with jitter instead", config: d.config, environment: d.environment)
        #expect(redrafted.id == id && redrafted.replaced && redrafted.wasApproved, "the goal can be redrafted as any")
    }
}
