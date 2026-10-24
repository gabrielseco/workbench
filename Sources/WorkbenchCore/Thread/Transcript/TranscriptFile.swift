import Foundation

/// What a turn's transcript file holds, for `turn.ended`.
public struct TranscriptSummary: Sendable, Equatable {
    public var lines: Int
    public var bytes: Int

    public var json: JSONValue { ["lines": .int(lines), "bytes": .int(bytes)] }
}

/// A turn's `claude` output, one line per stream line, kept beside the event log in
/// `threads/<id>/transcript/turn-<n>.jsonl`. Each line is `{"ts": ..., "data": <the line as claude wrote it>}`;
/// `data` is the same value the log used to hold in a `claude` event (the line itself, a truncation marker or an
/// `invalid_json` wrapper), so nothing that was kept before is dropped. The log keeps the turn's `result` line
/// and, on `turn.ended`, how many lines and bytes this file has.
public enum TranscriptFile {
    public static func directory(in threadDirectory: URL) -> URL {
        threadDirectory.appendingPathComponent("transcript")
    }

    public static func url(in threadDirectory: URL, turn: Int) -> URL {
        directory(in: threadDirectory).appendingPathComponent("turn-\(turn).jsonl")
    }

    /// Where the turn's file goes once the turn has ended: the same bytes, gzipped.
    public static func compressedURL(_ plain: URL) -> URL { plain.appendingPathExtension("gz") }

    /// A turn's transcript is gzipped when it ends unless it is bigger than this; a file left plain reads the same.
    public static let maxCompressedBytes = 256 << 20

    /// What a turn's transcript is on disk: not there, its bytes, or there and not readable (a damaged or altered
    /// `.gz`), which must not read as "nothing was said".
    enum Contents {
        case missing
        case data(Data)
        case unreadable(String)
    }

    /// The file's bytes, plain or (once the turn has ended) gzipped.
    static func load(_ plain: URL) -> Contents {
        // The plain file goes only after the compressed one is in place, so one of the two is always readable.
        if let data = try? Data(contentsOf: plain) { return .data(data) }
        let packedURL = compressedURL(plain)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: packedURL.path))?[.size] as? Int else {
            return .missing
        }
        // A file we wrote is never bigger than the plain one we were allowed to compress.
        guard size <= maxCompressedBytes else { return .unreadable("the file is over the size limit") }
        guard let packed = try? Data(contentsOf: packedURL) else { return .unreadable("the file cannot be read") }
        do { return .data(try Gzip.decompress(packed)) } catch let failure as Gzip.Failure {
            switch failure {
            case .notGzip: return .unreadable("not a gzip file")
            case .corrupt(let why): return .unreadable("damaged (\(why))")
            case .tooLarge: return .unreadable("it inflates past the size limit")
            }
        } catch { return .unreadable("\(error)") }
    }

    /// The bytes when there are some; nil for a turn with no transcript or one that cannot be read.
    static func contents(_ plain: URL) -> Data? {
        if case .data(let data) = load(plain) { return data }
        return nil
    }

    /// Whether the turn has a transcript, in either form.
    public static func exists(_ plain: URL) -> Bool {
        FileManager.default.fileExists(atPath: plain.path)
            || FileManager.default.fileExists(atPath: compressedURL(plain).path)
    }

    /// Gzips a finished turn's transcript next to the plain file, then removes the plain one. A failure of any
    /// step leaves the plain file, which reads the same; returns whether the turn now has a compressed file.
    @discardableResult
    public static func compress(_ plain: URL, limit: Int = maxCompressedBytes) -> Bool {
        let packed = compressedURL(plain)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: plain.path))?[.size] as? Int,
            size <= limit, let data = try? Data(contentsOf: plain), let gz = try? Gzip.compress(data)
        else { return FileManager.default.fileExists(atPath: packed.path) }
        let partial = packed.appendingPathExtension("partial")
        do {
            try gz.write(to: partial)
            // What was written must read back as what was compressed, or the plain file is the only copy.
            guard try Gzip.decompress(Data(contentsOf: partial)) == data else { throw Gzip.Failure.corrupt("verify") }
            try FileManager.default.moveItem(at: partial, to: packed)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return false
        }
        try? FileManager.default.removeItem(at: plain)
        return true
    }

    /// One stored line: its time, the `data` as stored (verbatim text, for `log --json`) and decoded.
    struct Stored {
        var ts: String
        var rawData: String
        var data: JSONValue
    }

    /// The complete lines from byte `offset` on, and the offset after them. A torn last line is not a line yet:
    /// the next read, from the returned offset, finds it whole.
    static func read(at url: URL, from offset: Int = 0) -> (lines: [Stored], offset: Int) {
        guard let data = contents(url) else { return ([], offset) }
        return parse(data, from: offset)
    }

    static func parse(_ data: Data, from offset: Int) -> (lines: [Stored], offset: Int) {
        guard offset <= data.count else { return ([], offset) }
        let decoder = JSONDecoder()
        var lines: [Stored] = []
        var start = data.startIndex + offset
        while let end = data[start...].firstIndex(of: 0x0A) {
            let line = data[start..<end]
            if let record = try? decoder.decode(Record.self, from: line),
                let open = line.range(of: Data("\"data\":".utf8)), line.last == UInt8(ascii: "}") {
                let raw = String(decoding: line[open.upperBound..<line.index(before: line.endIndex)], as: UTF8.self)
                lines.append(Stored(ts: record.ts, rawData: raw, data: record.data))
            }
            start = data.index(after: end)
        }
        return (lines, start - data.startIndex)
    }

    /// The complete lines of the file as transcript lines.
    public static func lines(at url: URL, turn: Int) -> [TranscriptLine] {
        read(at: url).lines.map { TranscriptLine(turn: turn, ts: $0.ts, seq: nil, data: $0.data) }
    }

    /// How many complete lines and bytes the file holds; nil when there is no file.
    public static func summary(at url: URL) -> TranscriptSummary? {
        guard let data = contents(url) else { return nil }
        guard let last = data.lastIndex(of: 0x0A) else { return TranscriptSummary(lines: 0, bytes: 0) }
        let complete = data[...last]
        return TranscriptSummary(lines: complete.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }, bytes: complete.count)
    }

    /// Cuts a torn last line off a file a dead writer left, and says what is left; nil when there is no file.
    @discardableResult
    public static func repair(at url: URL) -> TranscriptSummary? {
        guard let summary = summary(at: url) else { return nil }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > summary.bytes,
            let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(summary.bytes))
            try? handle.close()
        }
        return summary
    }

    struct Record: Decodable {
        var ts: String
        var data: JSONValue
    }
}

