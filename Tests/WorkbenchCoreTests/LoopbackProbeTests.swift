import Foundation
import Testing

@testable import WorkbenchCore

/// A listening socket on this machine whose connections are handled by a script, so each case of the probe has a server
/// that behaves exactly that way.
private final class Server: @unchecked Sendable {
    let port: Int
    private let running = Switch()
    private let handler: @Sendable (Int32) -> Void

    init?(ipv6: Bool = false, handler: @escaping @Sendable (Int32) -> Void) {
        self.handler = handler
        let family = ipv6 ? AF_INET6 : AF_INET
        let listener = socket(family, streamSocketType, 0)
        guard listener >= 0 else { return nil }
        var address = LoopbackProbe.addresses(for: ipv6 ? "::1" : "127.0.0.1", port: 0)[0]
        let length = socklen_t(ipv6 ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            close(listener)
            return nil
        }
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        guard named == 0 else {
            close(listener)
            return nil
        }
        // sin_port and sin6_port both sit at byte 2.
        port = Int(UInt16(bigEndian: withUnsafeBytes(of: &address) { $0.load(fromByteOffset: 2, as: UInt16.self) }))
        // The loop holds the descriptor and the flag, not the server, so dropping the server ends it and closes the listener.
        let flag = running
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        DispatchQueue.global().async { [handler] in
            defer { close(listener) }
            var watch = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            while flag.isOn {
                guard poll(&watch, 1, 100) > 0 else { continue }
                let client = accept(listener, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global().async {
                    handler(client)
                    close(client)
                }
            }
        }
    }

    deinit { running.turnOff() }

    static func say(_ text: String, to client: Int32) {
        _ = text.withCString { send(client, $0, strlen($0), sendFlags) }
    }

    /// Reads the request so the client is not reset before it has finished sending.
    static func hear(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 512)
        _ = recv(client, &buffer, buffer.count, 0)
    }
}

@Suite struct LoopbackProbeTests {
    private func url(_ host: String, _ port: Int, _ path: String = "/") -> String { "http://\(host):\(port)\(path)" }

    @Test func aServerThatAnswersWithAStatusLineIsUpWhateverTheStatus() async throws {
        for status in ["200 OK", "404 Not Found", "302 Found", "503 Service Unavailable"] {
            let server = try #require(Server { client in
                Server.hear(client)
                Server.say("HTTP/1.0 \(status)\r\n\r\n", to: client)
            })
            #expect(await LoopbackProbe.answers(url("127.0.0.1", server.port)), "\(status)")
        }
    }

    @Test func aStatusLineSplitAcrossPacketsIsStillRead() async throws {
        let server = try #require(Server { client in
            Server.hear(client)
            Server.say("HT", to: client)
            usleep(150_000)
            Server.say("TP/1", to: client)
            usleep(150_000)
            Server.say(".1 200 OK\r\n\r\n", to: client)
        })
        #expect(await LoopbackProbe.answers(url("localhost", server.port)))
    }

    @Test func aServerThatClosesWithoutAnAnswerIsNotUp() async throws {
        let server = try #require(Server { client in Server.hear(client) })
        #expect(await LoopbackProbe.answers(url("127.0.0.1", server.port)) == false)
    }

    @Test func somethingThatListensButAnswersWithAnotherProtocolIsNotUp() async throws {
        let server = try #require(Server { client in
            Server.hear(client)
            Server.say("SSH-2.0-OpenSSH\r\n", to: client)
        })
        #expect(await LoopbackProbe.answers(url("127.0.0.1", server.port)) == false)
    }

    @Test func aServerThatNeverAnswersEndsAtTheDeadline() async throws {
        let server = try #require(Server { client in
            Server.hear(client)
            usleep(3_000_000)
        })
        let started = Date()
        #expect(await LoopbackProbe.answers(url("127.0.0.1", server.port), attempt: 0.4) == false)
        #expect(Date().timeIntervalSince(started) < 1.5, "it gave up at its deadline, not the server's")
    }

    @Test func aNameThatIsNotThisMachineIsNeverResolvedAndIsNotUp() async {
        let started = Date()
        #expect(await LoopbackProbe.answers("http://no-such-host.invalid:8080/") == false)
        #expect(await LoopbackProbe.answers("http://example.com:80/") == false)
        #expect(Date().timeIntervalSince(started) < 0.5, "no lookup was made, so nothing waited on one")
    }

    @Test func aPortNothingListensOnIsNotUp() async throws {
        let port = try #require(AppLauncher.freePort())
        #expect(await LoopbackProbe.answers(url("127.0.0.1", port)) == false)
    }

    @Test func anIPv6LiteralIsReadWithItsBracketsOrWithout() async throws {
        // A machine without an IPv6 loopback cannot listen on it; the address parsing below still runs.
        if let server = Server(ipv6: true, handler: { client in
            Server.hear(client)
            Server.say("HTTP/1.0 200 OK\r\n\r\n", to: client)
        }) {
            #expect(await LoopbackProbe.answers(url("[::1]", server.port)))
        }
        #expect(LoopbackProbe.addresses(for: "[::1]", port: 1).count == 1)
        #expect(LoopbackProbe.addresses(for: "::1", port: 1).count == 1)
        #expect(LoopbackProbe.addresses(for: "localhost", port: 1).count == 2, "localhost is both families")
    }

    @Test func aCancelledCheckReturnsAtOnceInsteadOfWaitingForTheDeadline() async throws {
        let server = try #require(Server { client in
            Server.hear(client)
            usleep(3_000_000)
        })
        let target = url("127.0.0.1", server.port)
        let started = Date()
        let task = Task { await LoopbackProbe.answers(target, attempt: 30) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        #expect(await task.value == false)
        #expect(Date().timeIntervalSince(started) < 3, "cancelled, it did not wait out its 30 seconds")
    }

    @Test func aRedirectIsAnAnswerAndIsNotFollowed() async throws {
        let hits = Hits()
        let server = try #require(Server { client in
            hits.add()
            Server.hear(client)
            Server.say("HTTP/1.1 301 Moved\r\nLocation: http://example.com/\r\n\r\n", to: client)
        })
        #expect(await LoopbackProbe.answers(url("127.0.0.1", server.port)))
        #expect(hits.count == 1)
    }
}

private final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func turnOff() { lock.lock(); on = false; lock.unlock() }
}

private final class Hits: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func add() { lock.lock(); n += 1; lock.unlock() }
}
