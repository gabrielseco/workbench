import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The few BSD socket calls `LoopbackForwarder` needs, with the platform differences in one place. Every wait is a `poll` in slices
/// no longer than `slice` seconds so a stop is noticed, and nothing here blocks without a timeout.
enum ForwarderSocket {
    static let slice: Int32 = 200

    #if os(Linux)
        private static let sendFlags = Int32(MSG_NOSIGNAL)
    #else
        private static let sendFlags: Int32 = 0
    #endif

    /// No SIGPIPE when the peer is gone (an error from `send` instead), and a bound on how long a write may wait for a slow reader.
    static func configure(_ fd: Int32, timeout: TimeInterval) {
        #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Up to 64 KiB, or nil when the peer closed, the deadline passed, `stopped` became true or the read failed.
    static func receive(_ fd: Int32, deadline: Date, stopped: () -> Bool) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if stopped() || Date() >= deadline { return nil }
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, slice)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard ready > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 { return Data(buffer[..<count]) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            return nil
        }
    }

    /// All of `data`, or false when the peer is gone or too slow.
    @discardableResult
    static func deliver(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let start = raw.baseAddress else { return true }
            while offset < raw.count {
                let sent = send(fd, start + offset, raw.count - offset, sendFlags)
                if sent > 0 {
                    offset += sent
                } else if sent < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// The peer closed its end (or the connection broke): nothing more will be read and nothing written will be seen.
    static func hasHungUp(_ fd: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, 0) > 0 else { return false }
        if entry.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT)) == 0
    }

    /// A complete answer with a JSON body, and the end of the connection.
    static func respond(_ fd: Int32, status: Int, body: Data) {
        var head = "HTTP/1.1 \(status) \(ForwardPolicy.reason(status))\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        deliver(fd, Data(head.utf8) + body)
    }
}
