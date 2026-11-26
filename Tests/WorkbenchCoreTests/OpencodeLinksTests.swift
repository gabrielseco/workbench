import Foundation
import Testing

@testable import WorkbenchCore

/// A folder a read-only turn reads, with a private file beside it.
private struct Linked {
    let root: URL
    let folder: URL
    let secret: URL

    init() throws {
        let base = try #require(realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) })
        root = URL(fileURLWithPath: base).appendingPathComponent("oc-links-\(UUID().uuidString)")
        folder = root.appendingPathComponent("tree")
        secret = root.appendingPathComponent("private/secret.txt")
        for dir in [folder.appendingPathComponent("src/deep"), secret.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "x".write(to: folder.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try "private".write(to: secret, atomically: true, encoding: .utf8)
    }

    func link(_ path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(path).path, withDestinationPath: target)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct OpencodeLinksTests {
    @Test func aFolderWithNoLinksOrOnlyLinksInsideItIsFine() throws {
        let f = try Linked()
        defer { f.cleanUp() }
        #expect(OpencodeLinks.problem(in: f.folder) == nil)
        try f.link("inside.txt", to: "src/a.txt")
        try f.link("src/deep/up", to: "../../src")
        try f.link("self", to: f.folder.path)
        try f.link("dangling", to: "/no/such/place")
        try f.link("loop", to: "loop")
        #expect(OpencodeLinks.problem(in: f.folder) == nil)
    }

    @Test(arguments: ["absoluteFile", "relativeFile", "directory", "nested", "throughAnotherLink", "sibling"])
    func aLinkThatResolvesOutsideIsFoundHoweverItGetsThere(kind: String) throws {
        let f = try Linked()
        defer { f.cleanUp() }
        var name = "evil"
        switch kind {
        case "absoluteFile": try f.link(name, to: f.secret.path)
        case "relativeFile": try f.link(name, to: "../private/secret.txt")
        case "directory": try f.link(name, to: f.secret.deletingLastPathComponent().path)
        case "nested":
            name = "src/deep/evil"
            try f.link(name, to: "../../../private")
        case "throughAnotherLink":
            // Neither link names an outside path on its own; together they leave.
            try f.link("src/deep/hop", to: "../..")
            try f.link(name, to: "src/deep/hop/../private/secret.txt")
        default:
            // A folder whose name only starts like this one's is outside it.
            let sibling = f.root.appendingPathComponent("tree-old")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            try f.link(name, to: sibling.path)
        }
        let found = OpencodeLinks.problem(in: f.folder)
        #expect(found == .outward(name), "\(String(describing: found))")
    }

    @Test func theReasonNamesTheLinkAndNeverItsTarget() throws {
        let f = try Linked()
        defer { f.cleanUp() }
        try f.link("evil", to: f.secret.path)
        let message = try #require(OpencodeLinks.problem(in: f.folder)?.message)
        #expect(message.contains("evil") && !message.contains("secret") && !message.contains(f.root.path), "\(message)")
    }

    @Test(arguments: ["insideTheState", "pointingAtTheStateOutside"])
    func theRunsOwnStateIsNoExemption(kind: String) throws {
        let f = try Linked()
        defer { f.cleanUp() }
        var name = "opencode/cache"
        if kind == "insideTheState" {
            let state = f.folder.appendingPathComponent("opencode")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try f.link(name, to: f.secret.path)
        } else {
            let state = f.root.appendingPathComponent("out/opencode")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            name = "to-state"
            try f.link(name, to: state.path)
        }
        #expect(OpencodeLinks.problem(in: f.folder) == .outward(name))
    }

    @Test func aFolderThatCannotBeListedIsRefusedNotPassed() throws {
        // Root can list anything, so there is nothing to refuse.
        guard getuid() != 0 else { return }
        let f = try Linked()
        let closed = f.folder.appendingPathComponent("src/deep")
        defer {
            chmod(closed.path, 0o755)
            f.cleanUp()
        }
        #expect(chmod(closed.path, 0o000) == 0)
        guard case .unchecked(let why)? = OpencodeLinks.problem(in: f.folder) else {
            Issue.record("\(String(describing: OpencodeLinks.problem(in: f.folder)))")
            return
        }
        #expect(why.contains("deep cannot be read"), "\(why)")
    }

    @Test func aFolderTooLargeToCheckIsRefusedNotPassed() throws {
        let f = try Linked()
        defer { f.cleanUp() }
        let problem = OpencodeLinks.problem(in: f.folder, limit: 1)
        guard case .unchecked(let why)? = problem else {
            Issue.record("\(String(describing: problem))")
            return
        }
        #expect(why.contains("more than 1 entries"), "\(why)")
    }

    @Test func aReadOnlyTurnIsRefusedBeforeAnythingIsWrittenAndACodingTurnIsNot() throws {
        let f = try Linked()
        defer { f.cleanUp() }
        try f.link("evil", to: f.secret.path)
        let bin = f.root.appendingPathComponent("opencode")
        try "#!/bin/sh\nexit 0\n".write(to: bin, atomically: true, encoding: .utf8)
        chmod(bin.path, 0o755)
        let output = f.root.appendingPathComponent("out")
        let provider = OpencodeProvider(
            executable: bin.path, gateway: OpencodeProvider.Gateway(baseURL: "https://gw.example/v1"),
            forwarder: OpencodeProvider.Forwarder(baseURL: "http://127.0.0.1:4100/v1"),
            userDirectories: OpencodeSandbox.UserDirectories(
                temp: URL(fileURLWithPath: "/private/var/folders/ab/cd/T"),
                cache: URL(fileURLWithPath: "/private/var/folders/ab/cd/C")))
        func request(_ policy: AgentPolicy) -> AgentRequest {
            AgentRequest(
                provider: .opencode, model: "sonnet-claude", prompt: "Review.", workingDirectory: f.folder,
                outputDirectory: output,
                    policy: policy, spend: .timeoutOnly, purpose: policy == .scopedCoding ? .coding : .review,
                environment: ["PATH": "/usr/bin:/bin", "LITELLM_API_KEY": "real-key-0123"], limits: AgentLimits(timeout: 60))
        }
        do {
            _ = try provider.invocation(for: request(.readOnlyEvidence))
            Issue.record("a read-only turn started in a folder that links outside")
        } catch let failure as AgentFailure {
            #expect(failure.message.contains("evil is a symlink"), "\(failure.message)")
        }
        #expect(!FileManager.default.fileExists(atPath: output.path), "nothing was written")
        // Its reads are stated to be unconfined, so a link adds nothing to what it can already read.
        _ = try provider.invocation(for: request(.scopedCoding))
    }
}
