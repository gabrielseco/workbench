import Foundation
import Testing

@testable import WorkbenchCore

/// Images with the shape of real ones (signature, header fields, ending), as small as the test allows: the checks read no pixels.
enum TestImage {
    private static func be32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * $0)) & 0xFF) } }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        be32(data.count) + Array(type.utf8) + data + [0, 0, 0, 0]
    }

    /// `padding` extra bytes ride in an ancillary chunk, so a file can be big and small in pixels.
    static func png(width: Int = 4, height: Int = 4, padding: Int = 0) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += chunk("IHDR", be32(width) + be32(height) + [8, 2, 0, 0, 0])
        if padding > 0 { bytes += chunk("prVt", [UInt8](repeating: 7, count: padding)) }
        bytes += [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        return Data(bytes)
    }

    static func jpeg(width: Int = 4, height: Int = 4) -> Data {
        let size = [UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF)]
        let frame: [UInt8] = [0xFF, 0xC0, 0, 11, 8] + size + [1, 1, 0x11, 0]
        return Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0] + frame + [0xFF, 0xD9])
    }

    static func gif() -> Data { Data(Array("GIF89a".utf8) + [4, 0, 4, 0, 0, 0, 0] + [0x3B]) }

    /// A lossy WebP (`VP8 `) with a frame header that says `width` x `height`; the pixel data is not there, the checks read none.
    static func webp(width: Int = 4, height: Int = 4) -> Data {
        let sizes = [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8)]
        let frame: [UInt8] = [0x10, 0, 0, 0x9D, 0x01, 0x2A] + sizes
        let body = Array("WEBPVP8 ".utf8) + [UInt8(frame.count), 0, 0, 0] + frame
        let size = body.count
        return Data(Array("RIFF".utf8) + [UInt8(size & 0xFF), 0, 0, 0] + body)
    }

    /// A lossless WebP (`VP8L`): 14-bit sizes, minus one.
    static func webpLossless(width: Int, height: Int) -> Data {
        let (w, h) = (width - 1, height - 1)
        let bits: [UInt8] = [
            UInt8(w & 0xFF), UInt8((w >> 8) & 0x3F) | UInt8((h & 0x03) << 6), UInt8((h >> 2) & 0xFF), UInt8((h >> 10) & 0x0F),
        ]
        let body = Array("WEBPVP8L".utf8) + [5, 0, 0, 0, 0x2F] + bits
        return Data(Array("RIFF".utf8) + [UInt8(body.count & 0xFF), 0, 0, 0] + body)
    }

    /// An extended WebP (`VP8X`): 24-bit canvas sizes, minus one.
    static func webpExtended(width: Int, height: Int) -> Data {
        func le24(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)] }
        let body = Array("WEBPVP8X".utf8) + [10, 0, 0, 0, 0, 0, 0, 0] + le24(width - 1) + le24(height - 1)
        return Data(Array("RIFF".utf8) + [UInt8(body.count & 0xFF), 0, 0, 0] + body)
    }
}

extension Drafting {
    func image(_ name: String, jpeg: Bool = false, width: Int = 4, height: Int = 4, padding: Int = 0) throws -> URL {
        let data =
            jpeg ? TestImage.jpeg(width: width, height: height) : TestImage.png(width: width, height: height, padding: padding)
        return try write(name, data)
    }

    func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

@Suite(.processGate) struct GoalDraftAttachmentTests {
    @Test func imagesGoToACodexDrafterInOrderAndAreKeptWithTheThread() async throws {
        let d = try await drafting()
        let first = try d.image("shot-b.png")
        let second = try d.image("a.jpeg", jpeg: true)
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
            attachments: [try d.image("shot.png"), try d.image("b.jpg", jpeg: true)],
            environment: d.claudeEnvironment("answer=\(answer)", "dump=\(dump.path)"))
        let id = try #require(result.id)
        #expect(result.failure == nil, "\(String(describing: result.failure))")
        let seen = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as? [String: Any])
        let argv = try #require(seen["argv"] as? [String]).joined(separator: "\n")
        #expect(argv.contains("--tools\nRead\n--allowedTools\nRead"), "Read is the only tool: \(argv)")
        let first = try #require(argv.range(of: "1.png"))
        let second = try #require(argv.range(of: "2.jpg"))
        #expect(first.lowerBound < second.lowerBound, "the prompt names the files, in order")
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

    @Test func aTruncatedOrEmptyOrDisguisedImageIsRefusedBeforeAnyAgentStarts() async throws {
        let d = try await drafting()
        let whole = TestImage.png()
        let bad: [URL] = [
            try d.write("signature.png", whole.prefix(8)),
            try d.write("cut.png", whole.dropLast(5)),
            try d.write("empty.png", Data()),
            try d.write("cut.jpg", TestImage.jpeg().dropLast(2)),
            try d.write("cut.gif", TestImage.gif().dropLast()),
            try d.write("cut.webp", TestImage.webp().dropLast(2)),
            try d.write("zero.png", TestImage.png(width: 0, height: 5)),
        ]
        for url in bad {
            do {
                _ = try await d.draft(attachments: [url])
                Issue.record("\(url.lastPathComponent) was attached")
            } catch let refusal as GoalDraftRefusal {
                #expect("\(refusal)".contains(url.lastPathComponent), "\(refusal)")
            }
        }
        #expect(d.codex?.runs == 0 && d.threads.isEmpty)
    }

