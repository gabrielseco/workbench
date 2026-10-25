import Foundation

/// Who adopts a process whose parent died, found by doing it: a shell starts a `sleep` and exits at once, and the
/// `sleep`'s new parent is read. Only the kernel knows which ancestor is a subreaper (a user's `systemd --user`, a
/// supervisor, a container's init), and it is not always PID 1.
enum AdopterProbe {
    struct Outcome {
        var adopter: ProcessMember?
        var shell: pid_t?
    }

    /// `script` gets the name of a file as `$1` and must write the pid of an orphan-to-be into it. Every wait is bounded
    /// (`patience` is in 10 ms steps) and a probe that does not finish is killed and reaped, not left behind.
    static func measure(
        on host: some ProcessInspecting, script: String = "sleep 30 & echo $! > \"$1\"", patience: Int = 200
    ) -> Outcome {
        let name = FileManager.default.temporaryDirectory.appendingPathComponent("wb-adopter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: name) }
        let sink = open("/dev/null", O_WRONLY | O_CLOEXEC)
        defer { if sink >= 0 { close(sink) } }
        guard sink >= 0,
            let shell = try? Spawner.spawn(
                executable: "/bin/sh", arguments: ["-c", script, "sh", name.path],
                environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", stdout: sink, stderr: sink)
        else { return Outcome() }
        var status: Int32 = 0
        var waited = 0
        // Polled, never a blocking wait (docs/plan/P1-runner.md): the shell ends within milliseconds.
        while waitpid(shell, &status, WNOHANG) == 0 {
            guard waited < patience else { return Outcome(adopter: nil, shell: endGroup(shell)) }
            usleep(10_000)
            waited += 1
        }
        let text = (try? String(contentsOf: name, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, let sleeper = pid_t(text), let born = host.member(for: sleeper) else {
            return Outcome(adopter: nil, shell: shell)
        }
        defer { if host.member(for: sleeper) == born { kill(sleeper, SIGKILL) } }
        for _ in 0..<100 {
            if let parent = host.parent(of: sleeper), parent != shell {
                // PID 1 may not be readable (macOS); it is an adopter all the same.
                let adopter = host.member(for: parent) ?? ProcessMember(pid: parent, startSeconds: 0, startMicros: 0)
                return Outcome(adopter: adopter, shell: shell)
            }
            usleep(10_000)
        }
        return Outcome(adopter: nil, shell: shell)
    }

    /// The shell leads its own process group, so the group is the shell and whatever it started.
    private static func endGroup(_ shell: pid_t) -> pid_t {
        kill(-shell, SIGKILL)
        var status: Int32 = 0
        for _ in 0..<100 where waitpid(shell, &status, WNOHANG) == 0 { usleep(5_000) }
        return shell
    }
}

/// Adopters that earlier Workbench runs measured, kept in a small file so a leftover of a runner that was started
/// under one subreaper is still found when the thread is resumed from under another. An entry counts only while the
/// process with that pid still started when it did, so a reused pid is never taken for an adopter.
struct AdopterLedger {
    let file: URL

    static let capacity = 8

    static var standard: AdopterLedger { AdopterLedger(file: URL(fileURLWithPath: "/tmp/wb-adopters-\(getuid())")) }

    func recorded(on host: some ProcessInspecting) -> Set<pid_t> {
        Set(live(on: host).map(\.pid))
    }

    func record(_ member: ProcessMember, on host: some ProcessInspecting) {
        var kept = live(on: host).filter { $0 != member }
        kept.append(member)
        let text = kept.suffix(Self.capacity).map { "\($0.pid) \($0.startSeconds) \($0.startMicros)" }.joined(separator: "\n")
        // Best effort: a ledger that cannot be written only costs the recovery case it exists for.
        try? Data(text.utf8).write(to: file, options: .atomic)
    }

    private func live(on host: some ProcessInspecting) -> [ProcessMember] {
        // Someone else's file in a shared directory is not ours to believe.
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size < 4096, let text = try? String(contentsOf: file, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").prefix(Self.capacity).compactMap { line in
            let parts = line.split(separator: " ").compactMap { UInt64($0) }
            guard parts.count == 3, let pid = pid_t(exactly: parts[0]) else { return nil }
            let member = ProcessMember(pid: pid, startSeconds: parts[1], startMicros: parts[2])
            return host.member(for: pid) == member ? member : nil
        }
    }
}

/// PID 1, the adopter this process measured, and the ones earlier runs recorded. A failed measurement is not kept for
/// good: the next sweep after `retryAfter` seconds tries again, so one slow start does not blind the sweeper for the life
/// of the process.
final class AdopterCache: @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: AdopterLedger
    private let retryAfter: TimeInterval
    private let measure: @Sendable () -> ProcessMember?
    private var measured: ProcessMember?
    private var failedAt: Date?

    init(ledger: AdopterLedger, retryAfter: TimeInterval = 30, measure: @escaping @Sendable () -> ProcessMember?) {
        self.ledger = ledger
        self.retryAfter = retryAfter
        self.measure = measure
    }

    func adopters(on host: some ProcessInspecting) -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        // An adopter that has since exited hands its orphans to the next one up, which has to be found again.
        if let gone = measured, host.member(for: gone.pid) != gone, gone.pid > 1 { measured = nil }
        if measured == nil, failedAt.map({ Date().timeIntervalSince($0) >= retryAfter }) ?? true {
            if let found = measure() {
                measured = found
                if found.pid > 1 { ledger.record(found, on: host) }
            } else {
                failedAt = Date()
            }
        }
        var found: Set<pid_t> = [1]
        if let measured, host.member(for: measured.pid) == measured { found.insert(measured.pid) }
        return found.union(ledger.recorded(on: host))
    }
}
