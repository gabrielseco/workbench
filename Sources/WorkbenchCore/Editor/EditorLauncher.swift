import Foundation

/// Starts an editor's launcher and waits, bounded, for it to return.
///
/// Not `ProcessRunner`: that sweeps the child's process group and descendants when it exits, which would kill the
/// editor app a launcher such as `code` starts as its own child. The editor is meant to outlive `open`, so only a
/// launcher that does not return in time is stopped, with its group.
public enum EditorLauncher {
    public static let defaultTimeout: TimeInterval = 10
    static let tailBytes = 4096

    public static func launch(
        _ command: EditorCommand, editor: String, in directory: URL, environment: [String: String],
        timeout: TimeInterval = defaultTimeout, killGrace: TimeInterval = 1
    ) async throws {
        // Output goes to an unlinked file: no pipe the editor could fill or get SIGPIPE from after we stop reading.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-open-\(UUID().uuidString).log")
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let reason = "cannot create a scratch file: \(String(cString: strerror(errno)))"
            throw EditorError.launchFailed(editor: editor, reason: reason)
        }
        unlink(url.path)
        defer { close(fd) }

        let pid: pid_t
        do {
            pid = try Spawner.spawn(
                executable: command.executable, arguments: command.arguments, environment: environment,
                workingDirectory: directory.path, stdout: fd, stderr: fd)
        } catch {
            throw EditorError.launchFailed(editor: editor, reason: "\(error)")
        }
        let (termination, timedOut) = await LauncherWait(pid: pid).run(timeout: timeout, killGrace: killGrace)
        if timedOut { throw EditorError.timedOut(editor: editor, seconds: Int(timeout.rounded())) }
        switch termination {
        case .exited(0): return
        case .exited(let code): throw EditorError.failed(editor: editor, how: "exited \(code)", lastLine: lastLine(fd))
        case .signaled(let signal):
            throw EditorError.failed(editor: editor, how: "was killed by signal \(signal)", lastLine: lastLine(fd))
        case .lost: throw EditorError.failed(editor: editor, how: "ended with an unknown status", lastLine: lastLine(fd))
        }
    }

    /// The last non-empty line of what the launcher printed, cut to one printable line.
    static func lastLine(_ fd: Int32) -> String? {
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0 else { return nil }
        let start = max(0, Int(size) - tailBytes)
        var buffer = [UInt8](repeating: 0, count: Int(size) - start)
        let read = pread(fd, &buffer, buffer.count, off_t(start))
        guard read > 0 else { return nil }
        let text = String(decoding: buffer.prefix(read), as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) }) else {
            return nil
        }
        return ThreadState.safeLine(String(line), limit: 200)
    }
}

/// One launcher's exit or timeout, whichever comes first. All state is confined to `queue`.
private final class LauncherWait: @unchecked Sendable {
    private let pid: pid_t
    private let queue = DispatchQueue(label: "workbench.editor")
    private var watcher: ChildExitWatcher?
    private var timers: [DispatchSourceTimer] = []
    private var timedOut = false

    init(pid: pid_t) { self.pid = pid }

    func run(timeout: TimeInterval, killGrace: TimeInterval) async -> (Termination, Bool) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Termination, Bool), Never>) in
            queue.async { [self] in
                watcher = ChildExitWatcher(pid: pid, queue: queue) { [self] in
                    timers.forEach { $0.cancel() }
                    // Still a zombie, so its group id is ours alone: whatever a stopped launcher started goes too.
                    if timedOut { killpg(pid, SIGKILL) }
                    let termination = watcher?.reap() ?? .lost
                    watcher = nil
                    continuation.resume(returning: (termination, timedOut))
                }
                after(timeout) { [self] in
                    timedOut = true
                    killpg(pid, SIGTERM)
                    kill(pid, SIGTERM)
                    after(killGrace) { [self] in
                        killpg(pid, SIGKILL)
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
    }

    private func after(_ delay: TimeInterval, _ handler: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }
}