    @Test func everySupportedFormatIsAcceptedWhenItIsWhole() async throws {
        let d = try await drafting()
        let files = [
            try d.write("a.png", TestImage.png()), try d.write("b.jpg", TestImage.jpeg()), try d.write("c.gif", TestImage.gif()),
            try d.write("d.webp", TestImage.webp()),
        ]
        let result = try await d.draft(attachments: files)
        let id = try #require(result.id)
        let kept = try FileManager.default.contentsOfDirectory(
            atPath: d.fx.project.threadDirectory(id).appendingPathComponent("attachments").path)
        #expect(kept.sorted() == ["1.png", "2.jpg", "3.gif", "4.webp"])
    }

    @Test func anImageWithTooManyPixelsIsRefusedWhateverItsFileSize() async throws {
        let d = try await drafting()
        let huge = try d.image("huge.png", width: 20_000, height: 20_000)
        await #expect(throws: GoalDraftRefusal.attachment("\(GoalAttachments.Refusal.tooManyPixels("huge.png"))")) {
            _ = try await d.draft(attachments: [huge])
        }
        #expect(d.codex?.runs == 0 && d.threads.isEmpty)
    }

    @Test func aHeaderThatSaysAnAbsurdSizeIsRefusedNotMultipliedIntoACrash() async throws {
        let d = try await drafting()
        let max32 = 0xFFFF_FFFF
        let bad: [URL] = [
            try d.write("overflow.png", TestImage.png(width: max32, height: max32)),
            try d.write("wide.png", TestImage.png(width: max32, height: 1)),
            try d.write("big.webp", TestImage.webpExtended(width: 16_000_000, height: 16_000_000)),
            try d.write("lossy.webp", TestImage.webp(width: 16_000, height: 16_000)),
            try d.write("lossless.webp", TestImage.webpLossless(width: 16_000, height: 16_000)),
            try d.write("big.jpg", TestImage.jpeg(width: 65_535, height: 65_535)),
        ]
        for url in bad {
            let why = GoalAttachments.Refusal.tooManyPixels(url.lastPathComponent)
            await #expect(throws: GoalDraftRefusal.attachment("\(why)")) {
                _ = try await d.draft(attachments: [url])
            }
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

    @Test func theScreenshotsChangeThePromptOnlyWhenThereAreAnyAndNameTheirFilesInOrderOnlyForADrafterThatOpensFiles() {
        let none = GoalDraft.prompt(request: "x", instructions: nil, paths: [], pathsCut: false)
        let sent = GoalDraft.prompt(request: "x", instructions: nil, paths: [], pathsCut: false, attachments: 2)
        let read = GoalDraft.prompt(
            request: "x", instructions: nil, paths: [], pathsCut: false, attachments: 2, readFiles: ["1.png", "2.jpg"])
        #expect(none != sent && sent != read && none == GoalDraft.prompt(
            request: "x", instructions: nil, paths: [], pathsCut: false, attachments: 0, readFiles: ["1.png"]))
        #expect(!sent.contains("1.png") && !sent.contains("2.jpg"))
        let one = read.range(of: "1.png")
        let two = read.range(of: "2.jpg")
        #expect(one != nil && two != nil && one!.lowerBound < two!.lowerBound)
    }

    @Test func imagesAreRecognisedByTheirBytesAndSizedFromTheirHeaders() {
        #expect(GoalAttachments.inspect(TestImage.png(width: 30, height: 20)) == .init(ext: "png", width: 30, height: 20))
        #expect(GoalAttachments.inspect(TestImage.jpeg(width: 640, height: 480)) == .init(ext: "jpg", width: 640, height: 480))
        #expect(GoalAttachments.inspect(TestImage.gif()) == .init(ext: "gif", width: 4, height: 4))
        #expect(GoalAttachments.inspect(TestImage.webp(width: 30, height: 20)) == .init(ext: "webp", width: 30, height: 20))
        let lossless = TestImage.webpLossless(width: 300, height: 200)
        #expect(GoalAttachments.inspect(lossless) == .init(ext: "webp", width: 300, height: 200))
        let extended = TestImage.webpExtended(width: 5000, height: 4000)
        #expect(GoalAttachments.inspect(extended) == .init(ext: "webp", width: 5000, height: 4000))
        #expect(GoalAttachments.inspect(Data("<svg></svg>".utf8)) == nil)
        #expect(GoalAttachments.inspect(Data()) == nil)
    }
}
