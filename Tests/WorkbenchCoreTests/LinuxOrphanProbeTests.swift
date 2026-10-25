import Foundation
import Testing

@testable import WorkbenchCore

/// Throwaway: does an orphan made with Foundation's Process survive on Linux, and how does it differ from one made with our Spawner?
@Suite struct LinuxOrphanProbeTests {
    private func timeline(of pid: pid_t, for seconds: Double) async -> String {
        var rows: [String] = []
        let start = Date()
        var last = ""
        while Date().timeIntervalSince(start) < seconds {
            let status = (try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8))?
                .split(separator: "\n").filter { $0.hasPrefix("State:") || $0.hasPrefix("PPid:") }
                .joined(separator: " ") ?? "gone"
            if status != last {
                rows.append(String(format: "%.0fms %@", Date().timeIntervalSince(start) * 1000, status))
                last = status
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return rows.joined(separator: " | ")
    }

    @Test func foundationProcessOrphan() async throws {
        let dir = try Scratch.directory("probe")
        let file = dir.appendingPathComponent("pid")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 60 & echo $! > '\(file.path)'"]
        shell.currentDirectoryURL = dir
        try shell.run()
        shell.waitUntilExit()
        let pid = try #require(pid_t(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let story = await timeline(of: pid, for: 1.0)
        kill(pid, SIGKILL)
        Issue.record("PROBE foundation-process shell=\(shell.processIdentifier) orphan=\(pid): \(story)")
    }

    @Test func spawnerOrphan() async throws {
        let dir = try Scratch.directory("probe")
        let file = dir.appendingPathComponent("pid")
        let sink = open("/dev/null", O_WRONLY | O_CLOEXEC)
        defer { close(sink) }
        let shell = try Spawner.spawn(
            executable: "/bin/sh", arguments: ["-c", "sleep 60 & echo $! > '\(file.path)'"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: dir.path, stdout: sink, stderr: sink)
        var status: Int32 = 0
        for _ in 0..<400 where waitpid(shell, &status, WNOHANG) == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        let pid = try #require(pid_t(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let story = await timeline(of: pid, for: 1.0)
        kill(pid, SIGKILL)
        Issue.record("PROBE spawner shell=\(shell) orphan=\(pid): \(story)")
    }
}
