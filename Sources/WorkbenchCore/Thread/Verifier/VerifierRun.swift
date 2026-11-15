import Foundation

/// One verifier turn: a separate `claude -p` run in the thread's worktree, on the project's skill, that ends in
/// exactly one `verifier.ended` however it ends. The caller holds the log; this opens nothing of its own.
///
/// It is used by `workbench verifier` and by a turn's automatic step, so both leave the same events.
struct VerifierRun {
    var config: Config
    var verifier: VerifierConfig
    /// `[run]`: the app Workbench starts before the turn and stops after it. Nil when the project has none.
    var run: RunConfig?
    var skill: VerifierSkill
    var goal: Goal
    var threadID: String
    var goalPath: String
    var worktree: URL
    var proofDirectory: URL
    var threadDirectory: URL
    /// The resolved executable of `verifier.resolvedProvider`: `claude` or `codex`, never one for the other.
    var executable: URL
    /// The parent environment; what the verifier sees is the allowlisted part of it (the project's for Claude, Codex's own
    /// minimal set for Codex).
    var environment: [String: String]
    var timeout: TimeInterval
    var killGrace: TimeInterval = 5
    /// What the worktree held as the run started, recorded on every `proof.added` it writes.
    var identity: ProofIdentity?

    /// Appends `verifier.started`, runs, sweeps and appends `verifier.ended`. Only a failure to write the log throws.
    func run(turn: Int, log: EventLogWriter, attach: @Sendable (ProcessRun) -> Void) async throws -> VerifierReport {
        // The prompt names the app, which is only known once it is up; the attempt below is recorded first, so the
        // recorded argv has the prompt left out as it always has.
        let sessionID = UUID()
        let provider = verifier.resolvedProvider
        let name = provider.rawValue
        let scratch = threadDirectory.appendingPathComponent("verifier/tmp", isDirectory: true)
        let answerFile = threadDirectory.appendingPathComponent("verifier/answer-turn-\(turn).txt")
        func arguments(_ prompt: String) -> [String] {
            Verifier.arguments(
                provider: provider, config: config, verifier: verifier, prompt: prompt, worktree: worktree,
                proofDirectory: proofDirectory, scratch: scratch, answerFile: answerFile, sessionID: sessionID)
        }
        var shown = arguments("")
        if provider == .codex, let end = shown.firstIndex(of: "--") { shown = Array(shown[..<end]) }
        shown = PRDescriber.displayArguments(shown)
        if provider == .codex {
            // A previous attempt's answer is never read as this one's.
            try? FileManager.default.removeItem(at: answerFile)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        }

        // A `claude`, a `codex`, a helper or an app a killed verifier left is found by the directory it ran in, and ended first.
        Verifier.sweepOrphans(worktree: worktree, threadDirectory: threadDirectory)
        try? FileManager.default.createDirectory(at: proofDirectory, withIntermediateDirectories: true)
        let before = Self.snapshot(proofDirectory, threadDirectory)

        // The attempt is on record before anything is spent.
        try await log.append(
            .verifierStarted, turn: turn,
            data: [
                "argv": .array(shown.map { .string($0) }), "skill": .string(skill.path), "sha256": .string(skill.sha256),
                "bytes": .int(skill.bytes), "truncated": .bool(skill.truncated), "provider": .string(name),
                "model": verifier.model.map { .string($0) } ?? .null,
            ])
        let began = Date()

        // The app comes up first, and only a verifier that has one to drive is started and paid for.
        var app: AppLauncher.Running?
        var launchFailure: String?
        if let runConfig = run {
            let launched = try await launch(runConfig, turn: turn, log: log, attach: attach)
            app = launched.app
            launchFailure = launched.failure
        }

        var lines: [String] = []
        var exit: ProcessExit?
        var oversized = false
        var startError = launchFailure
        if launchFailure == nil {
            let info = app.map { Verifier.RunningApp(pid: $0.pid, port: $0.port, url: $0.url) }
            let prompt = Verifier.prompt(
                skill: skill, goal: goal, proofDirectory: proofDirectory, threadID: threadID, goalPath: goalPath,
                app: info, checkout: provider == .codex ? worktree : nil)
            var childEnvironment = Verifier.environment(
                base: provider == .codex
                    ? CodexProvider.environment(from: environment) : config.childEnvironment(from: environment),
                proofDirectory: proofDirectory, threadID: threadID, goalPath: goalPath, app: info)
            if provider == .codex { childEnvironment["TMPDIR"] = scratch.path }
            var request = SpawnRequest(
                executable: executable, arguments: arguments(prompt), environment: childEnvironment,
                workingDirectory: worktree, timeout: timeout)
            request.killGrace = killGrace
            request.maxLineBytes = Verifier.maxOutputBytes
            do {
                let process = try ProcessRunner.start(request)
                attach(process)
                for await event in process.events {
                    switch event {
                    case .line(let line): lines.append(line)
                    case .exited(let e): exit = e
                    case .oversizedLine: oversized = true
                    case .started: break
                    }
                }
            } catch { startError = "\(name) could not be started" }
        }

        // The app goes with the turn, however the turn ended. Nothing between its start and here can throw.
        var appEnd: AppLauncher.AppEnd?
        if let app { appEnd = await app.stop() }
        if let app, let appEnd { try await recordRunEnd(app: app, end: appEnd, turn: turn, log: log) }

        // The run ended; whatever it started and left (the app, also in a new session) goes with it, wherever it ran.
        let swept = Verifier.sweepOrphans(worktree: worktree, threadDirectory: threadDirectory)

        var answer = Verifier.Answer(text: nil, costUSD: nil, failure: startError)
        if startError == nil {
            if provider == .codex {
                answer = Self.codexAnswer(lines: lines, exit: exit, timeout: timeout, answerFile: answerFile)
            } else {
                answer = Self.answer(lines: lines, oversized: oversized, exit: exit, timeout: timeout, budget: verifier.budgetUSD)
            }
        }
        let after = Self.snapshot(proofDirectory, threadDirectory)
        let changed = after.filter { file in before.first { $0.name == file.name }?.sha256 != file.sha256 }
            .prefix(Verifier.maxFiles)
        let files = changed.map { VerifierFile(name: $0.name, bytes: $0.bytes, sha256: $0.sha256) }
        // A Codex verifier that could not drive the app (its sandbox, a missing permission) still ends its run and writes a
        // report, so a screenshot the goal asks for that this attempt did not write means nothing on screen was checked: not a
        // pass. One an earlier attempt left does not count (an identical re-capture is not told from it either).
        if provider == .codex, answer.failure == nil {
            let missing = Verifier.missingScreenshots(goal: goal, present: Set(changed.map(\.name)))
            if !missing.isEmpty {
                let more = missing.count > 5 ? ", and \(missing.count - 5) more" : ""
                let shown = missing.prefix(5).joined(separator: ", ") + more
                answer.failure = "codex left no screenshot the goal asks for (\(shown)), so nothing on screen was checked"
            }
        }
        // Every PNG it left is proof, recorded before the end so `review` and the criteria find it.
        for file in changed where file.name.lowercased().hasSuffix(".png") && !file.name.contains("/") {
            try await log.append(
                .proofAdded, turn: turn,
                data: [
                    "name": .string(file.name), "path": .string(file.path), "sha256": .string(file.sha256),
                    "bytes": .int(file.bytes), "commit": identity.map { .string($0.commit) } ?? .null,
                    "tree": identity.map { .string($0.tree) } ?? .null, "source": "verifier",
                ])
        }
        let elapsed = Int(Date().timeIntervalSince(began) * 1000)
        let report = VerifierReport(
            turn: turn, ok: answer.failure == nil && answer.text != nil,
            reason: answer.failure.map { Self.clean($0) }, costUSD: answer.costUSD, durationMs: elapsed,
            files: files, report: Self.clean(Verifier.bounded(answer.text ?? "")))

        var data: [String: JSONValue] = [
            "ok": .bool(report.ok), "duration_ms": .int(elapsed),
            "files": .array(
                report.files.map { .object(["name": .string($0.name), "bytes": .int($0.bytes), "sha256": .string($0.sha256)]) }),
            "report": .string(report.report),
        ]
        if let reason = report.reason { data["reason"] = .string(reason) }
        if let cost = report.costUSD { data["cost_usd"] = .double(cost) }
        if !swept.isEmpty { data["swept_orphans"] = .int(swept.count) }
        if let exit {
            if exit.escalatedToKill { data["escalated_to_kill"] = true }
            if exit.sweptProcesses > 0 { data["swept_processes"] = .int(exit.sweptProcesses) }
        }
        try await log.append(.verifierEnded, turn: turn, data: .object(data))
        return report
    }

