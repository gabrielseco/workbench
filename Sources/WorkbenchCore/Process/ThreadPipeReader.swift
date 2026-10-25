import Foundation

/// A pipe watch that does not use a Dispatch read source: a thread of its own waits in `poll`, and each time the pipe has data
/// or has hung up, asks the engine's queue to run the callback and waits for it to finish. Level-triggered like a read
/// source: it asks again while the pipe is still readable.
///
/// Why it exists: libdispatch on Linux crashes when a read source is cancelled as an event for it arrives (see
/// `PipeReading`). Nothing here touches libdispatch's event loop, only a queue and a semaphore.
///
/// `cancel()` wakes the thread through a second pipe, so it never waits out a timeout, and the thread closes the descriptor
/// itself when it ends: nothing is polling it by then.
final class ThreadPipeReader: PipeReader, @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let onReadable: @Sendable () -> Void
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()
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
        let first = lock.withLock { () -> Bool in
            defer { cancelled = true }
            return !cancelled
        }
        guard first, wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func run() {
        defer {
            close(fd)
            if wakeRead >= 0 { close(wakeRead) }
            if wakeWrite >= 0 { close(wakeWrite) }
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
