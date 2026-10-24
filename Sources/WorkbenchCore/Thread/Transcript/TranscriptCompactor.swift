import Foundation

/// Moves the `claude` lines of a log written before transcript files out of `events.jsonl`, into the turn's
/// transcript file, gzipped. Temporary: it is there for the logs that exist today and goes with the old shape.
///
/// What it does to a thread that has ended, in an order a crash cannot hurt:
/// 1. builds each turn's transcript from the log's `claude` events, `data` cut out of the stored line, so the lines
///    are byte for byte what the log held;
/// 2. builds the new log: every other event, and each turn's `result` line (cost, session and denials come from
///    it), with `seq` numbered again from 1 so it has no gaps. Two fields refer to a `seq` and are changed with it:
///    `grant.added`'s `denial_seq` and the `a<seq>` ids of agent attempts. A moved turn's `turn.ended` gains the
///    `transcript` counts a new turn has;
/// 3. checks the new log replays to the same state (the `seq` numbers apart) and every transcript line is its event;
/// 4. puts the transcript files in place, then renames the new log over the old one. A reader shows a turn from its
///    file when it has one, so a crash between the two steps shows nothing twice; running it again finishes.
/// It holds the log's lock throughout, refuses a thread that has not ended, and a second run finds nothing to do.
public struct TranscriptCompactor: Sendable {
    public struct Report: Sendable, Equatable {
        public var thread: String
        public var turns: [Int]
        public var lines: Int
        /// The transcript's bytes before gzip, and what the files take on disk.
        public var transcriptBytes: Int
        public var transcriptDiskBytes: Int
        public var logBytesBefore: Int
        public var logBytesAfter: Int
        /// False for a dry run: nothing was written.
        public var applied: Bool
    }

    public enum Outcome: Sendable, Equatable {
        case compacted(Report)
        case nothingToDo
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case active
        case running(pid: Int32)
        case unhealthy(String)
        case verification(String)
        case io(String)

        public var description: String {
            switch self {
            case .active: "the thread has not ended; accept, discard or abandon it first"
            case .running(let pid): "a run is live on it (pid \(pid))"
            case .unhealthy(let why): "its log is not healthy: \(why)"
            case .verification(let why): "the compacted log would not match the original, so nothing was changed: \(why)"
            case .io(let why): why
            }
        }
    }

    public let project: Project

    public init(project: Project) { self.project = project }

    private struct StagedFile {
        var turn: Int
        var name: String
        var data: Data
        /// The transcript's bytes before gzip, which is what an existing file has to hold for this one to be skipped.
        var plain: Data
    }

    private struct Rebuilt {
        var log: Data
        var files: [StagedFile]
        var report: Report
    }

    public func compact(id: String, dryRun: Bool = false) async throws -> Outcome {
        guard SafeNames.isThreadID(id) else { throw Failure.io("'\(id)' is not a thread id") }
        let store = ThreadStore(project: project)
        if store.summary(of: id).isActive { throw Failure.active }
        if let pid = store.runnerPID(id: id) { throw Failure.running(pid: pid) }

        let url = project.eventsURL(id)
        // Looked at before the writer is opened: opening repairs a torn tail, which a dry run must not do.
        let contents = try EventLogReader.read(at: url)
        guard contents.isHealthy else {
            let why = contents.truncatedTail != nil ? "it ends in a half-written event" : "\(contents.problems.count) problem(s)"
            throw Failure.unhealthy(why)
        }
        let writer: EventLogWriter
        do { writer = try EventLogWriter.open(at: url) } catch EventLogError.corrupt(let problems) {
            throw Failure.unhealthy("\(problems.count) problem(s)")
        } catch { throw Failure.io("\(error)") }

        do {
            let outcome = try rebuild(id: id, url: url).map { rebuilt -> Outcome in
                if !dryRun { try apply(rebuilt, id: id, url: url) }
                var report = rebuilt.report
                report.applied = !dryRun
                return .compacted(report)
            } ?? .nothingToDo
            await writer.close()
            return outcome
        } catch {
            await writer.close()
            throw error
        }
    }

    // MARK: building and checking