    /// Records `run.started`, starts the app and waits for it. On a failure `run.ended` is already written and the
    /// failure is what the verifier turn ends with.
    private func launch(
        _ runConfig: RunConfig, turn: Int, log: EventLogWriter, attach: @Sendable (ProcessRun) -> Void
    ) async throws -> (app: AppLauncher.Running?, failure: String?) {
        // The thread's own port, the one its check and setup were given, so the app, the browser test and the verifier agree on it
        // and another thread's app is somewhere else. A kernel-offered port is the fallback when the range had none.
        let threads = threadDirectory.deletingLastPathComponent()
        var ports = ThreadPorts.assign(threadsDirectory: threads, id: threadID, count: config.ports)
        // Whatever answers on the port would pass the ready check, so an app is never started on a port something else holds:
        // the thread is moved to a free block first (another project's app can sit on the same slot).
        if let held = ports, !held.all.allSatisfy({ AppLauncher.isFree($0) }) {
            ports = ThreadPorts.assign(threadsDirectory: threads, id: threadID, count: config.ports, renew: true)
        }
        let port = ports?.first ?? AppLauncher.freePort()
        var started: [String: JSONValue] = ["command": .string(runConfig.command), "port": port.map { .int($0) } ?? .null]
        switch runConfig.ready {
        case .url(let url): started["ready_url"] = .string(url)
        case .line(let pattern): started["ready_line"] = .string(pattern)
        }
        // The attempt is on record before anything is launched: a start that cannot be written is not made.
        try await log.append(.runStarted, turn: turn, data: .object(started))
        guard let port else {
            try await log.append(
                .runEnded, turn: turn,
                data: ["ready": false, "reason": "no free port could be found for the app"])
            return (nil, "no free port could be found for the app")
        }
        let launchBegan = Date()
        let launcher = AppLauncher(
            run: runConfig, worktree: worktree, environment: config.childEnvironment(from: environment),
            lifetime: timeout + TimeInterval(runConfig.readyTimeoutS) + 30, killGrace: killGrace)
        switch await launcher.start(port: port, threadID: threadID, goalPath: goalPath, ports: ports, attach: attach) {
        case .success(let app):
            return (app, nil)
        case .failure(let failure):
            var data: [String: JSONValue] = ["ready": false, "reason": .string(Self.clean(failure.description))]
            if !failure.tail.isEmpty { data["tail"] = .array(failure.tail.map { .string(Self.clean($0)) }) }
            data["duration_ms"] = .int(Int(Date().timeIntervalSince(launchBegan) * 1000))
            if case .exited(let end) = failure, let exit = end.exit {
                data["duration_ms"] = .int(exit.durationMs)
                switch exit.termination {
                case .exited(let code): data["exit_code"] = .int(Int(code))
                case .signaled(let signal): data["signal"] = .int(Int(signal))
                case .lost: data["lost"] = true
                }
            }
            try await log.append(.runEnded, turn: turn, data: .object(data))
            return (nil, Self.clean(failure.description))
        }
    }

