import Foundation
import Testing

@testable import WorkbenchCore

private let skillPath = ".claude/skills/verify/SKILL.md"

/// A stand-in `codex` for the verifier: it records its argv and working directory, and keeps to the write boundary `codex
/// exec -s workspace-write` sets: its workspace (`-C`) and the `writable_roots` it was given, nothing else. Inside it, it does
/// what the repository's verify-app skill does through `scripts/bundle-app.sh` (a build and its temporary files under the
/// checkout's `.build`), then leaves a screenshot in `$WORKBENCH_PROOF_DIR` and its answer in the file named by `-o`. A
/// write outside the boundary fails the run, as the sandbox would.
private func fakeCodexVerifier(_ dir: URL) -> String {
    """
    #!/bin/sh
    D="\(dir.path)"
    for a in "$@"; do echo "$a"; done > "$D/args"
    pwd -P > "$D/cwd"
    out=""; work=""; roots=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) out="$2"; shift ;;
        -C) work="$2"; shift ;;
        -c) case "$2" in sandbox_workspace_write.writable_roots=*) roots="${2#*=}" ;; esac; shift ;;
        --) break ;;
      esac
      shift
    done
    may_write() {
      case "$1" in "$work"/*) return 0 ;; esac
      old_ifs="$IFS"; IFS=,
      for r in $(printf '%s' "$roots" | tr -d '[]"'); do
        r="${r# }"
        case "$1" in "$r"/*) IFS="$old_ifs"; return 0 ;; esac
      done
      IFS="$old_ifs"; return 1
    }
    for target in "$work/.build/bundle-tmp.x" "$WORKBENCH_PROOF_DIR/selection.png"; do
      if ! may_write "$target"; then echo "sandbox: write denied: $target" >&2; exit 1; fi
    done
    mkdir -p "$work/.build/bundle-tmp.x" && printf 'app' > "$work/.build/bundle-tmp.x/Workbench"
    printf 'png' > "$WORKBENCH_PROOF_DIR/selection.png"
    printf 'c1 holds: the header is blue' > "$out"
    echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """
}

/// A project whose base commit has the verifier's skill, with a fake `codex` beside it.
private struct SelectionFixture {
    let fx: RunnerFixture
    let codexDir: URL
    let codex: URL

    init(verifier: String, codexExists: Bool = true) async throws {
        let dir = Scratch.url("codex-verifier")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        codexDir = dir
        codex = dir.appendingPathComponent("codex")
        if codexExists {
            try fakeCodexVerifier(dir).write(to: codex, atomically: true, encoding: .utf8)
            chmod(codex.path, 0o755)
        }
        fx = try await RunnerFixture(
            extraConfig: "[providers.codex]\nexecutable = \"\(codex.path)\"\n\n[verifier]\nskill = \"\(skillPath)\"\n" + verifier)
        let skill = fx.repo.appendingPathComponent(skillPath)
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Verify\n\nLook at the header.\n".write(to: skill, atomically: true, encoding: .utf8)
        _ = try await fx.git.run(["add", "-A"], in: fx.repo)
        _ = try await fx.git.run(["commit", "-q", "-m", "skill"], in: fx.repo)
    }

    var codexArguments: [String]? {
        (try? String(contentsOf: codexDir.appendingPathComponent("args"), encoding: .utf8))
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    }

    func verifierEvents(_ id: String) throws -> [Event] {
        try fx.events(id).filter { [.verifierStarted, .verifierEnded, .verifierSkipped].contains($0.kind) }
    }
}

