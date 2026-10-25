#if !canImport(Darwin)
import CShim
import Foundation
import Glibc

/// Linux: `/proc` for the process table, no exit event (the poll alone), and everything above descriptor 2 closed in
/// the child by a file action, since there is no `CLOEXEC_DEFAULT`.
struct LinuxPlatform: ProcessInspecting, SpawnPlatform, ExitNotifying, Subreaping, PipeReading {
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

    var orphanAdopters: Set<pid_t> { Self.adopters.adopters(on: self) }

    private static let adopters = AdopterCache(ledger: .standard) { AdopterProbe.measure(on: LinuxPlatform()).adopter }

    func watch(fd: Int32, queue: DispatchQueue, onReadable: @escaping @Sendable () -> Void) -> any PipeReader {
        ThreadPipeReader(fd: fd, queue: queue, onReadable: onReadable)
    }
}
#endif
