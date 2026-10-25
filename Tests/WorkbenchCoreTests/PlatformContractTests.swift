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
        // `test -e /dev/fd/N`, not a redirect: dash (Linux's /bin/sh) accepts only a one-digit descriptor after `>&`.
        let script = """
            read line; echo "stdin:[$line]"; echo to-stderr >&2
            if [ -e /dev/fd/\(spare) ]; then echo leaked; else echo cannot-write; fi
            ls /dev/fd
            """
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

    @Test func aProcessWhoseParentDiedIsAdoptedByOneOfTheAdoptersThePlatformNames() async throws {
        let dir = try Scratch.directory("contract")
        let pidFile = Scratch.url("contract-orphan")
        let (shell, _) = try spawn("sleep 300 & echo $! > '\(pidFile.path)'", in: dir)
        _ = await wait { waitpidNoHang(shell) }
        let text = try #require(try? String(contentsOf: pidFile, encoding: .utf8))
        let orphan = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(orphan, SIGKILL) }
        #expect(await wait { platform.parent(of: orphan).map { $0 != shell } ?? false }, "it is re-parented")
        let parent = try #require(platform.parent(of: orphan))
        #expect(platform.orphanAdopters.contains(parent), "adopted by \(parent); the adopters are \(platform.orphanAdopters)")
    }

    @Test(arguments: WatchKind.allCases)
    func aPipeWatchReportsDataThenTheHangUpAndAnExtraCancelIsHarmless(kind: WatchKind) async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        let seen = WatchSeen()
        let reader = fds[0]
        let watch = kind.watch(fd: reader, queue: DispatchQueue(label: "contract.pipe")) {
            var buffer = [UInt8](repeating: 0, count: 64)
            while true {
                let n = read(reader, &buffer, buffer.count)
                if n > 0 {
                    seen.add(Array(buffer[0..<n]))
                } else {
                    if n == 0 { seen.markHangUp() }
                    break
                }
            }
        }
        _ = write(fds[1], "hello", 5)
        #expect(await eventually { seen.text == "hello" }, "the data is reported")
        _ = write(fds[1], " world", 6)
        #expect(await eventually { seen.text == "hello world" }, "and more of it, as it comes")
        close(fds[1])
        #expect(await eventually { seen.hungUp }, "the hang-up is reported (a read returns 0)")
        watch.cancel()
        watch.cancel()
    }

    @Test(arguments: WatchKind.allCases)
    func cancellingAPipeWatchClosesItsDescriptorAndStopsTheCallbacks(kind: WatchKind) async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        defer { close(fds[1]) }
        let seen = WatchSeen()
        let watch = kind.watch(fd: fds[0], queue: DispatchQueue(label: "contract.pipe.cancel")) { seen.count() }
        watch.cancel()
        // With the read end closed, the write end reports an error condition (nothing is written to it: that would raise SIGPIPE).
        let writer = fds[1]
        #expect(await eventually { Self.hasError(writer) }, "the read end was closed")
        let calls = seen.calls
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(seen.calls == calls, "no callback after the cancel")
    }

    @Test(arguments: WatchKind.allCases)
    func aPipeWatchMayBeCancelledFromInsideItsOwnCallback(kind: WatchKind) async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        defer { close(fds[1]) }
        let seen = WatchSeen()
        let holder = WatchHolder()
        let reader = fds[0]
        holder.watch = kind.watch(fd: reader, queue: DispatchQueue(label: "contract.pipe.inside")) {
            var byte: UInt8 = 0
            if read(reader, &byte, 1) > 0 {
                seen.count()
                holder.watch?.cancel()
            }
        }
        _ = write(fds[1], "x", 1)
        #expect(await eventually { seen.calls == 1 })
        let writer = fds[1]
        #expect(await eventually { Self.hasError(writer) }, "closed after it cancelled itself")
    }

    @Test(arguments: WatchKind.allCases)
    func manyPipeWatchesStartedWrittenToHungUpAndCancelledAtOnceDoNotBringTheProcessDown(kind: WatchKind) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    for _ in 0..<100 {
                        var fds: [Int32] = [0, 0]
                        guard pipe(&fds) == 0 else { return }
                        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
                        let reader = fds[0]
                        let watch = kind.watch(fd: reader, queue: DispatchQueue(label: "contract.pipe.many")) {
                            var byte: UInt8 = 0
                            _ = read(reader, &byte, 1)
                        }
                        _ = write(fds[1], "x", 1)
                        try? await Task.sleep(nanoseconds: UInt64.random(in: 0...2_000_000))
                        close(fds[1])
                        watch.cancel()
                    }
                }
            }
        }
    }

    private static func hasError(_ fd: Int32) -> Bool {
        // A write end whose last read end is gone reports an error (Linux: POLLERR, macOS: POLLHUP or POLLERR).
        var probe = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&probe, 1, 0) > 0 && probe.revents & Int16(POLLERR | POLLHUP) != 0
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

/// Both ways of watching a pipe run through the same checks: the platform's own, and the thread reader Linux uses (which has no
/// OS-specific code, so macOS can hold it to the same behavior).
enum WatchKind: CaseIterable, CustomTestStringConvertible, Sendable {
    case platform
    case thread

    var testDescription: String { self == .platform ? "platform watch" : "thread reader" }

    func watch(fd: Int32, queue: DispatchQueue, onReadable: @escaping @Sendable () -> Void) -> any PipeReader {
        switch self {
        case .platform: WorkbenchCore.platform.watch(fd: fd, queue: queue, onReadable: onReadable)
        case .thread: ThreadPipeReader(fd: fd, queue: queue, onReadable: onReadable)
        }
    }
}

private final class WatchHolder: @unchecked Sendable {
    var watch: (any PipeReader)?
}

/// What a pipe watch's callback saw, safe to read from the test.
private final class WatchSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var eof = false
    private var n = 0
    func add(_ more: [UInt8]) { lock.withLock { bytes += more } }
    func markHangUp() { lock.withLock { eof = true } }
    func count() { lock.withLock { n += 1 } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var hungUp: Bool { lock.withLock { eof } }
    var calls: Int { lock.withLock { n } }
}

/// Polls `condition` for up to five seconds.
private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
