#if !canImport(Network)
import Foundation
import Glibc

// The readiness check on plain BSD sockets, for platforms without Network.framework (Linux). macOS keeps its NWConnection
// until P18 task 5 replaces both with one probe. `[run] ready_url` may only name this machine (`localhost`, `127.0.0.1`,
// `::1`; Config checks it), so no name is ever resolved: a resolver that stalls cannot hold the check, and every wait below
// is a poll bounded by the one deadline.
extension AppLauncher {
    /// Any HTTP answer, whatever its status, means something is listening and serving: the status line from a plain TCP
    /// connection, nothing followed, no body read, and the whole attempt ends within `attempt` seconds.
    static func answers(_ url: String, attempt: TimeInterval = 1.5) async -> Bool {
        guard let url = URL(string: url), let host = url.host, let number = url.port, (1...65_535).contains(number)
        else { return false }
        let target = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?" + $0 } ?? "")
        let request = "GET \(target) HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        let deadline = Date().addingTimeInterval(attempt)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let found = loopbackAddresses(for: host, port: UInt16(number)).contains {
                    exchange(address: $0, request: request, deadline: deadline)
                }
                continuation.resume(returning: found)
            }
        }
    }

    /// The addresses a loopback host name stands for, from literals: `localhost` is both families. Anything else is none.
    private static func loopbackAddresses(for host: String, port: UInt16) -> [sockaddr_storage] {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let names: [(family: Int32, text: String)]
        switch bare {
        case "localhost": names = [(AF_INET, "127.0.0.1"), (AF_INET6, "::1")]
        case "127.0.0.1": names = [(AF_INET, bare)]
        case "::1": names = [(AF_INET6, bare)]
        default: return []
        }
        return names.compactMap { family, text in
            var storage = sockaddr_storage()
            if family == AF_INET {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                guard inet_pton(AF_INET, text, &address.sin_addr) == 1 else { return nil }
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: &address, count: MemoryLayout<sockaddr_in>.size)) }
            } else {
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                guard inet_pton(AF_INET6, text, &address.sin6_addr) == 1 else { return nil }
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: UnsafeRawBufferPointer(start: &address, count: MemoryLayout<sockaddr_in6>.size)) }
            }
            return storage
        }
    }

    private static func exchange(address: sockaddr_storage, request: String, deadline: Date) -> Bool {
        var address = address
        let fd = socket(Int32(address.ss_family), streamSocketType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let length = socklen_t(address.ss_family == sa_family_t(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS, ready(fd, Int16(POLLOUT), deadline) else { return false }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else { return false }
        }

        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            guard ready(fd, Int16(POLLOUT), deadline) else { return false }
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            if n > 0 { sent += n } else if errno != EAGAIN && errno != EINTR { return false }
        }

        var head = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16)
        while head.count < 5 {
            guard ready(fd, Int16(POLLIN), deadline) else { return false }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 { head += buffer[0..<n] } else if n == 0 || (errno != EAGAIN && errno != EINTR) { break }
        }
        return String(decoding: head, as: UTF8.self).hasPrefix("HTTP/")
    }

    /// Waits for `events` on `fd` until `deadline`. An error or hang-up counts as ready: the next call reports it.
    private static func ready(_ fd: Int32, _ events: Int16, _ deadline: Date) -> Bool {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            let n = poll(&descriptor, 1, remaining)
            if n > 0 { return true }
            if n == 0 || errno != EINTR { return false }
        }
    }
}
#endif