/// Appends one turn's lines. Called one line at a time by the recorder, so it needs no lock of its own.
public final class TranscriptWriter: @unchecked Sendable {
    public static let defaultMaxLineBytes = EventLogWriter.defaultMaxClaudeLineBytes

    private let url: URL
    private let maxLineBytes: Int
    private let now: @Sendable () -> Date
    private var handle: FileHandle?
    private(set) var lines = 0
    private(set) var bytes = 0

    public init(
        url: URL, maxLineBytes: Int = defaultMaxLineBytes, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.maxLineBytes = maxLineBytes
        self.now = now
    }

    /// What was written, for `turn.ended`; nil when no line was.
    public var summary: TranscriptSummary? { lines == 0 ? nil : TranscriptSummary(lines: lines, bytes: bytes) }

    /// One raw line from the process, stored the way the log stored a `claude` line.
    public func append(_ raw: String) throws {
        try write(dataJSON: try EventLogWriter.claudeDataJSON(raw, maxBytes: maxLineBytes))
    }

    /// A line the process runner already cut short.
    public func appendOversized(preview: String, totalBytes: Int) throws {
        try write(dataJSON: try EventLogWriter.oversizedDataJSON(preview: preview, totalBytes: totalBytes))
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    private func write(dataJSON: String) throws {
        let ts = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now())
        let line = "{\"ts\":\(try EventLogWriter.json(.string(ts))),\"data\":\(dataJSON)}\n"
        do {
            if handle == nil {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A line is appended, never rewritten; a file left by an earlier run of this turn is kept whole.
                let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
                guard fd >= 0 else { throw EventLogError.io("cannot open \(url.path): \(String(cString: strerror(errno)))") }
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            }
            try handle?.write(contentsOf: Data(line.utf8))
        } catch let error as EventLogError {
            throw error
        } catch {
            throw EventLogError.io("transcript append failed: \(error)")
        }
        lines += 1
        bytes += line.utf8.count
    }
}
