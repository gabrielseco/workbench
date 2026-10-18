import Foundation
import WorkbenchCore

extension Commands {
    /// `grant [id]` lists a thread's denied commands; `grant [id] <n[.p]> --once|--thread|--never` decides one.
    static func grant(_ args: [String]) async throws {
        var a = Arguments(args)
        let scopes: [(String, GrantScope)] = [("--once", .once), ("--thread", .thread), ("--never", .never)]
        let chosen = scopes.filter { a.flag($0.0) }.map(\.1)
        let dangerous = a.flag("--allow-dangerous")
        var named = a.positional()
        var target: String?
        if let first = named, isDenialNumber(first) {
            target = first
            named = nil
        } else if let second = a.positional() {
            guard isDenialNumber(second) else { throw CLIError.usage("'\(second)' is not a denial number like 3 or 3.2") }
            target = second
        }
        try a.requireEmpty()
        let ctx = try await Context.load()

        guard let target else {
            if !chosen.isEmpty || dangerous {
                throw CLIError.usage("say which denial: workbench grant <number> --once | --thread | --never")
            }
            let id = try ctx.threadIDForViewing(named)
            let candidates = try ctx.service.grantCandidates(id: id)
            let suggestions = suggestions(ctx)
            if Output.json {
                printJSON(grantListJSON(thread: id, candidates: candidates, suggestions: suggestions))
            } else {
                for line in GrantReport.render(threadID: id, candidates: candidates) { out(line) }
                for line in GrantReport.renderSuggestions(suggestions) { out(line) }
            }
            return
        }
        guard chosen.count == 1, let scope = chosen.first else {
            throw CLIError.usage("pick exactly one of --once, --thread or --never")
        }
        let id = try ctx.threadID(named)
        let outcome: GrantOutcome
        do {
            outcome = try await ctx.service.grant(id: id, target: target, scope: scope, allowDangerous: dangerous)
        } catch let error as GrantError {
            switch error {
            case .refused(let message): throw CLIError.refused(message)
            case .notFound(let message): throw CLIError.notFound(message)
            }
        }
        let suggestion = outcome.scope == .never ? nil : suggestions(ctx).first { $0.pattern == outcome.pattern }
        if Output.json {
            printJSON([
                "v": 1, "thread": .string(id), "pattern": .string(outcome.pattern),
                "suggestion": suggestion.map(suggestionJSON) ?? .null,
                "scope": .string(outcome.scope.rawValue), "level": .string(GrantReport.level(outcome.level)),
                "recorded": .bool(outcome.seq != nil), "seq": outcome.seq.map { .int($0) } ?? .null,
            ])
            return
        }
        let pattern = GrantReport.printable(outcome.pattern)
        switch (outcome.seq, outcome.scope) {
        case (nil, _): out("already on record (\(outcome.scope.rawValue)): \(pattern)")
        case (_, .never): out("recorded: \(pattern) will not be offered again")
        case (_, .once): out("granted once: \(pattern) \u{2014} the next turn may run it, then it is gone")
        case (_, .thread): out("granted for \(id): \(pattern)")
        }
        if let suggestion { for line in GrantReport.renderSuggestions([suggestion]) { out(line) } }
        if outcome.scope != .never {
            out("next: workbench send-back \"<note>\"   or   workbench run --feedback \"<note>\"")
        }
    }

    /// Commands the project keeps being denied; empty when the config cannot be read.
    private static func suggestions(_ ctx: Context) -> [GrantSuggestion] {
        guard let config = try? Config.load(from: ctx.project.configURL) else { return [] }
        return ctx.service.grantSuggestions(tools: config.tools)
    }

    private static func suggestionJSON(_ suggestion: GrantSuggestion) -> JSONValue {
        [
            "pattern": .string(suggestion.pattern), "config_entry": .string(suggestion.configEntry),
            "threads": .array(suggestion.threads.map { .string($0) }),
        ]
    }

    private static func isDenialNumber(_ text: String) -> Bool {
        text.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    private static func statusName(_ status: GrantStatus) -> JSONValue {
        switch status {
        case .open: "open"
        case .granted(let scope): .string("granted_\(scope.rawValue)")
        case .refused: "never"
        }
    }

    static func grantListJSON(thread: String, candidates: [GrantCandidate], suggestions: [GrantSuggestion]) -> JSONValue {
        [
            "suggestions": .array(suggestions.map(suggestionJSON)),
            "v": 1, "thread": .string(thread),
            "denied": .array(
                candidates.map { candidate in
                    [
                        "number": .int(candidate.number), "tool": .string(candidate.tool),
                        "input": candidate.input.map { .string($0) } ?? .null,
                        "level": .string(GrantReport.level(candidate.assessment.level)),
                        "compound": .bool(candidate.assessment.isCompound),
                        "status": statusName(candidate.status),
                        "turns": .array(candidate.turns.map { .int($0) }), "seqs": .array(candidate.seqs.map { .int($0) }),
                        "parts": .array(
                            candidate.parts.map { part in
                                [
                                    "number": .string(part.number), "command": .string(part.command),
                                    "level": .string(GrantReport.level(part.level)),
                                    "pattern": part.pattern.map { .string($0) } ?? .null,
                                    "reasons": .array(part.reasons.map { .string($0) }), "status": statusName(part.status),
                                ]
                            }),
                    ]
                }),
        ]
    }
}
