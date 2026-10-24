import Foundation

/// One line of what `claude` said in a turn, wherever the log keeps it.
public struct TranscriptLine: Sendable, Equatable {
    public var turn: Int
    public var ts: String
    /// The line's `seq` when it is stored in `events.jsonl` (an older log); nil for a line in a transcript file.
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

/// A thread's log as `workbench log` reads it: `events.jsonl` and the transcript files beside it. Every reader
/// of the transcript goes through here, so where the transcript is stored is this file's business and no
/// command's.
///
/// A turn's transcript lines are shown just before its `turn.ended` (or, while it is open, after the newest
/// event). A turn that has a transcript file shows its `result` line from there, not twice: the log keeps that
/// line as a `claude` event too, because cost, session and denials are derived from it. A turn of an older log
/// has no file and shows the `claude` events it holds.
public struct ThreadLog: Sendable {
    public var contents: EventLogContents
    private let threadDirectory: URL
    private let rawEventLines: [String]

    /// How much a reader has been given: events by count, each transcript by byte offset.
    public struct Position: Sendable, Equatable {
        public var events = 0
        public var transcript: [Int: Int] = [:]
        public init() {}
    }

    public static func read(at eventsURL: URL) throws -> ThreadLog {
        // One read serves the events and the raw lines: a log that grows between two reads would make them disagree.
        let data: Data
        do { data = try Data(contentsOf: eventsURL) } catch {
            throw EventLogError.io("cannot read \(eventsURL.path): \(error.localizedDescription)")
        }
        EventLogReadCount.record(eventsURL)
        let contents = EventLogReader.parse(data)
        // Split as bytes: a writer that died inside a multibyte character must not hide the events before it.
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        _ = parts.popLast()  // the part after the last newline is not a whole event yet
        return ThreadLog(
            contents: contents, threadDirectory: eventsURL.deletingLastPathComponent(),
            rawEventLines: parts.map { String(decoding: $0, as: UTF8.self) })
    }

    /// Everything, in order.
    public var entries: [LogEntry] { entries(after: Position()).entries }

    /// What was not given at `position`, and the position after it.
    public func entries(after position: Position) -> (entries: [LogEntry], position: Position) {
        var out: [LogEntry] = []
        let position = walk(after: position) { item in
            switch item {
            case .event(let event, _): out.append(TranscriptLine(event: event).map(LogEntry.transcript) ?? .event(event))
            case .transcript(let turn, let stored):
                out.append(.transcript(TranscriptLine(turn: turn, ts: stored.ts, seq: nil, data: stored.data)))
            }
        }
        return (out, position)
    }

    /// The same as `entries(after:)` for `log --json`: the stored lines, one JSON object each. An event is its
    /// line in `events.jsonl` as it was written; a transcript line is written as the `claude` event it would
    /// have been (`seq` null), its `data` verbatim. A log with a line that is not an event cannot say which raw
    /// line is which, so it is printed as it is, without transcripts.
    public func jsonLines(after position: Position) -> (lines: [String], position: Position) {
        guard rawEventLines.count == contents.events.count else {
            var next = position
            next.events = rawEventLines.count
            return (Array(rawEventLines.dropFirst(position.events)), next)
        }
        var out: [String] = []
        let position = walk(after: position) { item in
            switch item {
            case .event(_, let index): out.append(rawEventLines[index])
            case .transcript(let turn, let stored):
                out.append(
                    "{\"v\":\(Event.currentVersion),\"seq\":null,\"ts\":\(Self.quoted(stored.ts)),\"turn\":\(turn),"
                        + "\"kind\":\"claude\",\"data\":\(stored.rawData)}")
            }
        }
        return (out, position)
    }

    private enum Item {
        case event(Event, index: Int)
        case transcript(turn: Int, TranscriptFile.Stored)
    }

    private func walk(after start: Position, _ emit: (Item) -> Void) -> Position {
        var position = start
        func flush(_ turn: Int) {
            let url = TranscriptFile.url(in: threadDirectory, turn: turn)
            let (lines, offset) = TranscriptFile.read(at: url, from: position.transcript[turn] ?? 0)
            for line in lines { emit(.transcript(turn: turn, line)) }
            if offset > 0 { position.transcript[turn] = offset }
        }
        var hasFile: [Int: Bool] = [:]
        func hasTranscript(_ turn: Int) -> Bool {
            if let known = hasFile[turn] { return known }
            let found = FileManager.default.fileExists(atPath: TranscriptFile.url(in: threadDirectory, turn: turn).path)
            hasFile[turn] = found
            return found
        }
        for (index, event) in contents.events.enumerated().dropFirst(start.events) {
            // The turn's `result` line is shown from its transcript when it has one.
            if event.kind == .claude, event.data["type"]?.stringValue == "result", hasTranscript(event.turn) { continue }
            if event.kind == .turnEnded { flush(event.turn) }
            emit(.event(event, index: index))
        }
        position.events = contents.events.count
        if let open = contents.openTurn { flush(open) }
        return position
    }

    private static func quoted(_ text: String) -> String {
        (try? EventLogWriter.json(.string(text))) ?? "\"\""
    }
}
