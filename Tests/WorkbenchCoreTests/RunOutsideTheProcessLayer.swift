import Foundation

@testable import WorkbenchCore

/// Starts a program with the spawner and waits for it to end, without `ProcessRunner`: its sweep of a child's descendants
/// would otherwise kill the leftover a test is making. Used to leave an orphan behind. Not Foundation's `Process`: on
/// Linux the background child of a shell it ran is gone the moment the shell ends, so no orphan survives to be found.
func runOutsideTheProcessLayer(
    _ executable: String, _ arguments: [String], in directory: URL, environment: [String: String] = ["PATH": "/usr/bin:/bin"]
) async throws {
    let sink = open("/dev/null", O_WRONLY | O_CLOEXEC)
    defer { if sink >= 0 { close(sink) } }
    let pid = try Spawner.spawn(
        executable: executable, arguments: arguments, environment: environment, workingDirectory: directory.path,
        stdout: sink, stderr: sink)
    var status: Int32 = 0
    for _ in 0..<2_000 {
        if waitpid(pid, &status, WNOHANG) != 0 { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