@Suite(.processGate) struct VerifierSelectionTests {
    /// [c2] A provider and model chosen through `ConfigEdit` (what the Agents card writes) are in the config the next time it is
    /// read, the card shows them, and the next turn's verifier runs on them.
    @Test func persistsAndRunsSelectedVerifier() async throws {
        let s = try await SelectionFixture(verifier: "")
        _ = try ConfigEdit.set(try ConfigEdit.Key.verifier(.provider), to: "codex", in: s.fx.project)
        _ = try ConfigEdit.set(try ConfigEdit.Key.verifier(.model), to: "gpt-6.1-terra", in: s.fx.project)

        // Reopened: read from the file, as the app and the CLI do on opening the project.
        let config = try Config.load(from: s.fx.project.configURL)
        #expect(config.verifier?.provider == .codex && config.verifier?.model == "gpt-6.1-terra")
        let row = try #require(AgentSetup(config: config).row(.verifier))
        #expect(row.provider == .codex && row.model == "gpt-6.1-terra" && row.source == .configured)
        #expect(row.label == "Codex · gpt-6.1-terra")

        // The automatic verifier after a turn runs on Codex, with the chosen model, and its answer and screenshot are kept.
        let id = try await s.fx.approvedThread()
        let report = try await s.fx.runner(id).run(s.fx.options("write=a.txt"))
        let seen = try s.fx.events(id).filter { $0.kind.rawValue.hasPrefix("verifier") || $0.kind.rawValue.hasPrefix("turn") }
            .map { "\($0.kind.rawValue) \($0.data["reason"]?.stringValue ?? "")" }
        let verifier = try #require(report.verifier, "\(seen)")
        #expect(verifier.ok, "\(verifier)")
        #expect(verifier.report == "c1 holds: the header is blue")
        #expect(verifier.files.map(\.name) == ["selection.png"])

        let args = try #require(s.codexArguments)
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        #expect(args.first == "exec")
        #expect(value(after: "-m") == "gpt-6.1-terra")
        #expect(value(after: "-s") == "workspace-write")
        // Its workspace is the checkout, so the skill's helpers can build there (the fake refuses a write outside the
        // workspace and the writable roots, as the sandbox does); the proof directory is one of its writable roots.
        let worktree = WorktreeManager(repoRoot: s.fx.repo, git: s.fx.git).path(for: id)
        let proof = s.fx.project.proofDirectory(id, turn: 1)
        #expect(value(after: "-C") == worktree.path)
        #expect(args.contains { $0.hasPrefix("sandbox_workspace_write.writable_roots=") && $0.contains(proof.path) })
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".build/bundle-tmp.x/Workbench").path))
        #expect(!args.contains("--max-budget-usd") && !args.contains("--allowedTools"))

        let events = try s.verifierEvents(id)
        #expect(events.map(\.kind) == [.verifierStarted, .verifierEnded])
        #expect(events.first?.data["provider"] == "codex" && events.first?.data["model"] == "gpt-6.1-terra")
        #expect(events.last?.data["ok"] == true)
        #expect(try s.fx.events(id).contains { $0.kind == .proofAdded && $0.data["name"] == "selection.png" })

        // Run again by hand, it is Codex again: the selection holds for every verification, not only the first.
        let again = try await s.fx.service.verifier(
            id: id, config: config, again: true, environment: s.fx.options().parentEnvironment, timeout: 20, killGrace: 2)
        #expect(again.ok)
        #expect(try s.verifierEvents(id).filter { $0.kind == .verifierStarted }.allSatisfy { $0.data["provider"] == "codex" })
    }

    /// [c3] A project whose `[verifier]` names no provider keeps the Claude verifier it always had.
    @Test func legacyConfigurationUsesExistingVerifier() async throws {
        let s = try await SelectionFixture(verifier: "model = \"sonnet\"\n")
        let config = try Config.load(from: s.fx.project.configURL)
        #expect(config.verifier?.provider == nil && config.verifier?.resolvedProvider == .claude)
        let row = try #require(AgentSetup(config: config).row(.verifier))
        #expect(row.provider == .claude && row.model == "sonnet")

        let id = try await s.fx.approvedThread()
        let report = try await s.fx.runner(id).run(s.fx.options("write=a.txt"))
        #expect(report.verifier?.ok == true, "\(String(describing: report.verifier))")

        let started = try #require(try s.verifierEvents(id).first { $0.kind == .verifierStarted })
        #expect(started.data["provider"] == "claude")
        var argv: [String] = []
        if case .array(let items)? = started.data["argv"] { argv = items.compactMap(\.stringValue) }
        // The same Claude request as before: print mode, its model, its dollar cap and its tool allowlist.
        #expect(argv.contains("-p") && argv.contains("--max-budget-usd") && argv.contains("--allowedTools"))
        #expect(argv.firstIndex(of: "--model").map { argv[$0 + 1] } == "sonnet")
        #expect(s.codexArguments == nil, "codex must not run for a project that never chose it")

        // A project with no [verifier] table at all is the default verifier, on Claude.
        let bare = try Config.parse("[tools]\navailable = [\"Read\"]\n")
        #expect(bare.verifier?.resolvedProvider == .claude)
        #expect(AgentSetup(config: bare).row(.verifier)?.provider == .claude)
        #expect(AgentSetup(config: bare).row(.verifier)?.source == .providerDefault)
    }

    /// [c4] A provider with no verifier adapter, or a setting the chosen provider cannot honour, is refused where it is made;
    /// and a chosen provider that is missing is refused, never replaced by another.
    @Test func rejectsInvalidSelection() async throws {
        func problems(_ verifier: String) -> [ConfigProblem] {
            do {
                _ = try Config.parse("[tools]\navailable = [\"Read\"]\n\n[verifier]\n" + verifier)
                return []
            } catch let error as ConfigError {
                return error.problems
            } catch {
                return [ConfigProblem(code: .syntax, line: nil, message: "\(error)")]
            }
        }
        // Unknown and unsupported providers, and a wrong type, are refused at the `provider` line.
        for value in ["\"gemini\"", "\"Claude\"", "\"\""] {
            let found = problems("provider = \(value)")
            #expect(found.map(\.code) == [.invalidValue] && found.first?.line == 5, "\(value): \(found)")
        }
        #expect(problems("provider = 3").map(\.code) == [.wrongType])
        // Claude's tool patterns and dollar cap cannot bound Codex: refused, not run without them.
        #expect(problems("provider = \"codex\"\ntools = [\"Read\"]").map(\.code) == [.conflict])
        #expect(problems("provider = \"codex\"\nbudget_usd = 2").map(\.code) == [.conflict])
        #expect(problems("provider = \"claude\"\ntools = [\"Read\"]\nbudget_usd = 2").isEmpty)
        #expect(problems("provider = \"codex\"\nmodel = \"gpt-6.1-terra\"\ntimeout_min = 5").isEmpty)

        // The same refusals through the writer the Agents card uses, with the file left as it was.
        let s = try await SelectionFixture(verifier: "tools = [\"Read\"]\n", codexExists: false)
        let before = try String(contentsOf: s.fx.project.configURL, encoding: .utf8)
        let provider = try ConfigEdit.Key.verifier(.provider)
        #expect(throws: ConfigEdit.Failure.self) { _ = try ConfigEdit.set(provider, to: "gemini", in: s.fx.project) }
        #expect(throws: ConfigEdit.Failure.self) { _ = try ConfigEdit.set(provider, to: "codex", in: s.fx.project) }
        #expect(try String(contentsOf: s.fx.project.configURL, encoding: .utf8) == before)
        #expect(throws: ConfigEdit.Failure.self) { _ = try ConfigEdit.parseKey("verifier.reasoning_effort") }
        #expect(throws: ConfigEdit.Failure.self) { _ = try ConfigEdit.Key.verifier(.reasoningEffort) }
        #expect(try ConfigEdit.parseKey("verifier.model") == ConfigEdit.Key.verifier(.model))

        // Codex chosen and not installed: the automatic step says why it did not run, and a run by hand is refused; Claude never
        // stands in.
        let text = before.replacingOccurrences(of: "tools = [\"Read\"]\n", with: "provider = \"codex\"\n")
        try text.write(to: s.fx.project.configURL, atomically: true, encoding: .utf8)
        let config = try Config.load(from: s.fx.project.configURL)
        #expect(config.verifier?.provider == .codex)
        let id = try await s.fx.approvedThread()
        let report = try await s.fx.runner(id).run(s.fx.options("write=a.txt"))
        #expect(report.verifier == nil)
        let events = try s.verifierEvents(id)
        #expect(events.map(\.kind) == [.verifierSkipped], "\(events.map(\.kind))")
        #expect(events.first?.data["reason"]?.stringValue?.contains("codex") == true)

        await #expect(throws: VerifierRefusal.providerNotFound(provider: "codex", name: s.codex.path)) {
            _ = try await s.fx.service.verifier(
                id: id, config: config, environment: s.fx.options().parentEnvironment, timeout: 20, killGrace: 2)
        }
        #expect(try s.verifierEvents(id).map(\.kind) == [.verifierSkipped], "nothing started on another provider")
    }
}
