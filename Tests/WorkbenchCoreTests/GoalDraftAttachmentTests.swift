import Foundation
import Testing

@testable import WorkbenchCore

extension Drafting {
    /// A file with an image's first bytes (the sniff reads no more), plus `padding` more bytes.
    func image(
        _ name: String, header: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], padding: Int = 16
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(header + [UInt8](repeating: 7, count: padding)).write(to: url)
        return url
    }
}

@Suite(.processGate) struct GoalDraftAttachmentTests {
    private let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]

    @Test func imagesGoToACodexDrafterInOrderAndAreKeptWithTheThread() async throws {
        let d = try await drafting()
        let first = try d.image("shot-b.png")
        let second = try d.image("a.jpeg", header: jpeg)
        let result = try await d.draft(attachments: [first, second])
        let id = try #require(result.id)
        #expect(result.failure == nil)

        let call = try #require(d.codex?.read("calls"))
        let one = try #require(call.range(of: "images/1.png"))
        let two = try #require(call.range(of: "images/2.jpg"))
        #expect(call.contains("-i ") && one.lowerBound < two.lowerBound, "both images, in the order given: \(call)")
        #expect(!call.contains("shot-b") && !call.contains("a.jpeg"), "the files' own names never reach the agent")

        let folder = d.fx.project.threadDirectory(id).appendingPathComponent("attachments")
        #expect(try Data(contentsOf: folder.appendingPathComponent("1.png")) == Data(contentsOf: first))
        #expect(try Data(contentsOf: folder.appendingPathComponent("2.jpg")) == Data(contentsOf: second))
        let goal = try String(contentsOf: d.fx.project.goalURL(id), encoding: .utf8)
        #expect(goal.contains("![screenshot 1](attachments/1.png)") && goal.contains("![screenshot 2](attachments/2.jpg)"))
        #expect(try GoalFile.parse(goal).goal.approval == .draft, "the references leave the goal a valid draft")
    }

    @Test func theDrafterFoldersHoldNoImagesWhenTheDraftEnds() async throws {
        let d = try await drafting()
        let result = try await d.draft(attachments: [try d.image("a.png")])
        let call = try #require(d.codex?.read("calls"))
        let words = call.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        let path = try #require(words.firstIndex(of: "-i").map { words[$0 + 1] })
        #expect(result.id != nil && !FileManager.default.fileExists(atPath: path), "the scratch copy was removed")
    }

    @Test func aClaudeDrafterOpensTheImagesFromItsFolderWithReadAndNothingIsSentAsAnAttachment() async throws {
        let d = try await drafting(provider: .claude, allowUnpriced: false)
        let answer = try d.file("answer.json", proposalJSON)
        let dump = d.dir.appendingPathComponent("dump.json")
        let result = try await d.draft(
            attachments: [try d.image("shot.png"), try d.image("b.jpg", header: jpeg)],
            environment: d.claudeEnvironment("answer=\(answer)", "dump=\(dump.path)"))
        let id = try #require(result.id)
        #expect(result.failure == nil, "\(String(describing: result.failure))")
        let seen = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as? [String: Any])
        let argv = try #require(seen["argv"] as? [String]).joined(separator: "\n")
        #expect(argv.contains("--tools\nRead\n--allowedTools\nRead"), "Read is the only tool: \(argv)")
        #expect(argv.contains("1.png, 2.jpg"), "the prompt names the files, in order")
        #expect(!argv.contains("shot.png") && !argv.contains("b.jpg"))
        #expect(seen["cwd_files"] as? [String] == ["1.png", "2.jpg"], "they were in the folder it ran in")
        let kept = d.fx.project.threadDirectory(id).appendingPathComponent("attachments")
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("2.jpg").path))
    }

    @Test func aClaudeDraftWithoutImagesGetsNoToolsAsBefore() async throws {
        let d = try await drafting(provider: .claude, allowUnpriced: false)
        let answer = try d.file("answer.json", proposalJSON)
        let dump = d.dir.appendingPathComponent("dump.json")
        _ = try await d.draft(environment: d.claudeEnvironment("answer=\(answer)", "dump=\(dump.path)"))
        let seen = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as? [String: Any])
        let argv = try #require(seen["argv"] as? [String])
        #expect(argv.contains("--tools") && !argv.contains("Read") && seen["cwd_files"] as? [String] == [])
    }

    @Test func aFileThatIsNotAnImageIsRefusedWhateverItIsCalled() async throws {
        let d = try await drafting()
        let fake = d.dir.appendingPathComponent("not.png")
        try "just text".write(to: fake, atomically: true, encoding: .utf8)
        do {
            _ = try await d.draft(attachments: [fake])
            Issue.record("a text file named .png was attached")
        } catch let refusal as GoalDraftRefusal {
            #expect("\(refusal)".contains("not.png is not a PNG"), "\(refusal)")
        }
        #expect(d.codex?.runs == 0 && d.threads.isEmpty)
    }

    @Test func tooManyTooBigAndLinkedImagesAreRefusedBeforeSpawn() async throws {
        let d = try await drafting()
        let many = try (0..<(GoalAttachments.maxCount + 1)).map { try d.image("m\($0).png") }
        let big = try d.image("big.png", padding: GoalAttachments.maxBytes)
        let link = d.dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try d.image("real.png"))
        for bad in [many, [big], [link], [d.dir.appendingPathComponent("missing.png")], [d.dir]] {
            await #expect(throws: GoalDraftRefusal.self) { _ = try await d.draft(attachments: bad) }
        }
        #expect(d.codex?.runs == 0 && d.threads.isEmpty)
    }

    @Test func aRedraftTakesNoImages() async throws {
        let d = try await drafting()
        let first = try await d.draft()
        let id = try #require(first.id)
        await #expect(throws: GoalDraftRefusal.imagesNeedANewThread) {
            _ = try await d.draft(.replace(id: id), attachments: [try d.image("a.png")])
        }
    }

    @Test func aDraftThatFailsLeavesNoThreadAndNoImages() async throws {
        let d = try await drafting(answer: "not a goal")
        let result = try await d.draft(attachments: [try d.image("a.png")])
        #expect(result.id == nil && result.failure != nil && d.threads.isEmpty)
    }

    @Test func theScreenshotNoteIsInThePromptOnlyWhenThereAreScreenshots() {
        let none = GoalDraft.prompt(request: "x", instructions: nil, paths: [], pathsCut: false)
        let sent = GoalDraft.prompt(request: "x", instructions: nil, paths: [], pathsCut: false, attachments: 2)
        let read = GoalDraft.prompt(
            request: "x", instructions: nil, paths: [], pathsCut: false, attachments: 2, readFiles: ["1.png", "2.jpg"])
        #expect(!none.contains("## Screenshots"))
        #expect(sent.contains("## Screenshots") && sent.contains("attached to this message") && !sent.contains("1.png"))
        #expect(read.contains("Read tool") && read.contains("1.png, 2.jpg") && !read.contains("attached to this message"))
    }

    @Test func imagesAreRecognisedByTheirBytesNotTheirNames() {
        #expect(GoalAttachments.kind(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "png")
        #expect(GoalAttachments.kind(of: Data([0xFF, 0xD8, 0xFF])) == "jpg")
        #expect(GoalAttachments.kind(of: Data("GIF89a".utf8)) == "gif")
        #expect(GoalAttachments.kind(of: Data("RIFF....WEBP".utf8)) == "webp")
        #expect(GoalAttachments.kind(of: Data("<svg></svg>".utf8)) == nil)
        #expect(GoalAttachments.kind(of: Data()) == nil)
    }
}
