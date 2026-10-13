import Foundation
import WorkbenchCore

extension Commands {
    /// `log --seq <n>`: one event in full, so the `seq` shown by `review` can be followed.
    static func showEvent(_ seqText: String, in id: String, url: URL) throws {
        guard let seq = Int(seqText) else { throw CLIError.usage("--seq needs an event number, got '\(seqText)'") }
        let events = try EventLogReader.read(at: url).events
        guard let event = events.first(where: { $0.seq == seq }) else {
            throw CLIError.message("no event \(seq) in \(id) (it has \(events.count))")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        out(String(decoding: try encoder.encode(event), as: UTF8.self))
    }

    static func discard(_ args: [String]) async throws {
        var a = Arguments(args)
        let yes = a.flag("--yes", "-y")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        let plan = try await ctx.service.discardPlan(id: id)
        for line in plan.render() { out(line) }

        if !yes, !plan.fullyShown {
            throw CLIError.message(
                "not discarding: the list above does not show everything that would be lost. Pass --yes to confirm.")
        }
        let interactive = isatty(STDIN_FILENO) == 1
        if !yes && interactive { print("Delete these for good? [y/N] ", terminator: "") }
        switch Confirmation.ask(yes: yes, interactive: interactive, readLine: { readLine() }) {
        case .proceed: break
        case .declined:
            out("nothing changed")
            return
        case .refused:
            throw CLIError.message("not discarding: there is no terminal to ask on. Pass --yes to confirm.")
        }
        try await ctx.service.discard(id: id, shown: plan)
        out("discarded \(id); the log is kept (`workbench log \(id)`)")
    }

    static func accept(_ args: [String]) async throws {
        var a = Arguments(args)
        let yes = a.flag("--yes", "-y")
        let message = try a.value("-m", "--message")
        let named = a.positional()
        try a.requireEmpty()
        let ctx = try await Context.load()
        let id = try ctx.threadID(named)
        let plan = try await ctx.service.acceptPlan(id: id)
        for line in plan.render() { out(line) }
        let interactive = isatty(STDIN_FILENO) == 1

        if plan.checkFailed {
            let result = plan.openWork ? "cut off" : (plan.check?.result ?? "unknown")
            out("the latest check did not pass (\(result)); `workbench review \(id)` has the details")
            if !yes && interactive { print("Accept it anyway? [y/N] ", terminator: "") }
            switch Confirmation.ask(yes: yes, interactive: interactive, readLine: { readLine() }) {
            case .proceed: break
            case .declined:
                out("nothing changed")
                return
            case .refused:
                throw CLIError.message(
                    "not accepting: the check did not pass and there is no terminal to ask on. "
                        + "Pass --yes to accept anyway.")
            }
        }

        var text = message
        if text == nil, plan.hasPendingChanges, interactive {
            out("")
            for line in plan.defaultMessage.split(separator: "\n", omittingEmptySubsequences: false) { out("  " + line) }
            print("Commit message: Enter keeps this, or type a one-line replacement: ", terminator: "")
            if let typed = readLine(), !typed.trimmingCharacters(in: .whitespaces).isEmpty { text = typed }
        }
        let result = try await ctx.service.accept(id: id, message: text, shown: plan)
        if result.committedNow {
            out("accepted \(id): committed \(result.commit) on \(result.branch). Nothing was pushed.")
        } else {
            out("accepted \(id): \(result.branch) at \(result.commit), already committed. Nothing was pushed.")
        }
        out("the worktree is kept for `ship`; the log is kept (`workbench log \(id)`)")
    }
}
