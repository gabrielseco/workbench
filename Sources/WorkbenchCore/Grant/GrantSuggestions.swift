import Foundation

/// A pattern worth adding to the project's `[tools] allowed`, because it was denied in more than one thread.
public struct GrantSuggestion: Sendable, Equatable {
    public var pattern: String
    /// The threads it was denied in, oldest first.
    public var threads: [String]

    /// The entry as it is written in the config's list.
    public var configEntry: String { "\"\(pattern)\"" }
}

/// Reads every thread's log for commands the project keeps being denied, and says which are safe to allow for good.
/// It only reads and suggests: the config is the person's to edit.
public enum GrantSuggestions {
    public static let minimumThreads = 2

    /// - Only commands rated `safe`, and only a narrow prefix rule such as `Bash(gh pr view:*)`. The exact text of
    ///   a command (`mkdir -p scratch`) is a one-off however often a script repeats it, so it is never suggested.
    /// - Not one the project already allows or denies, one that cannot be a valid pattern, or one the user turned
    ///   down with `--never` in any thread.
    public static func derive(threads: [(id: String, events: [Event])], tools: ToolSet) -> [GrantSuggestion] {
        var seen: [String: [String]] = [:]
        var refused: Set<String> = []
        for thread in threads {
            var inThread: Set<String> = []
            for candidate in GrantCandidates.derive(events: thread.events) {
                for part in candidate.parts {
                    guard let pattern = part.pattern, part.level == .safe else { continue }
                    inThread.insert(pattern)
                    if part.status == .refused { refused.insert(pattern) }
                }
            }
            for pattern in inThread { seen[pattern, default: []].append(thread.id) }
        }
        return seen.compactMap { pattern, ids -> GrantSuggestion? in
            guard ids.count >= minimumThreads, pattern.hasSuffix(":*)"), !refused.contains(pattern), isWritable(pattern),
                GrantPattern.problem(pattern, available: tools.available) == nil,
                GrantPattern.coveringEntry(of: pattern, in: tools.allowed) == nil,
                GrantPattern.deniedBy(pattern, denied: tools.denied) == nil
            else { return nil }
            return GrantSuggestion(pattern: pattern, threads: ids)
        }
        .sorted { ($1.threads.count, $0.pattern) < ($0.threads.count, $1.pattern) }
    }

    /// A TOML string needs no escaping: the suggestion is printed to be pasted as it is.
    private static func isWritable(_ pattern: String) -> Bool {
        !pattern.contains("\"") && !pattern.contains("\\")
    }
}

extension ThreadService {
    /// Suggestions from every thread of the project, history included.
    public func grantSuggestions(tools: ToolSet) -> [GrantSuggestion] {
        let store = ThreadStore(project: project)
        let threads = store.threadIDs().map { id in
            (id: id, events: (try? EventLogReader.read(at: project.eventsURL(id)).events) ?? [])
        }
        return GrantSuggestions.derive(threads: threads, tools: tools)
    }
}

extension GrantReport {
    /// What to print under the list, or after a decision about `pattern` only.
    public static func renderSuggestions(_ suggestions: [GrantSuggestion]) -> [String] {
        guard !suggestions.isEmpty else { return [] }
        var lines = [
            "",
            "Denied in more than one thread and safe. To allow for every thread, add to [tools] allowed in "
                + ".workbench/config.toml (nothing was changed):",
        ]
        for suggestion in suggestions {
            let shown = printable(suggestion.configEntry)
            lines.append("  \(shown),   (\(suggestion.threads.count) threads)")
        }
        return lines
    }
}
