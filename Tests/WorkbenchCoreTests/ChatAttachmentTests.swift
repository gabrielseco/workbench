import Foundation
import Testing

@testable import WorkbenchCore

/// Screenshots in a chat: checked before anything starts, kept with the thread, and shown to the agent again on every later turn.
@Suite(.processGate) struct ChatAttachmentTests {
    private func chat(
        _ d: Drafting, _ target: ChatTarget = .newThread(name: "idea"), _ message: String = "what is wrong here?",
        attachments: [URL] = [], environment: [String: String]? = nil, timeout: TimeInterval = 30,
        attach: @Sendable (AgentExecution) -> Void = { _ in }
    ) async throws -> ChatResult {
        try await d.fx.service.chat(
            target: target, message: message, config: d.config, attachments: attachments,
            environment: environment ?? d.environment, timeout: timeout, attach: attach)
    }

    private func events(_ d: Drafting, _ id: String) throws -> [Event] {
        try EventLogReader.read(at: d.fx.project.eventsURL(id)).events
    }

    private func state(_ d: Drafting, _ id: String) -> ThreadState { ThreadStore(project: d.fx.project).state(of: id) }

    private func folder(_ d: Drafting, _ id: String) -> URL {
        d.fx.project.threadDirectory(id).appendingPathComponent(Chat.imagesFolder)
    }

    // MARK: Refusals

    @Test func refusesBadImages() async throws {
        let d = try await drafting()
        let notAnImage = try d.write("shot.png", Data("just text".utf8))
        await #expect(throws: (any Error).self) { _ = try await chat(d, attachments: [notAnImage]) }
        do {
            _ = try await chat(d, attachments: [notAnImage])
            Issue.record("a text file named .png was accepted")
        } catch let refusal as ChatRefusal {
            #expect(refusal == .attachment("shot.png is not a PNG, JPEG, GIF or WebP image."), "\(refusal)")
        }
        let good = try d.image("ok.png")
        do {
            _ = try await chat(d, attachments: Array(repeating: good, count: GoalAttachments.maxCount + 1))
            Issue.record("six images were accepted in one message")
        } catch let refusal as ChatRefusal {
            #expect(refusal == .attachment("\(GoalAttachments.Refusal.tooMany)"))
        }
        #expect(d.threads.isEmpty, "no thread was made")
        #expect(d.codex?.runs == 0, "no agent was started, so nothing was spent")
    }

    @Test func capsImagesPerChat() async throws {
        let d = try await drafting()
        let shot = try d.image("a.png")
        let first = try await chat(d, attachments: Array(repeating: shot, count: 5))
        _ = try await chat(d, .existing(id: first.id), attachments: Array(repeating: shot, count: 5))
        #expect(state(d, first.id).chat?.messages.flatMap(\.images).count == Chat.maxImages)
        let runs = d.codex?.runs
        let before = try events(d, first.id).count
        do {
            _ = try await chat(d, .existing(id: first.id), attachments: [shot])
            Issue.record("an eleventh screenshot was accepted")
        } catch let refusal as ChatRefusal {
            #expect(refusal == .tooManyImages)
            #expect("\(refusal)".contains("\(Chat.maxImages)"), "it names the cap")
        }
        #expect(d.codex?.runs == runs, "nothing was started")
        #expect(try events(d, first.id).count == before, "nothing was written to the log")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder(d, first.id).path)
        #expect(files.count == Chat.maxImages, "and no file was kept")
        // A message with no screenshot is still welcome.
        let plain = try await chat(d, .existing(id: first.id), "and without a picture?")
        #expect(plain.end == "ok")
    }

    // MARK: The log

    @Test func recordsNamesInLog() async throws {
        let d = try await drafting()
        let first = try d.image("shot-b.png")
        let second = try d.image("a.jpeg", jpeg: true)
        let result = try await chat(d, attachments: [first, second])
        let id = result.id
        let said = try #require(try events(d, id).first { $0.kind == .chatMessage })
        #expect(said.data["images"] == .array([.string("1.png"), .string("2.jpg")]))
        let logText = try String(contentsOf: d.fx.project.eventsURL(id), encoding: .utf8)
        #expect(!logText.contains("shot-b"), "the file's own name is not kept")
        let derived = try #require(state(d, id).chat)
        #expect(derived.messages.map(\.images) == [["1.png", "2.jpg"], []], "the agent's reply carries none")
        #expect(try Data(contentsOf: folder(d, id).appendingPathComponent("1.png")) == Data(contentsOf: first))
        #expect(try Data(contentsOf: folder(d, id).appendingPathComponent("2.jpg")) == Data(contentsOf: second))
        let goalsFolder = d.fx.project.threadDirectory(id).appendingPathComponent(GoalAttachments.folder)
        #expect(!FileManager.default.fileExists(atPath: goalsFolder.path), "the goal's folder is not used: a run would copy it")
        // The next message carries on from the numbers already used.
        _ = try await chat(d, .existing(id: id), "and this one", attachments: [try d.image("c.png")])
        #expect(state(d, id).chat?.messages.map(\.images) == [["1.png", "2.jpg"], [], ["3.png"], []])
    }

