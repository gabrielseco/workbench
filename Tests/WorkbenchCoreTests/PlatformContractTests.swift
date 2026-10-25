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

    @Test func theStartIsReadFromTheKernelNotInventedSoALaterProcessStartsLater() async throws {
        let dir = try Scratch.directory("contract")
        let (first, _) = try spawn("sleep 300", in: dir)
        defer { end(first) }
        let earlier = try #require(platform.member(for: first))
        try await Task.sleep(nanoseconds: 150_000_000)
        let (second, _) = try spawn("sleep 300", in: dir)
        defer { end(second) }
        let later = try #require(platform.member(for: second))
        #expect(earlier.startSeconds > 0, "a start is reported")
        #expect(platform.member(for: first) == earlier, "a process keeps its start while it runs")
        #expect(
            (later.startSeconds, later.startMicros) > (earlier.startSeconds, earlier.startMicros),
            "a process that began 150 ms later has a later start: \(earlier) \(later)")
    }

    @Test func theWorkingDirectoryIsTheRealPathTheChildWasStartedIn() async throws {
        let dir = try Scratch.directory("contract")
        let (pid, _) = try spawn("sleep 300", in: dir)
        defer { end(pid) }
        #expect(platform.workingDirectory(of: pid) == OrphanSweeper.realPath(dir))
    }

    @Test func aDescendantTwoLevelsDownIsFoundWhateverItsDirectoryOrGroup() async throws {
        let dir = try Scratch.directory("contract")
        // shell -> shell (own job, so its own process group, in another directory) -> sleep
        let (pid, _) = try spawn("set -m; (cd /; sh -c 'exec sleep 300' & wait) & wait", in: dir)
        defer { end(pid) }
        func deep() -> [ProcessMember] { ProcessTree.descendants(of: pid).filter { platform.parent(of: $0.pid) != pid } }
        #expect(await wait { !deep().isEmpty }, "a descendant that is not a direct child is found")
        let direct = platform.children(of: pid)
        #expect(!direct.isEmpty && direct.allSatisfy { platform.parent(of: $0) == pid }, "children are direct children only")
        #expect(platform.allPIDs().contains(direct[0]))
    }

    @Test func aChildHoldsStdinStdoutAndStderrAndNoDescriptorOfOurs() async throws {
        let dir = try Scratch.directory("contract")
        let leaked = Scratch.url("contract-leak")
        let fd = open(leaked.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        defer { close(fd) }
        // A spare descriptor above anything another test is likely to hold, open here without close-on-exec.
        let spare = fcntl(fd, F_DUPFD, 100)
        #expect(spare >= 100)
        defer { close(spare) }
        let script =
            "read line; echo \"stdin:[$line]\"; echo to-stderr >&2; echo leaked >&\(spare) || echo cannot-write; ls /dev/fd"
        let (pid, output) = try spawn(script, in: dir)
        let exited = await wait { waitpidNoHang(pid) }
        #expect(exited)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("stdin:[]"), "stdin is /dev/null: \(text)")
        #expect(text.contains("to-stderr"), "stderr is the file we gave: \(text)")
        #expect(text.contains("cannot-write"), "our spare descriptor did not reach the child: \(text)")
        #expect(try String(contentsOf: leaked, encoding: .utf8).isEmpty)
        // What the child lists in /dev/fd: 0, 1, 2 and the few handles `ls` opens for itself, nothing like ours (the spare
        // is 100 or more, and the descriptors we hold above the standard three are all well past `ls`'s own).
        let listed = Set(text.split(separator: "\n").compactMap { Int($0) })
        #expect(listed.isSuperset(of: [0, 1, 2]) && listed.allSatisfy { $0 < 10 }, "descriptors in the child: \(listed.sorted())")
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
        #if canImport(Darwin)
        #expect(watch != nil, "macOS has the kqueue event")
        #endif
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