    private func recordRunEnd(
        app: AppLauncher.Running, end: AppLauncher.AppEnd, turn: Int, log: EventLogWriter
    ) async throws {
        var data: [String: JSONValue] = ["ready": true, "ready_ms": .int(app.readyMs), "exited_early": .bool(end.exitedEarly)]
        if let exit = end.exit {
            data["duration_ms"] = .int(exit.durationMs)
            switch exit.termination {
            case .exited(let code): data["exit_code"] = .int(Int(code))
            case .signaled(let signal): data["signal"] = .int(Int(signal))
            case .lost: data["lost"] = true
            }
            if exit.escalatedToKill { data["escalated_to_kill"] = true }
            if exit.sweptProcesses > 0 { data["swept_processes"] = .int(exit.sweptProcesses) }
        }
        try await log.append(.runEnded, turn: turn, data: .object(data))
    }

    /// What the output and the exit say. A run that was stopped or timed out has no answer worth reading; one that
    /// ended on its own is read first (a budget stop prints its reason), then judged by its exit status.
    static func answer(
        lines: [String], oversized: Bool, exit: ProcessExit?, timeout: TimeInterval, budget: Decimal
    ) -> Verifier.Answer {
        if let exit, exit.cause != .natural {
            return Verifier.Answer(text: nil, costUSD: nil, failure: Verifier.processProblem(exit, timeout: timeout))
        }
        if oversized { return Verifier.Answer(text: nil, costUSD: nil, failure: "the answer was too large to read") }
        guard !lines.isEmpty else {
            return Verifier.Answer(
                text: nil, costUSD: nil, failure: Verifier.processProblem(exit, timeout: timeout) ?? "claude printed nothing")
        }
        var parsed = Verifier.parse(output: lines.joined(separator: "\n"), budget: budget)
        if parsed.failure == nil, let problem = Verifier.processProblem(exit, timeout: timeout) {
            parsed.text = nil
            parsed.failure = problem
        } else if parsed.failure != nil, let exit, exit.termination != .exited(0), parsed.costUSD == nil {
            parsed.failure = Verifier.processProblem(exit, timeout: timeout) ?? parsed.failure
        }
        return parsed
    }

    /// A Codex verifier is read from its answer file, and only after it ended on its own with status 0; its stream is a
    /// transcript, read only for an "at capacity" that explains a missing answer.
    static func codexAnswer(lines: [String], exit: ProcessExit?, timeout: TimeInterval, answerFile: URL) -> Verifier.Answer {
        if let problem = Verifier.processProblem(exit, timeout: timeout, name: "codex") {
            return Verifier.Answer(text: nil, costUSD: nil, failure: problem)
        }
        let capacity = lines.contains { CodexDecoder.atCapacity($0) } || CodexDecoder.atCapacity(exit?.stderrTail ?? "")
        return Verifier.codexAnswer(answerFile: answerFile, sawCapacity: capacity)
    }

    static func clean(_ text: String) -> String {
        ThreadService.withoutCredentials(PRBodyBuilder.scrub(text))
    }

    /// The regular files under the proof directory by name, with their hashes; bounded by `ProofCollector`.
    static func snapshot(_ proofDirectory: URL, _ threadDirectory: URL) -> [ProofFile] {
        ProofCollector.collect(proofDirectory: proofDirectory, threadDirectory: threadDirectory).files
    }
}
