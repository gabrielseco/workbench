import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// The ready check of `[run] ready_url` (docs/plan/P16-run.md), on plain BSD sockets so it is the same code on macOS and
/// Linux. The URL may only name this machine (`localhost`, `127.0.0.1`, `::1`; Config checks it), so no name is ever
/// resolved: a resolver that stalls cannot hold the check, and every wait below is a poll bounded by the one deadline.
enum LoopbackProbe {
    /// Any HTTP answer, whatever its status, means something is listening and serving. It is the status line that counts,
    /// read from a plain TCP connection: nothing follows a redirect (the check stays on this machine, and a 3xx is an
    /// answer already), the body is never read (a server that streams one cannot hold the check or grow our memory), and
    /// the whole attempt ends within `attempt` seconds, or at once when the calling task is cancelled.
    static func answers(_ url: String, attempt: TimeInterval = 1.5) async -> Bool {
        guard let url = URL(string: url), let host = url.host, let number = url.port, (1...65_535).contains(number)
        else { return false }
        let target = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?" + $0 } ?? "")
        let request = "GET \(target) HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        let deadline = Date().addingTimeInterval(attempt)
        let stop = Stop()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let found = addresses(for: host, port: UInt16(number)).contains {
                        exchange(address: $0, request: request, deadline: deadline, stop: stop)
                    }
                    continuation.resume(returning: found)
                }
            }
        } onCancel: {
            stop.set()
        }
    }

    private final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
        func set() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    /// The addresses a loopback host name stands for, from literals: `localhost` is both families. Anything else is none.
    static func addresses(for host: String, port: UInt16) -> [sockaddr_storage] {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let names: [(family: Int32, text: String)]
        switch bare {
        case "localhost": names = [(AF_INET, "127.0.0.1"), (AF_INET6, "::1")]
        case "127.0.0.1": names = [(AF_INET, bare)]
        case "::1": names = [(AF_INET6, bare)]
        default: return []
        }
        return names.compactMap { family, text -> sockaddr_storage? in
            if family == AF_INET {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                guard inet_pton(AF_INET, text, &address.sin_addr) == 1 else { return nil }
                return storage(of: &address)
            } else {
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                guard inet_pton(AF_INET6, text, &address.sin6_addr) == 1 else { return nil }
                return storage(of: &address)
            }
        }
    }

    /// An address struct copied into the one type that holds either family.
    private static func storage<T>(of address: inout T) -> sockaddr_storage {
        var storage = sockaddr_storage()
        withUnsafeBytes(of: &address) { source in
            withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: source) }
        }
        return storage
    }

    private static func exchange(address: sockaddr_storage, request: String, deadline: Date, stop: Stop) -> Bool {
        var address = address
        let fd = socket(Int32(address.ss_family), streamSocketType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        suppressSigpipe(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let isIPv4 = address.ss_family == sa_family_t(AF_INET)
        let length = socklen_t(isIPv4 ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS, ready(fd, Int16(POLLOUT), deadline, stop) else { return false }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else { return false }
        }

        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            guard ready(fd, Int16(POLLOUT), deadline, stop) else { return false }
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, sendFlags) }
            if n > 0 { sent += n } else if errno != EAGAIN && errno != EINTR { return false }
        }

        var head = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16)
        while head.count < 5 {
            guard ready(fd, Int16(POLLIN), deadline, stop) else { return false }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { head += buffer[0..<n] } else if n == 0 || (errno != EAGAIN && errno != EINTR) { break }
        }
        return String(decoding: head, as: UTF8.self).hasPrefix("HTTP/")
    }

    /// Waits for `events` on `fd` until `deadline`, in slices so a cancel is noticed. An error or hang-up counts as ready:
    /// the next call reports it.
    private static func ready(_ fd: Int32, _ events: Int16, _ deadline: Date, _ stop: Stop) -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while !stop.isSet {
            let remaining = Int32(min(50, max(0, deadline.timeIntervalSinceNow * 1000)))
            let n = poll(&descriptor, 1, remaining)
            if n > 0 { return true }
            if n < 0 && errno != EINTR { return false }
            if deadline.timeIntervalSinceNow <= 0 { return false }
        }
        return false
    }
}
