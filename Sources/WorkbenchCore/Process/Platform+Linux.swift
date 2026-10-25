#if !canImport(Darwin)
import CShim
import Foundation
import Glibc

/// Linux: `/proc` for the process table, no exit event (the poll alone), and everything above descriptor 2 closed in
/// the child by a file action, since there is no `CLOEXEC_DEFAULT`.
struct LinuxPlatform: ProcessInspecting, SpawnPlatform, ExitNotifying, Subreaping {
    private func fields(_ pid: pid_t) -> [Substring]? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return nil }
        return ProcStat.fields(text)
    }

    func member(for pid: pid_t) -> ProcessMember? {
        guard let fields = fields(pid), let ticks = ProcStat.startTicks(fields) else { return nil }
        return ProcessMember(pid: pid, startSeconds: ticks, startMicros: 0)
    }

    func parent(of pid: pid_t) -> pid_t? { fields(pid).flatMap(ProcStat.parent) }

    func workingDirectory(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard readlink("/proc/\(pid)/cwd", &buffer, buffer.count - 1) > 0 else { return nil }
        return String(cString: buffer)
    }

    func allPIDs() -> [pid_t] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return entries.compactMap { pid_t($0) }
    }

    func children(of parent: pid_t) -> [pid_t] {
        allPIDs().filter { self.parent(of: $0) == parent }
    }

    var descriptorFlags: Int32 { 0 }

    func addDescriptorHygiene(to actions: inout SpawnFileActions) -> Int32 {
        // After the dup2s: everything from 3 up is closed in the child.
        posix_spawn_file_actions_addclosefrom_np(&actions, 3)
    }

    func watchExit(of pid: pid_t, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) -> ExitWatch? { nil }

    func becomeSubreaper() -> Bool { wb_become_subreaper() == 0 }

    var orphanAdopters: Set<pid_t> { Self.measuredAdopters }

    /// PID 1, and whoever adopts a process we orphan on purpose: a shell starts a `sleep` and exits at once, and the
    /// `sleep`'s new parent is read. Measured once per process (about 30 ms) because only the kernel knows which ancestor is
    /// a subreaper, and under a container's init, a supervisor or `systemd --user` it is not always PID 1.
    private static let measuredAdopters: Set<pid_t> = {
        var adopters: Set<pid_t> = [1]
        let name = FileManager.default.temporaryDirectory.appendingPathComponent("wb-adopter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: name) }
        let sink = open("/dev/null", O_WRONLY | O_CLOEXEC)
        defer { if sink >= 0 { close(sink) } }
        guard sink >= 0,
            let shell = try? Spawner.spawn(
                executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $! > '\(name.path)'"],
                environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/", stdout: sink, stderr: sink)
        else { return adopters }
        var status: Int32 = 0
        var waited = 0
        // Polled, never a blocking wait (docs/plan/P1-runner.md): the shell ends within milliseconds.
        while waitpid(shell, &status, WNOHANG) == 0, waited < 200 {
            usleep(10_000)
            waited += 1
        }
        let text = (try? String(contentsOf: name, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, let sleeper = pid_t(text) else { return adopters }
        let platform = LinuxPlatform()
        for _ in 0..<100 {
            if let parent = platform.parent(of: sleeper), parent != shell {
                adopters.insert(parent)
                break
            }
            usleep(10_000)
        }
        kill(sleeper, SIGKILL)
        return adopters
    }()
}
#endif
