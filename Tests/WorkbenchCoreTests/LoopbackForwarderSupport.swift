import Foundation
import Testing

@testable import WorkbenchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

let realKey = "sk-real-gateway-key-0123456789"

#if canImport(Darwin)
    private let streamSocket = SOCK_STREAM
    private let noSignal: Int32 = 0
#else
    private let streamSocket = Int32(SOCK_STREAM.rawValue)
    private let noSignal = Int32(MSG_NOSIGNAL)
#endif

// MARK: A fake gateway and a raw client, over real loopback sockets

/// What the fake gateway saw of one request.
struct Seen {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data
}

enum Reply {
    case json(status: Int, body: String, headers: [String: String] = [:])
    /// A streamed 200: each chunk is sent as it is reached; `gate`, when set, holds the rest back until the test signals it.
    case stream(first: String, gate: DispatchSemaphore?, rest: String)
    case redirect(String)
    /// Streams `chunkKilobytes` at a time, every `pauseMs`, until its peer closes the connection, and records that it did.
    case flood(chunkKilobytes: Int, pauseMs: Int)
    /// Answers nothing, and records whether the forwarder closed the connection (a cancelled request).
    case silent
}

final class FakeGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Seen] = []
    private var sawClose = false
    private(set) var port = 0
    var reply: @Sendable (Seen) -> Reply = { _ in .json(status: 200, body: "{}") }

    init() throws {
        let fd = socket(AF_INET, streamSocket, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        listen(fd, 16)
        var length = size
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.start()
    }

    var requests: [Seen] { lock.withLock { seen } }
    var connectionWasClosed: Bool { lock.withLock { sawClose } }

    private var stopping = false

    /// The listener closes on its own thread: closing a descriptor another thread is blocked on does not wake it, so it polls.
    func stop() { lock.withLock { stopping = true } }

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd) }
        while !lock.withLock({ stopping }) {
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&entry, 1, 50) > 0 else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            Thread { [self] in handle(client) }.start()
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        // A peer that goes away mid-answer is an error from `send`, not a signal that ends the test process.
        #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        guard let request = Self.read(client) else { return }
        lock.withLock { seen.append(request) }
        switch reply(request) {
        case .json(let status, let body, let headers):
            var head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\n"
            head += "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            Self.write(client, head + "\r\n" + body)
        case .redirect(let location):
            Self.write(client, "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        case .stream(let first, let gate, let rest):
            Self.write(
                client,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
            let sent = Self.write(client, "\(String(first.utf8.count, radix: 16))\r\n\(first)\r\n")
            gate?.wait()
            let finished = sent && Self.write(client, "\(String(rest.utf8.count, radix: 16))\r\n\(rest)\r\n0\r\n\r\n")
            if !finished { lock.withLock { sawClose = true } }
        case .flood(let chunkKilobytes, let pauseMs):
            Self.write(
                client,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
            let chunk = String(repeating: "x", count: chunkKilobytes * 1024)
            while Self.write(client, "\(String(chunk.utf8.count, radix: 16))\r\n\(chunk)\r\n") {
                Thread.sleep(forTimeInterval: Double(pauseMs) / 1000)
            }
            lock.withLock { sawClose = true }
        case .silent:
            for _ in 0..<400 {
                var entry = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                if poll(&entry, 1, 50) > 0 {
                    var byte: UInt8 = 0
                    if recv(client, &byte, 1, 0) == 0 {
                        lock.withLock { sawClose = true }
                        return
                    }
                }
            }
        }
    }

    @discardableResult
    private static func write(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { buffer -> Bool in
            var sent = 0
            while sent < buffer.count {
                guard let start = buffer.baseAddress else { return true }
                let n = send(fd, start + sent, buffer.count - sent, noSignal)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private static func read(_ fd: Int32) -> Seen? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return nil }
            data.append(contentsOf: buffer[..<n])
        }
        let end = data.range(of: Data("\r\n\r\n".utf8))!  // swiftlint:disable:this force_unwrapping
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ").map(String.init)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).lowercased()
                headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        var body = Data(data[end.upperBound...])
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < length {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            body.append(contentsOf: buffer[..<n])
        }
        return Seen(method: first[0], target: first.count > 1 ? first[1] : "", headers: headers, body: body)
    }
}

struct Answer {
    var status: Int
    var headers: [String: String]
    var body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
}

/// A client that speaks raw HTTP/1.1 to the forwarder, as OpenCode's would.
enum Client {
    static func dial(_ port: Int) -> Int32? {
        let fd = socket(AF_INET, streamSocket, 0)
        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func say(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = send(fd, bytes, bytes.count, 0)
    }

    /// Everything until the peer closes (or `seconds` pass), as the first `limit` bytes when given.
    static func readAll(_ fd: Int32, seconds: Double = 8, until: ((Data) -> Bool)? = nil) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&entry, 1, 100) <= 0 { continue }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buffer[..<n])
            if let until, until(data) { break }
        }
        return data
    }

    static func parse(_ raw: Data) -> Answer? {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: raw[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        guard let status = lines[0].split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).lowercased()
                headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        var body = Data(raw[end.upperBound...])
        if headers["transfer-encoding"] == "chunked" { body = dechunk(body) }
        return Answer(status: status, headers: headers, body: body)
    }

    private static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var rest = data[...]
        while let line = rest.range(of: Data("\r\n".utf8)) {
            guard let size = Int(String(decoding: rest[..<line.lowerBound], as: UTF8.self), radix: 16), size > 0 else { break }
            let start = line.upperBound
            guard rest.count >= start - rest.startIndex + size else { break }
            out.append(rest[start..<(start + size)])
            rest = rest[(start + size + 2 <= rest.endIndex ? start + size + 2 : rest.endIndex)...]
        }
        return out
    }

    /// One whole request and its answer.
    static func call(port: Int, _ request: String, seconds: Double = 8) -> Answer? {
        guard let fd = dial(port) else { return nil }
        defer { close(fd) }
        say(fd, request)
        return parse(readAll(fd, seconds: seconds))
    }

    static func post(_ target: String = "/v1/chat/completions", body: String = "{\"x\":1}", extra: [String] = []) -> String {
        let lines = [
            "POST \(target) HTTP/1.1", "Host: 127.0.0.1", "Content-Type: application/json", "Content-Length: \(body.utf8.count)",
        ]
        return (lines + extra).joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    static func get(_ target: String, extra: [String] = []) -> String {
        (["GET \(target) HTTP/1.1", "Host: 127.0.0.1"] + extra).joined(separator: "\r\n") + "\r\n\r\n"
    }
}

struct Rig {
    let gateway: FakeGateway
    let forwarder: LoopbackForwarder
    let port: Int
    let base: URL

    init(configure: (inout LoopbackForwarder.Configuration) -> Void = { _ in }) throws {
        gateway = try FakeGateway()
        var configuration = LoopbackForwarder.Configuration(
            upstream: try #require(URL(string: "http://127.0.0.1:\(gateway.port)/v1")), apiKey: realKey)
        configure(&configuration)
        forwarder = try LoopbackForwarder(configuration)
        base = try forwarder.start()
        port = try #require(base.port)
    }

    func tearDown() {
        forwarder.stop()
        gateway.stop()
    }
}

/// Polls `condition` for up to `seconds` (five by default).
func pollUntil(seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}
