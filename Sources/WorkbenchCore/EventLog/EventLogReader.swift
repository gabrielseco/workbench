import Foundation

/// Everything a replay learned about a log file.
public struct EventLogContents: Sendable {
    /// Events that decoded, in file order. Includes events that broke an invariant; see `problems`.
    public var events: [Event]
    public var problems: [LogProblem]
    /// Bytes after the last newline: a write that was cut short. Not a problem, a crash artifact.
    public var truncatedTail: Data?
    /// Number of bytes up to and including the last newline.
    public var completeByteCount: Int
    /// A turn that started and never ended, if any.
    public var openTurn: Int?
    public var lastTurn: Int
    /// The turn whose check started and never ended, if any.
    public var openCheck: Int?

    public var isHealthy: Bool { problems.isEmpty && truncatedTail == nil }
}

public enum EventLogReader {
    public static func read(at url: URL) throws -> EventLogContents {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw EventLogError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> EventLogContents {
        var contents = EventLogContents(
            events: [], problems: [], truncatedTail: nil, completeByteCount: 0, openTurn: nil, lastTurn: 0)
        var state = LogState()
        let decoder = JSONDecoder()
        let newline = UInt8(ascii: "\n")

        var lineStart = data.startIndex
        var lineNumber = 0
        while let end = data[lineStart...].firstIndex(of: newline) {
            lineNumber += 1
            let line = data[lineStart..<end]
            if let event = try? decoder.decode(Event.self, from: line) {
                if let problem = state.check(event, line: lineNumber) {
                    contents.problems.append(problem)
                }
                state.apply(event)
                contents.events.append(event)
            } else {
                contents.problems.append(.invalidLine(line: lineNumber))
            }
            lineStart = data.index(after: end)
        }

        contents.completeByteCount = lineStart - data.startIndex
        if lineStart < data.endIndex {
            contents.truncatedTail = Data(data[lineStart...])
        }
        contents.openTurn = state.openTurn
        contents.lastTurn = state.lastTurn
        contents.openCheck = state.openCheck
        return contents
    }
}
