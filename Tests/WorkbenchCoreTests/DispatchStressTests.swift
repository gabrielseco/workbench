import Foundation
import Testing

@testable import WorkbenchCore

/// Hammers one process or Dispatch mechanism at a time with 48 concurrent loops, for as long as `WORKBENCH_STRESS_SECONDS`
/// says (default 180), and prints how many iterations it got through. Off unless `WORKBENCH_STRESS=<mode>` is set:
/// `runner` (ProcessRunner), `pipe` (the platform's pipe watch), `reads-raw` (a bare Dispatch read source: crashes libdispatch
/// on Linux, which is why the platform has its own), `timers`, `exitwatch`. It found that bug (docs/plan/P18-linux.md).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private let stressMode = ProcessInfo.processInfo.environment["WORKBENCH_STRESS"]

@Suite(.enabled(if: stressMode != nil)) struct DispatchStressTests {
    @Test func hammer() async throws {
        let mode = stressMode ?? ""
        let seconds = Double(ProcessInfo.processInfo.environment["WORKBENCH_STRESS_SECONDS"] ?? "180") ?? 180
        let deadline = Date().addingTimeInterval(seconds)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<48 {
                group.addTask {
                    while Date() < deadline {
                        await one(mode)
                        counter.add()
                    }
                }
            }
        }
        print("STRESS_DONE mode \(mode) iterations \(counter.value)")
    }
}

private func one(_ mode: String) async {
    switch mode {
    case "runner":
        let spawn = SpawnRequest(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: URL(fileURLWithPath: "/tmp"), timeout: 10)
        guard let run = try? ProcessRunner.start(spawn) else { return }
        for await _ in run.events {}
    case "timers":
        let queue = DispatchQueue(label: "stress.timers")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int.random(in: 1...20)), repeating: .never)
        timer.setEventHandler {}
        timer.resume()
        try? await Task.sleep(nanoseconds: UInt64.random(in: 0...15_000_000))
        timer.cancel()
    case "reads-raw":
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        let queue = DispatchQueue(label: "stress.reads")
        let source = DispatchSource.makeReadSource(fileDescriptor: fds[0], queue: queue)
        let reader = fds[0]
        source.setEventHandler {
            var byte: UInt8 = 0
            _ = read(reader, &byte, 1)
        }
        source.setCancelHandler { close(reader) }
        source.resume()
        _ = write(fds[1], "x", 1)
        try? await Task.sleep(nanoseconds: UInt64.random(in: 0...10_000_000))
        close(fds[1])
        source.cancel()
    case "pipe":
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
        let reader = fds[0]
        let watch = platform.watch(fd: reader, queue: DispatchQueue(label: "stress.pipe")) {
            var byte: UInt8 = 0
            _ = read(reader, &byte, 1)
        }
        _ = write(fds[1], "x", 1)
        try? await Task.sleep(nanoseconds: UInt64.random(in: 0...10_000_000))
        close(fds[1])
        if Bool.random() { try? await Task.sleep(nanoseconds: UInt64.random(in: 0...3_000_000)) }
        watch.cancel()
    case "exitwatch":
        let sink = open("/dev/null", O_WRONLY | O_CLOEXEC)
        defer { close(sink) }
        guard let pid = try? Spawner.spawn(
            executable: "/bin/true", arguments: [], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: "/tmp",
            stdout: sink, stderr: sink)
        else { return }
        let queue = DispatchQueue(label: "stress.exit")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let watcher = ChildExitWatcher(pid: pid, queue: queue) { done.resume() }
            queue.asyncAfter(deadline: .now() + 5) { watcher.cancel() }
        }
        var status: Int32 = 0
        _ = waitpid(pid, &status, WNOHANG)
    default:
        break
    }
}
