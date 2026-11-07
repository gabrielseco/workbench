import Foundation
import Testing

@testable import WorkbenchCore

@Suite struct ConfigEditTests {
    private static let tools = "[tools]\navailable = [\"Read\"]\nallowed = [\"Read\"]\n"

    private func project(_ config: String?) throws -> Project {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".workbench"), withIntermediateDirectories: true)
        let project = Project(root: root)
        if let config { try config.write(to: project.configURL, atomically: true, encoding: .utf8) }
        return project
    }

    private func text(_ project: Project) throws -> String { try String(contentsOf: project.configURL, encoding: .utf8) }
    private func key(_ text: String) throws -> ConfigEdit.Key { try ConfigEdit.parseKey(text) }

    @Test func aTableIsAppendedAndAnExistingOneHasOnlyItsLineChanged() throws {
        let original = "check_command = \"make\"\n\n" + Self.tools
        let p = try project(original)
        let created = try ConfigEdit.set(key("agents.goal.provider"), to: "claude", in: p)
        #expect(created.old == nil && created.new == "claude" && created.written)
        #expect(try text(p) == original + "\n[agents.goal]\nprovider = \"claude\"\n")
        let changed = try ConfigEdit.set(key("agents.goal.provider"), to: "codex", in: p)
        #expect(changed.old == "claude" && changed.new == "codex")
        #expect(try text(p) == original + "\n[agents.goal]\nprovider = \"codex\"\n")
        #expect(try Config.load(from: p.configURL).resolvedGoalAgent?.provider == .codex)
    }

    @Test func aNewKeyJoinsItsTableBeforeTheBlankLinesThatEndIt() throws {
        let original = "[agents.run]\nmodel = \"opus\"\n\n# the review\n[agents.review]\nprovider = \"codex\"\n\n" + Self.tools
        let p = try project(original)
        _ = try ConfigEdit.set(key("agents.run.reasoning_effort"), to: "high", in: p)
        #expect(try text(p) == original.replacingOccurrences(
            of: "model = \"opus\"\n", with: "model = \"opus\"\nreasoning_effort = \"high\"\n"))
    }

    @Test func untouchedBytes() throws {
        let original = """
            # who does what
            check_command = "make test"   # the gate

            [agents.run]
              model = "opus"   # the strong one
            # a note about judge
            [agents.judge]
            provider = "claude"
            model = "sonnet"

            \(Self.tools)
            """
        let p = try project(original)
        let before = original.split(separator: "\n", omittingEmptySubsequences: false)
        _ = try ConfigEdit.set(key("agents.run.model"), to: "haiku", in: p)
        let after = try text(p).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(before.count == after.count)
        let differing = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(differing.count == 1, "only one line changed: \(differing)")
        #expect(after[differing[0]] == "  model = \"haiku\"   # the strong one", "indent and comment are kept")
    }

    @Test func unset() throws {
        let judge = "[agents.judge]\nmodel = \"sonnet\"\nprovider = \"claude\"\n\n"
        let original = "check_command = \"make\"\n\n[agents.run]\nmodel = \"opus\"\n\n" + judge + Self.tools
        let p = try project(original)
        let gone = try ConfigEdit.unset(key("agents.run.model"), in: p)
        #expect(gone.old == "opus" && gone.new == nil)
        #expect(try text(p) == "check_command = \"make\"\n\n" + judge + Self.tools)
        _ = try ConfigEdit.unset(key("agents.judge.model"), in: p)
        #expect(try text(p).contains("[agents.judge]\nprovider = \"claude\"\n"), "the table stays while it has a key")
        #expect(try Config.load(from: p.configURL).resolvedRunAgent().model == nil, "the role is back on its default")
        #expect(throws: ConfigEdit.Failure.notSet(try key("agents.ship.model"))) {
            try ConfigEdit.unset(key("agents.ship.model"), in: p)
        }
    }

    @Test func aTableWithACommentIsKeptWhenItsLastKeyGoes() throws {
        let original = "[agents.run]\n# why opus\nmodel = \"opus\"\n\n" + Self.tools
        let p = try project(original)
        _ = try ConfigEdit.unset(key("agents.run.model"), in: p)
        #expect(try text(p) == "[agents.run]\n# why opus\n\n" + Self.tools)
    }

    @Test func refusals() throws {
        let original = Self.tools
        let p = try project(original)
        for bad in [
            "agents.run.allow_unpriced", "agents.nobody.model", "agents.review.stage", "check_command", "agents.run",
            "agents.run.model.x", "tools.allowed", "",
        ] {
            #expect(throws: ConfigEdit.Failure.badKey(bad), "\(bad)") { try ConfigEdit.parseKey(bad) }
        }
        for value in ["", "has space", "quo\"te", "new\nline", "back\\slash", String(repeating: "a", count: 101), "#x"] {
            #expect(throws: (any Error).self, "\(value.debugDescription)") {
                try ConfigEdit.set(key("agents.run.model"), to: value, in: p)
            }
        }
        #expect(try text(p) == original, "nothing was written")
    }

    @Test func invalidIsPutBack() throws {
        let original = "[agents.run]\nmodel = \"opus\"\n\n" + Self.tools
        let p = try project(original)
        let bad = [("agents.run.provider", "gemini"), ("agents.run.reasoning_effort", "extreme"), ("agents.goal.model", "x")]
        for (name, value) in bad {
            #expect(throws: ConfigEdit.Failure.self, "\(name)=\(value)") { try ConfigEdit.set(self.key(name), to: value, in: p) }
        }
        #expect(try text(p) == original)
    }

    @Test func unsafeFiles() throws {
        #expect(throws: ConfigEdit.Failure.noConfig) { try ConfigEdit.set(key("agents.run.model"), to: "x", in: project(nil)) }
        let big = try project(Self.tools + String(repeating: "# padding\n", count: 30_000))
        #expect(throws: ConfigEdit.Failure.tooLarge) { try ConfigEdit.set(key("agents.run.model"), to: "x", in: big) }
        let broken = "[agents.run]\nmodel = \"a\"\n[agents.run]\nmodel = \"b\"\n" + Self.tools
        let dup = try project(broken)
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set(key("agents.run.model"), to: "x", in: dup) }
        #expect(try text(dup) == broken, "a config that does not load is not touched")
        let crlf = try project("check_command = \"make\"\r\n" + Self.tools)
        #expect(throws: ConfigEdit.Failure.unsafe("it has Windows line endings")) {
            try ConfigEdit.set(key("agents.run.model"), to: "x", in: crlf)
        }
    }

    @Test func changedUnderneath() throws {
        let original = Self.tools
        let p = try project(original)
        let theirs = original + "# added by someone else\n"
        #expect(throws: ConfigEdit.Failure.changed) {
            try ConfigEdit.edit(key("agents.run.model"), value: "opus", in: p) {
                try? theirs.write(to: p.configURL, atomically: true, encoding: .utf8)
            }
        }
        #expect(try text(p) == theirs, "their change is not overwritten")
    }

    @Test func theFileKeepsItsMode() throws {
        let p = try project(Self.tools)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p.configURL.path)
        _ = try ConfigEdit.set(key("agents.run.model"), to: "opus", in: p)
        let mode = try FileManager.default.attributesOfItem(atPath: p.configURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func settingTheValueItAlreadyHasWritesNothing() throws {
        let original = "[agents.run]\nmodel = \"opus\"\n\n" + Self.tools
        let p = try project(original)
        let change = try ConfigEdit.set(key("agents.run.model"), to: "opus", in: p)
        #expect(!change.written && change.old == "opus")
        #expect(try text(p) == original)
    }
}
