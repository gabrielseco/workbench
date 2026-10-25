import Foundation
import Testing

@testable import WorkbenchCore

#if os(Linux)
    /// Linux refuses to exec a file that is open for writing (ETXTBSY); macOS does not, so only Linux can show it.
    @Suite(.processGate) struct SpawnerBusyTests {
        private func busyScript() throws -> (path: String, writer: Int32) {
            let path = Scratch.url("busy").appendingPathExtension("sh").path
            try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
            let writer = open(path, O_WRONLY | O_CLOEXEC)
            try #require(writer >= 0)
            return (path, writer)
        }

        private func spawn(_ path: String) throws -> pid_t {
            let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
            defer { close(null) }
            return try Spawner.spawn(
                executable: path, arguments: [], environment: [:], workingDirectory: "/", stdout: null, stderr: null)
        }

        @Test func aScriptThatStopsBeingWrittenWithinTheRetriesIsLaunched() throws {
            let (path, writer) = try busyScript()
            Thread.detachNewThread {
                usleep(50_000)
                close(writer)
            }
            let pid = try spawn(path)
            var status: Int32 = 0
            #expect(waitpid(pid, &status, 0) == pid)
            #expect(Termination(waitStatus: status) == .exited(0))
        }

        @Test func aScriptThatStaysOpenForWritingIsReportedAfterTheRetriesRunOut() throws {
            let (path, writer) = try busyScript()
            defer { close(writer) }
            #expect(throws: SpawnError.self) { try spawn(path) }
        }
    }
#endif
