import Foundation

/// One line of what `claude` said in a turn, wherever the log keeps it.
public struct TranscriptLine: Sendable, Equatable {
    public var turn: Int
    public var ts: String
    /// The line's `seq` when it is stored in `events.jsonl`; nil for a line kept somewhere else.
    public var seq: Int?
    /// The stream line as `claude` wrote it (or the truncation / invalid-JSON wrapper the writer made of it).
    public var data: JSONValue

    public init(turn: Int, ts: String, seq: Int?, data: JSONValue) {
        self.turn = turn
        self.ts = ts
        self.seq = seq
        self.data = data
    }

    /// nil unless `event` is a `claude` line.
    public init?(event: Event) {
        guard event.kind == .claude else { return nil }
        self.init(turn: event.turn, ts: event.ts, seq: event.seq, data: event.data)
    }
}

/// What `log` shows, in order: Workbench's own events and the transcript lines between them.
public enum LogEntry: Sendable, Equatable {
    case event(Event)
    case transcript(TranscriptLine)
}

/// A thread's log as `workbench log` reads it. Every reader of the transcript goes through here, so where the
/// transcript is stored is this file's business and no command's.
public struct ThreadLog: Sendable {
    public var entries: [LogEntry]
    public var contents: EventLogContents

    public static func read(at eventsURL: URL) throws -> ThreadLog {
        let contents = try EventLogReader.read(at: eventsURL)
        let entries = contents.events.map { event in
            TranscriptLine(event: event).map(LogEntry.transcript) ?? .event(event)
        }
        return ThreadLog(entries: entries, contents: contents)
    }
}
