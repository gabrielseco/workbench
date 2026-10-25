import Foundation

/// A pipe watch that does not use a Dispatch read source: a thread of its own waits in `poll`, and each time the pipe has data
/// or has hung up, asks the engine's queue to run the callback and waits for it to finish. Level-triggered like a read
/// source: it asks again while the pipe is still readable.
///
/// Why it exists: libdispatch on Linux crashes when a read source is cancelled as an event for it arrives (see
/// `PipeReading`). Nothing here touches libdispatch's event loop, only a queue and a semaphore.
///
/// `cancel()` wakes the thread through a second pipe, so it never waits out a timeout. The wake pipe's write end belongs to
/// `cancel()` (or to the thread, if it ends on its own first) and is closed under the lock, so nothing can write to it after
/// it is closed or reused: an earlier version set the flag first and wrote afterwards, and under load the thread left and
/// closed the pipe in between (a SIGPIPE, or a byte into someone else's descriptor). The thread closes the watched
/// descriptor and the read end when it ends: nothing is polling them by then.
final class ThreadPipeReader: PipeReader, @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let onReadable: @Sendable () -> Void
    private let wakeRead: Int32
    private let lock = NSLock()
    private var wakeWrite: Int32
    private var cancelled = false

    init(fd: Int32, queue: DispatchQueue, onReadable: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.queue = queue
        self.onReadable = onReadable
        var wake: [Int32] = [-1, -1]
        if pipe(&wake) != 0 { wake = [-1, -1] }
        for end in wake where end >= 0 { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        wakeRead = wake[0]
        wakeWrite = wake[1]
        let thread = Thread { [self] in run() }
        thread.name = "workbench.pipe-reader"
        thread.start()
    }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            if wakeWrite >= 0 {
                var byte: UInt8 = 1
                _ = write(wakeWrite, &byte, 1)
                close(wakeWrite)
                wakeWrite = -1
            }
        }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func run() {
        defer {
            close(fd)
            if wakeRead >= 0 { close(wakeRead) }
            // Ending on its own: a later cancel() must find nothing to write to.
            lock.withLock {
                cancelled = true
                if wakeWrite >= 0 {
                    close(wakeWrite)
                    wakeWrite = -1
                }
            }
        }
        while !isCancelled {
            var watched = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&watched, 2, wakeRead >= 0 ? -1 : 50)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if isCancelled { return }
            if watched[0].revents != 0 {
                let finished = DispatchSemaphore(value: 0)
                queue.async { [self] in
                    if !isCancelled { onReadable() }
                    finished.signal()
                }
                finished.wait()
            }
        }
    }
}
