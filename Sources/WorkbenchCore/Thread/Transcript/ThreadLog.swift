import Foundation

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
/// `log` shows the events: a turn is in the log as its `agent.activity`. What the agent printed is in the turn's
/// transcript file and comes out only through `transcript(turn:)` (`log --transcript`).
public struct ThreadLog: Sendable {
    public var contents: EventLogContents
    private let threadDirectory: URL
    private let rawEventLines: [String]

    /// How much a reader has been given: events by count.
    public struct Position: Sendable, Equatable {
        public var events = 0
        public init() {}
    }

    public static func read(at eventsURL: URL) throws -> ThreadLog {
        // One read serves the events and the raw lines: a log that grows between two reads would make them disagree.
        let data: Data
        do { data = try Data(contentsOf: eventsURL) } catch {
            throw EventLogError.io("cannot read \(eventsURL.path): \(error.localizedDescription)")
        }
        EventLogReadCount.record(eventsURL, bytes: data.count)
        let contents = EventLogReader.parse(data)
        // Split as bytes: a writer that died inside a multibyte character must not hide the events before it.
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        _ = parts.popLast()  // the part after the last newline is not a whole event yet
        return ThreadLog(
            contents: contents, threadDirectory: eventsURL.deletingLastPathComponent(),
            rawEventLines: parts.map { String(decoding: $0, as: UTF8.self) })
    }

    /// Everything, in order.
    public var entries: [Event] { contents.events }

    /// What was not given at `position`, and the position after it.
    public func entries(after position: Position) -> (entries: [Event], position: Position) {
        var next = position
        next.events = contents.events.count
        return (Array(contents.events.dropFirst(position.events)), next)
    }

    /// The same as `entries(after:)` for `log --json`: the stored lines, one JSON object each, as they were written.
    public func jsonLines(after position: Position) -> (lines: [String], position: Position) {
        var next = position
        next.events = rawEventLines.count
        return (Array(rawEventLines.dropFirst(position.events)), next)
    }

    /// The stream lines of the thread as they were stored, one string each, oldest turn first (`turn` limits it
    /// to one), from the turn's transcript file, gzipped or not.
    public func transcript(turn only: Int? = nil) throws -> [String] {
        var out: [String] = []
        let turns = Set(contents.events.filter { $0.kind == .turnStarted }.map(\.turn)).sorted()
        for turn in turns where only == nil || only == turn {
            switch TranscriptFile.load(TranscriptFile.url(in: threadDirectory, turn: turn)) {
            case .data(let data): out += TranscriptFile.parse(data, from: 0).lines.map(\.rawData)
            case .unreadable(let reason): throw ThreadLogError.unreadableTranscript(turn: turn, reason: reason)
            case .missing: break
            }
        }
        return out
    }
}
