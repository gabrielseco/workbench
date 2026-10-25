import Foundation
import Testing

@testable import WorkbenchCore

/// What every platform implementation must do. The same checks run on whichever one is in use (macOS now, Linux when it
/// is added), so a new platform is correct when this suite passes on it.
private func spawn(
    _ script: String, in directory: URL
) throws -> (pid: pid_t, output: URL) {
    let output = Scratch.url("contract-out")
    let out = open(output.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    defer { close(out) }
    let pid = try Spawner.spawn(
        executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
        workingDirectory: directory.path, stdout: out, stderr: out)
    return (pid, output)
}

private func end(_ pid: pid_t) {
    for member in ProcessTree.descendants(of: pid) { kill(member.pid, SIGKILL) }
    kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
}

private func wait(_ timeout: TimeInterval = Patience.limit, until condition: () -> Bool) async -> Bool {
    await pollUntil(timeout: timeout, condition)
}

@Suite(.processGate) struct PlatformContractTests {
    @Test func aProcessIsIdentifiedByItsPidAndStartAndAMissingOneIsNil() throws {
        let me = try #require(platform.member(for: getpid()))
        #expect(me.pid == getpid() && me == platform.member(for: getpid()), "the same process reads the same twice")
        #expect(platform.member(for: 2_000_000_000) == nil)
        #expect(platform.parent(of: getpid()) == getppid())
        #expect(platform.allPIDs().contains(getpid()))
    }

    @Test func aChildHasItsOwnIdentityAndIsOnlyAliveWithTheStartItWasSeenWith() async throws {
        let dir = try Scratch.directory("contract")
        let (pid, _) = try spawn("sleep 300", in: dir)
        defer { end(pid) }
        let child = try #require(platform.member(for: pid))
        #expect(child != platform.member(for: getpid()))
        #expect(platform.parent(of: pid) == getpid())
        #expect(ProcessTree.isAlive(child))
        var recycled = child
        recycled.startSeconds += 5
        #expect(!ProcessTree.isAlive(recycled), "the same pid with another start is another process")
    }

    @Test func theWorkingDirectoryIsTheRealPathTheChildWasStartedIn() async throws {
        let dir = try Scratch.directory("contract")
        let (pid, _) = try spawn("sleep 300", in: dir)
        defer { end(pid) }
        #expect(platform.workingDirectory(of: pid) == OrphanSweeper.realPath(dir))
    }

    @Test func aGrandchildIsFoundBelowItsParentWhateverItsDirectoryOrGroup() async throws {
        let dir = try Scratch.directory("contract")
        let (pid, _) = try spawn("sh -c 'cd /; exec sleep 300' & wait", in: dir)
        defer { end(pid) }
        #expect(await wait { !platform.children(of: pid).isEmpty }, "the shell's child is listed")
        let child = try #require(platform.children(of: pid).first)
        #expect(platform.allPIDs().contains(child))
        #expect(await wait { ProcessTree.descendants(of: pid).contains { platform.parent(of: $0.pid) != nil } })
        #expect(ProcessTree.descendants(of: pid).map(\.pid).contains(child))
    }

    @Test func aChildHoldsStdinStdoutAndStderrAndNoDescriptorOfOurs() async throws {
        let dir = try Scratch.directory("contract")
        let leaked = Scratch.url("contract-leak")
        let fd = open(leaked.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        defer { close(fd) }
        // Descriptor 7 is open here without close-on-exec; the child must not have it.
        #expect(dup2(fd, 7) == 7)
        defer { close(7) }
        let (pid, output) = try spawn("echo to-stdout; echo to-seven >&7", in: dir)
        let exited = await wait { kill(pid, 0) != 0 || waitpidNoHang(pid) }
        #expect(exited)
        #expect(try String(contentsOf: output, encoding: .utf8).contains("to-stdout"), "stdout is the file we gave")
        #expect(try String(contentsOf: leaked, encoding: .utf8).isEmpty, "descriptor 7 did not reach the child")
    }

    @Test func anExitIsReportedPromptlyWhereThePlatformHasAnEventAndNeverWrongly() async throws {
        let dir = try Scratch.directory("contract")
        let (pid, _) = try spawn("sleep 300", in: dir)
        let heard = Heard()
        let watch = platform.watchExit(of: pid, queue: DispatchQueue(label: "contract.exit")) { heard.set() }
        defer { watch?.cancel(); end(pid) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!heard.value, "a running child is not reported as exited")
        kill(pid, SIGKILL)
        if watch != nil { #expect(await wait { heard.value }, "the platform's event arrives") }
    }

    @Test func onlyAPlatformThatHasSubreapersSaysItBecameOne() {
        #if canImport(Darwin)
        #expect(!platform.becomeSubreaper(), "macOS has no subreapers")
        #endif
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// True when `pid` has ended and was reaped here; false while it runs.
private func waitpidNoHang(_ pid: pid_t) -> Bool {
    var status: Int32 = 0
    return waitpid(pid, &status, WNOHANG) == pid
}