    @Test func oldLogReplays() async throws {
        let d = try await drafting()
        let result = try await chat(d)
        let said = try #require(try events(d, result.id).first { $0.kind == .chatMessage })
        #expect(said.data["images"] == nil, "a message with no screenshot writes no field")
        #expect(state(d, result.id).chat?.messages.map(\.images) == [[], []])

        // A name a log was edited to hold, which is not one this feature writes, is not read as a file.
        var chat = ChatState()
        let names: JSONValue = .array([.string("../../etc/passwd.png"), .string("2.png"), .string("01.png"), .string("3.jpg")])
        chat.apply(
            Event(seq: 1, ts: "t", turn: 0, kind: .chatMessage, data: ["role": "user", "text": "hi", "images": names]))
        #expect(chat.messages.first?.images == ["2.png", "3.jpg"])
    }

    // MARK: Later turns

    @Test func laterTurnsCarryEarlierImages() async throws {
        let d = try await drafting()
        let first = try await chat(d, attachments: [try d.image("one.png")])
        _ = try await chat(d, .existing(id: first.id), "and this?", attachments: [try d.image("two.png")])
        let calls = try #require(d.codex?.read("calls"))
        #expect(calls.components(separatedBy: "images/1.png").count - 1 == 2, "turn 1 and again turn 2: \(calls)")
        #expect(calls.components(separatedBy: "images/2.png").count - 1 == 1, "only turn 2 has the second")
        let last = try #require(calls.range(of: "images/1.png", options: .backwards))
        let second = try #require(calls.range(of: "images/2.png"))
        #expect(last.lowerBound < second.lowerBound, "in the order they were sent")
        // Turn 3 sends nothing new and still shows both.
        _ = try await chat(d, .existing(id: first.id), "any other thoughts?")
        let again = try #require(d.codex?.read("calls"))
        #expect(again.components(separatedBy: "images/2.png").count - 1 == 2)
    }

