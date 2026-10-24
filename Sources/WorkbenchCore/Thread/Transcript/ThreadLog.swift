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
    /// A turn's transcript file exists and cannot be read; said once, in place of its lines.
    case unreadableTranscript(turn: Int, reason: String)
}

public enum ThreadLogError: Error, Equatable, CustomStringConvertible {
    case unreadableTranscript(turn: Int, reason: String)

    public var description: String {
        switch self {
        case .unreadableTranscript(let turn, let reason): "the transcript of turn \(turn) cannot be read: \(reason)"
        }
    }
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
            case .unreadable(let turn, let reason): out.append(.unreadableTranscript(turn: turn, reason: reason))
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
            case .unreadable(let turn, let reason):
                out.append(
                    "{\"v\":\(Event.currentVersion),\"seq\":null,\"ts\":null,\"turn\":\(turn),"
                        + "\"kind\":\"transcript.unreadable\",\"data\":{\"reason\":\(Self.quoted(reason))}}")
            case .transcript(let turn, let stored):
                out.append(
                    "{\"v\":\(Event.currentVersion),\"seq\":null,\"ts\":\(Self.quoted(stored.ts)),\"turn\":\(turn),"
                        + "\"kind\":\"claude\",\"data\":\(stored.rawData)}")
            }
        }
        return (out, position)
    }

    /// The stream lines of the thread as they were stored, one string each, oldest turn first (`turn` limits it
    /// to one). The lines of a turn with a transcript file come from there, gzipped or not; those of an older
    /// log from its `claude` events, whose `data` is cut out of the stored line.
    public func transcript(turn only: Int? = nil) throws -> [String] {
        let aligned = rawEventLines.count == contents.events.count
        var out: [String] = []
        let turns = Set(contents.events.filter { $0.kind == .turnStarted }.map(\.turn)).sorted()
        for turn in turns where only == nil || only == turn {
            let file = TranscriptFile.url(in: threadDirectory, turn: turn)
            switch TranscriptFile.load(file) {
            case .data(let data):
                out += TranscriptFile.parse(data, from: 0).lines.map(\.rawData)
                continue
            case .unreadable(let reason):
                throw ThreadLogError.unreadableTranscript(turn: turn, reason: reason)
            case .missing:
                break
            }
            for (index, event) in contents.events.enumerated() where event.kind == .claude && event.turn == turn {
                if aligned, let open = rawEventLines[index].range(of: "\"data\":") {
                    out.append(String(rawEventLines[index][open.upperBound...].dropLast()))
                } else if let json = try? EventLogWriter.json(event.data) {
                    out.append(json)
                }
            }
        }
        return out
    }

    private enum Item {
        case event(Event, index: Int)
        case transcript(turn: Int, TranscriptFile.Stored)
        case unreadable(turn: Int, reason: String)
    }

    private func walk(after start: Position, _ emit: (Item) -> Void) -> Position {
        var position = start
        // Each turn's file is read (and, once ended, inflated) once per walk.
        var loaded: [Int: TranscriptFile.Contents] = [:]
        func transcriptFile(_ turn: Int) -> TranscriptFile.Contents {
            if let known = loaded[turn] { return known }
            let found = TranscriptFile.load(TranscriptFile.url(in: threadDirectory, turn: turn))
            loaded[turn] = found
            return found
        }
        func flush(_ turn: Int) {
            switch transcriptFile(turn) {
            case .missing:
                return
            case .unreadable(let reason):
                // Said once; the marker keeps a follower from saying it again.
                if position.transcript[turn] != Int.max { emit(.unreadable(turn: turn, reason: reason)) }
                position.transcript[turn] = Int.max
            case .data(let data):
                let (lines, offset) = TranscriptFile.parse(data, from: position.transcript[turn] ?? 0)
                for line in lines { emit(.transcript(turn: turn, line)) }
                if offset > 0 { position.transcript[turn] = offset }
            }
        }
        // Only a transcript that reads is shown in place of the log's own `result` line.
        func hasTranscript(_ turn: Int) -> Bool {
            if case .data = transcriptFile(turn) { return true }
            return false
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
