import Foundation
import Testing

@testable import WorkbenchCore

/// A `codex` that records how it was started and answers from files in its directory.
///
///   answer / answer_<n>   what `-o` gets on the nth run (else `answer`)
///   capacity_until        runs up to this number say "at capacity" and exit 1
///   hang                  runs forever; ignore_term makes it ignore SIGTERM first
///   crash                 exits 70
///   leave_child           leaves a child in its own session, running, then answers
///   big                   writes a 300 KB answer that ends in VERDICT: CLEAN
///   flood                 writes 6 MB to stdout before answering
struct FakeCodex {
    let dir: URL
    var path: String { dir.appendingPathComponent("codex").path }

    init(in fx: RunnerFixture) throws {
        dir = fx.repo.deletingLastPathComponent().appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex")
        try """
            #!/bin/sh
            d="$CODEX_FAKE_DIR"
            echo $$ > "$d/pid"
            n=$(cat "$d/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/n"
            echo "$@" >> "$d/calls"
            pwd -P >> "$d/cwds"
            out=""; prev=""; last=""
            for a in "$@"; do
              [ "$prev" = "-o" ] && out="$a"
              [ "$prev" = "-C" ] && tree="$a"
              prev="$a"; last="$a"
            done
            brief=$(printf '%s' "$last" | sed -n 's/^Read the review brief at \\(.*\\) and follow it exactly\\..*/\\1/p')
            cp "$brief" "$d/brief_$n" 2>/dev/null
            diff=$(sed -n 's/.*saved at \\(.*\\)\\. Read that file.*/\\1/p' "$brief" | head -1)
            cp "$diff" "$d/diff_$n" 2>/dev/null
            ls "$tree" > "$d/tree_$n" 2>/dev/null
            env > "$d/env_$n"
            if [ -f "$d/capacity_until" ] && [ "$n" -le "$(cat "$d/capacity_until")" ]; then
              echo "ERROR: Selected model is at capacity right now" >&2; exit 1
            fi
            if [ -f "$d/hang" ]; then
              if [ -f "$d/ignore_term" ]; then trap '' TERM; fi
              while :; do sleep 1; done
            fi
            if [ -f "$d/leave_child" ]; then
              perl -e 'use POSIX qw(setsid); my $a = fork();
                if ($a == 0) {
                  setsid(); my $b = fork();
                  if ($b == 0) { close STDOUT; close STDERR; exec "sleep", "120"; }
                  open(F, ">", $ARGV[0]); print F "$b\\n"; close F; exit 0;
                }
                waitpid($a, 0);' "$d/child_pid"
            fi
            if [ -f "$d/flood" ]; then yes "0123456789012345678901234567890123456789" | head -c 6000000; fi
            if [ -f "$d/big" ] && [ -n "$out" ]; then
              { yes "0123456789012345678901234567890123456789" | head -c 300000; echo; echo "VERDICT: CLEAN"; } > "$out"
              exit 0
            fi
            if [ -f "$d/crash" ]; then echo "boom: it fell over" >&2; exit 70; fi
            a="$d/answer_$n"; [ -f "$a" ] || a="$d/answer"
            if [ -f "$a" ] && [ -n "$out" ]; then cat "$a" > "$out"; fi
            echo "codex progress line"
            exit 0
            """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
    }

    func put(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    var runs: Int { Int(read("n")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0 }
    var calls: [String] { (read("calls") ?? "").split(separator: "\n").map(String.init) }

    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "CODEX_FAKE_DIR": dir.path].merging(extra) { $1 }
    }
}

struct ReviewedPR {
    var fx: RunnerFixture
    var id: String
    var bare: URL
    var head: String
    var codex: FakeCodex
    var config: Config

    func round(
        again: Bool = false, timeout: TimeInterval = 30,
        environment: [String: String]? = nil, codexPath: String? = nil, backoff: TimeInterval = 0,
        stopRequested: @escaping @Sendable () -> Bool = { false }, attach: @Sendable (ProcessRun) -> Void = { _ in }
    ) async throws -> PRReviewResult {
        try await fx.service.prReview(
            id: id, config: config, again: again, codexPath: codexPath ?? codex.path,
            environment: environment ?? codex.environment(), timeout: timeout,
            capacityBackoff: { _ in backoff }, stopRequested: stopRequested, attach: attach)
    }

    var finished: [Event] { (try? fx.events(id).filter { $0.kind == .prReviewFinished }) ?? [] }
    var started: [Event] { (try? fx.events(id).filter { $0.kind == .prReviewStarted }) ?? [] }
    var folder: URL { fx.project.threadDirectory(id).appendingPathComponent("pr-review") }

    /// No throwaway checkout is left, as a directory or as a registered worktree.
    func expectNoLeftovers(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let trees = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".tree") } ?? []
        #expect(trees.isEmpty, "left \(trees)", sourceLocation: sourceLocation)
        let list = try await fx.git.run(["worktree", "list", "--porcelain"], in: fx.repo).stdout
        #expect(!list.contains("round-"), "a registered worktree is left: \(list)", sourceLocation: sourceLocation)
    }
}

/// A shipped thread (`pr.opened` recorded as PR 12), with its branch pushed to the origin.
func reviewedPR(extraConfig: String = "", answer: String? = "All good.\nVERDICT: CLEAN\n") async throws -> ReviewedPR {
    let fx = try await RunnerFixture(extraConfig: extraConfig)
    let gh = try FakeGH(in: fx)
    let (id, worktree) = try await acceptedThread(fx)
    let bare = try await addOrigin(fx)
    _ = try await fx.service.shipPush(id: id, gh: gh.runner)
    _ = try await fx.service.shipOpenPR(id: id, gh: gh.runner)
    let head = try await shipOut(["rev-parse", "HEAD"], worktree, fx)
    let codex = try FakeCodex(in: fx)
    if let answer { try codex.put("answer", answer) }
    return ReviewedPR(fx: fx, id: id, bare: bare, head: head, codex: codex, config: try Config.load(from: fx.project.configURL))
}

/// A flag one task raises and the review polls.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}