    private func rebuild(id: String, url: URL) throws -> Rebuilt? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure.io("cannot read \(url.path)") }
        let original = EventLogReader.parse(data)
        guard original.isHealthy else { throw Failure.unhealthy("it has problems; `workbench doctor` or the log's tail") }
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        _ = parts.popLast()
        guard parts.count == original.events.count else { throw Failure.unhealthy("a line is not an event") }
        let lines = parts.map { String(decoding: $0, as: UTF8.self) }
        let events = original.events

        // Turns that still hold stream lines in the log: more than their result line.
        var claudeByTurn: [Int: [Int]] = [:]
        for (index, event) in events.enumerated() where event.kind == .claude {
            claudeByTurn[event.turn, default: []].append(index)
        }
        let moved = Set(claudeByTurn.filter { _, indices in indices.contains { !Self.isResult(events[$0]) } }.keys)
        guard !moved.isEmpty else { return nil }

        // 1. Each moved turn's transcript, from the stored lines.
        var transcripts: [Int: Data] = [:]
        var summaries: [Int: TranscriptSummary] = [:]
        for turn in moved.sorted() {
            var file = Data()
            var count = 0
            for index in claudeByTurn[turn] ?? [] {
                let raw = try Self.rawData(of: lines[index])
                let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
                guard decoded == events[index].data else {
                    throw Failure.verification("turn \(turn), event \(events[index].seq): its data does not read back")
                }
                file.append(Data("{\"ts\":\(try EventLogWriter.json(.string(events[index].ts))),\"data\":\(raw)}\n".utf8))
                count += 1
            }
            transcripts[turn] = file
            summaries[turn] = TranscriptSummary(lines: count, bytes: file.count)
        }

        // 2. The new log.
        var newLines: [String] = []
        var seqs: [Int: Int] = [:]
        var attempts: [String: String] = [:]
        for (index, event) in events.enumerated() {
            if event.kind == .claude, moved.contains(event.turn), !Self.isResult(event) { continue }
            let seq = newLines.count + 1
            seqs[event.seq] = seq
            var changed = event.data
            var rebuildLine = false
            if event.kind == .turnEnded, let summary = summaries[event.turn], event.data["transcript"] == nil {
                changed = Self.setting("transcript", summary.json, in: changed)
                rebuildLine = true
            }
            if event.kind.rawValue == "grant.added", let old = event.data["denial_seq"]?.intValue {
                guard let new = seqs[old] else { throw Failure.verification("grant.added refers to event \(old), which is gone") }
                changed = Self.setting("denial_seq", .int(new), in: changed)
                rebuildLine = true
            }
            if let attempt = event.data["attempt"]?.stringValue {
                let renamed = event.kind.rawValue == "agent.attempt.started" ? "a\(seq)" : attempts[attempt]
                if event.kind.rawValue == "agent.attempt.started" { attempts[attempt] = renamed }
                if let renamed, renamed != attempt {
                    changed = Self.setting("attempt", .string(renamed), in: changed)
                    rebuildLine = true
                }
            }
            if rebuildLine {
                let numbered = Event(v: event.v, seq: seq, ts: event.ts, turn: event.turn, kind: event.kind, data: changed)
                newLines.append(try EventLogWriter.encodedLine(numbered, dataJSON: try EventLogWriter.json(changed)))
            } else {
                let prefix = "{\"v\":\(event.v),\"seq\":\(event.seq),"
                guard lines[index].hasPrefix(prefix) else {
                    throw Failure.verification("event \(event.seq) is stored in an unknown shape")
                }
                newLines.append("{\"v\":\(event.v),\"seq\":\(seq)," + lines[index].dropFirst(prefix.count))
            }
        }
        let newLog = Data((newLines.joined(separator: "\n") + "\n").utf8)

        // 3. It has to replay to the same thread.
        let rebuilt = EventLogReader.parse(newLog)
        guard rebuilt.isHealthy, rebuilt.events.count == newLines.count else {
            throw Failure.verification("the new log does not replay cleanly")
        }
        guard ThreadState.derive(from: events, id: id).comparable == ThreadState.derive(from: rebuilt.events, id: id).comparable
        else { throw Failure.verification("the thread's state would change") }
        func shown(_ candidates: [GrantCandidate]) -> [String] { candidates.map { "\($0.tool)|\($0.input ?? "")|\($0.turns)" } }
        guard shown(GrantCandidates.derive(events: events)) == shown(GrantCandidates.derive(events: rebuilt.events)),
            GrantLedger(events: events).refused == GrantLedger(events: rebuilt.events).refused
        else { throw Failure.verification("what `grant` lists would change") }
        for event in rebuilt.events where event.kind.rawValue == "grant.added" {
            if let denial = event.data["denial_seq"]?.intValue, rebuilt.events[denial - 1].kind != .claude {
                throw Failure.verification("a grant would point at event \(denial), which is not the denial")
            }
        }

        // The files as they will be stored: gzipped unless that is not allowed or does not pay.
        var files: [StagedFile] = []
        for turn in moved.sorted() {
            let plain = transcripts[turn] ?? Data()
            let name = TranscriptFile.url(in: URL(fileURLWithPath: "/"), turn: turn).lastPathComponent
            if plain.count <= TranscriptFile.maxCompressedBytes, let packed = try? Gzip.compress(plain),
                (try? Gzip.decompress(packed)) == plain {
                files.append(StagedFile(turn: turn, name: name + ".gz", data: packed, plain: plain))
            } else {
                files.append(StagedFile(turn: turn, name: name, data: plain, plain: plain))
            }
        }
        // A transcript already there, in either form, has to be these very lines: it is what a reader will show.
        for file in files {
            let existing = TranscriptFile.url(in: project.threadDirectory(id), turn: file.turn)
            switch TranscriptFile.load(existing) {
            case .missing: break
            case .data(let have):
                guard have == file.plain else {
                    throw Failure.verification("turn \(file.turn) already has a transcript file that differs")
                }
            case .unreadable(let why):
                throw Failure.verification("turn \(file.turn) has a transcript file that cannot be read (\(why))")
            }
        }
        let report = Report(
            thread: id, turns: moved.sorted(), lines: summaries.values.reduce(0) { $0 + $1.lines },
            transcriptBytes: transcripts.values.reduce(0) { $0 + $1.count },
            transcriptDiskBytes: files.reduce(0) { $0 + $1.data.count },
            logBytesBefore: data.count, logBytesAfter: newLog.count, applied: false)
        return Rebuilt(log: newLog, files: files, report: report)
    }

    // MARK: writing

    private func apply(_ rebuilt: Rebuilt, id: String, url: URL) throws {
        let fileManager = FileManager.default
        let thread = project.threadDirectory(id)
        let staging = thread.appendingPathComponent("transcript.compacting")
        let staged = url.appendingPathExtension("compacting")
        try? fileManager.removeItem(at: staging)
        try? fileManager.removeItem(at: staged)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in rebuilt.files { try file.data.write(to: staging.appendingPathComponent(file.name)) }
            try rebuilt.log.write(to: staged)

            // Transcript files first, then the log: a crash in between leaves both, and a reader shows the file.
            let destination = TranscriptFile.directory(in: thread)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in rebuilt.files {
                // An interrupted run left it, and it was checked to hold these lines: keep it.
                if TranscriptFile.exists(TranscriptFile.url(in: thread, turn: file.turn)) { continue }
                try fileManager.moveItem(
                    at: staging.appendingPathComponent(file.name), to: destination.appendingPathComponent(file.name))
            }
            guard Darwin.rename(staged.path, url.path) == 0 else {
                throw Failure.io("cannot replace \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            try? fileManager.removeItem(at: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: staged)
            throw error as? Failure ?? Failure.io("\(error)")
        }
    }

    // MARK: helpers

    private static func isResult(_ event: Event) -> Bool { event.data["type"]?.stringValue == "result" }

    /// The text of a stored line's `data`: everything after `"data":` up to the closing brace of the event.
    private static func rawData(of line: String) throws -> String {
        guard let marker = line.range(of: "\"data\":"), line.hasSuffix("}") else {
            throw Failure.verification("an event is stored in an unknown shape")
        }
        return String(line[marker.upperBound...].dropLast())
    }

    private static func setting(_ key: String, _ value: JSONValue, in data: JSONValue) -> JSONValue {
        guard case .object(var fields) = data else { return [key: value] }
        fields[key] = value
        return .object(fields)
    }
}

extension ThreadState {
    /// The state with what a rewrite of the log is allowed to change taken out: the `seq` it numbers events by (and the
    /// attempt ids made of one), and the progress folded from stream lines (an ended thread's is not shown).
    fileprivate var comparable: ThreadState {
        var copy = self
        copy.review.notes = copy.review.notes.map { var note = $0; note.seq = 0; return note }
        copy.review.deniedTools = copy.review.deniedTools.map { var tool = $0; tool.seq = 0; return tool }
        copy.progress = Progress()
        // An attempt is named a<seq of its start>, and the seq changes.
        copy.agentUse = copy.agentUse.mapValues { use in
            var use = use
            use.attempt = use.attempt == nil ? nil : "a"
            return use
        }
        return copy
    }
}