    @Test func aClaudeAgentOpensEveryEarlierImageFromItsFolderOnLaterTurns() async throws {
        var d = try await drafting(provider: .claude, allowUnpriced: false)
        d.config.chatReadsRepo = false  // about the screenshots: with no repository copy they are all the folder holds
        let answer = try d.file("answer.txt", "I see it.")
        let dump = d.dir.appendingPathComponent("dump.json")
        let env = d.claudeEnvironment("answer=\(answer)", "dump=\(dump.path)")
        let first = try await chat(d, attachments: [try d.image("one.png")], environment: env)
        _ = try await chat(
            d, .existing(id: first.id), "and this?", attachments: [try d.image("two.jpg", jpeg: true)], environment: env)
        let seen = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as? [String: Any])
        let argv = try #require(seen["argv"] as? [String]).joined(separator: "\n")
        #expect(argv.contains("--tools\nRead\n--allowedTools\nRead"), "Read is the only tool: \(argv)")
        #expect(seen["cwd_files"] as? [String] == ["1.png", "2.jpg"], "both were in the folder it ran in")
        #expect(!argv.contains("one.png") && !argv.contains("two.jpg"), "the files' own names never reach the agent")
    }

    @Test func aChatWithoutImagesNamesNoneAndEachMessageNamesItsOwn() throws {
        let plain = Chat.prompt(history: [], message: "hello", instructions: nil, paths: [], pathsCut: false)
        #expect(!plain.contains(".png"), "no screenshot is mentioned when there is none")

        let history = [
            ChatMessage(role: .user, text: "alpha", seq: 1, images: ["1.png"]),
            ChatMessage(role: .assistant, text: "beta", seq: 2),
        ]
        let prompt = Chat.prompt(
            history: history, message: "gamma", instructions: nil, paths: [], pathsCut: false,
            images: ["1.png", "2.jpg"], newImages: ["2.jpg"])
        // Each message is quoted under a line that says who spoke (or a heading, for the latest): that line names the screenshots that message sent, and no others.
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func above(_ quoted: String) throws -> String {
            let at = try #require(lines.firstIndex(of: "> \(quoted)"))
            return try #require(lines[..<at].last { !$0.isEmpty })
        }
        let (alpha, beta, gamma) = (try above("alpha"), try above("beta"), try above("gamma"))
        #expect(alpha.contains("1.png") && !alpha.contains("2.jpg"))
        #expect(!beta.contains(".png") && !beta.contains(".jpg"))
        #expect(gamma.contains("2.jpg") && !gamma.contains("1.png"))
    }

    // MARK: Ends and clean-up

    @Test func endsEveryTurn() async throws {
        let d = try await drafting()
        let shot = try d.image("a.png")
        try d.codex?.put("hang", "")
        let stopped = try await chat(d, attachments: [shot], attach: { execution in
            Task { try? await Task.sleep(nanoseconds: 300_000_000); execution.stop() }
        })
        #expect(stopped.end == "stopped")
        let id = stopped.id
        let timedOut = try await chat(d, .existing(id: id), "again", attachments: [shot], timeout: 1)
        #expect(timedOut.end == "timeout")
        let kinds = try events(d, id).map(\.kind)
        #expect(kinds.filter { $0 == .chatMessage }.count == 2 && kinds.filter { $0 == .chatEnded }.count == 2)
        #expect(state(d, id).chat?.open == false && state(d, id).chat?.lastEnd == "timeout")
        #expect(state(d, id).chat?.messages.flatMap(\.images) == ["1.png", "2.png"], "what was sent stays on record")
        #expect(!FileManager.default.fileExists(atPath: d.fx.service.chatScratch(id).path), "the agent's folder is gone")
        #expect(FileManager.default.fileExists(atPath: folder(d, id).appendingPathComponent("2.png").path))
    }

    @Test func aCrashWithScreenshotsStillEndsTheTurnOnceAndKeepsWhatWasSent() async throws {
        let d = try await drafting()
        try d.codex?.put("crash", "")
        let result = try await chat(d, attachments: [try d.image("a.png"), try d.image("b.png")])
        #expect(result.end == "failed")
        let id = result.id
        let kinds = try events(d, id).map(\.kind)
        #expect(kinds.filter { $0 == .chatMessage }.count == 1 && kinds.filter { $0 == .chatEnded }.count == 1)
        #expect(state(d, id).chat?.open == false && state(d, id).chat?.messages.first?.images == ["1.png", "2.png"])
        #expect(!FileManager.default.fileExists(atPath: d.fx.service.chatScratch(id).path), "the agent's folder is gone")
        // The chat goes on, and the next turn shows the agent both again.
        try FileManager.default.removeItem(at: d.codex!.dir.appendingPathComponent("crash"))
        _ = try await chat(d, .existing(id: id), "try again")
        let calls = try #require(d.codex?.read("calls"))
        #expect(calls.components(separatedBy: "images/2.png").count - 1 == 2)
    }

    @Test func abandonRemovesImages() async throws {
        let d = try await drafting()
        let result = try await chat(d, attachments: [try d.image("a.png")])
        #expect(FileManager.default.fileExists(atPath: folder(d, result.id).path))
        _ = try await d.fx.service.abandon(id: result.id)
        #expect(!FileManager.default.fileExists(atPath: folder(d, result.id).path), "the screenshots went with the chat")
        #expect(state(d, result.id).decision == "abandoned")
    }

    @Test func aScreenshotThatWentMissingRefusesTheTurnBeforeItStarts() async throws {
        let d = try await drafting()
        let first = try await chat(d, attachments: [try d.image("a.png")])
        try FileManager.default.removeItem(at: folder(d, first.id).appendingPathComponent("1.png"))
        let runs = d.codex?.runs
        do {
            _ = try await chat(d, .existing(id: first.id), "still there?")
            Issue.record("a turn started with a screenshot missing")
        } catch let refusal as ChatRefusal {
            #expect("\(refusal)".contains("1.png"))
        }
        #expect(d.codex?.runs == runs)
        #expect(state(d, first.id).chat?.messages.count == 2 && state(d, first.id).chat?.open == false)
    }
}
