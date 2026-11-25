import Foundation
import Testing

@testable import WorkbenchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

private let realKey = "sk-real-gateway-key-0123456789"

#if canImport(Darwin)
    private let streamSocket = SOCK_STREAM
    private let noSignal: Int32 = 0
#else
    private let streamSocket = Int32(SOCK_STREAM.rawValue)
    private let noSignal = Int32(MSG_NOSIGNAL)
#endif

// MARK: A fake gateway and a raw client, over real loopback sockets

/// What the fake gateway saw of one request.
private struct Seen {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data
}

private enum Reply {
    case json(status: Int, body: String, headers: [String: String] = [:])
    /// A streamed 200: each chunk is sent as it is reached; `gate`, when set, holds the rest back until the test signals it.
    case stream(first: String, gate: DispatchSemaphore?, rest: String)
    case redirect(String)
    /// Streams `chunkKilobytes` at a time, every `pauseMs`, until its peer closes the connection, and records that it did.
    case flood(chunkKilobytes: Int, pauseMs: Int)
    /// Answers nothing, and records whether the forwarder closed the connection (a cancelled request).
    case silent
}

private final class FakeGateway: @unchecked Sendable {
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

private struct Answer {
    var status: Int
    var headers: [String: String]
    var body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
}

/// A client that speaks raw HTTP/1.1 to the forwarder, as OpenCode's would.
private enum Client {
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

private struct Rig {
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

// MARK: The tests

/// Serialized: these tests block their threads (waiting on sockets for seconds), and Swift Testing runs a synchronous test on the
/// cooperative pool, whose width is the core count. Dozens of them at once leave URLSession (which needs that pool to deliver its
/// callbacks) nothing to run on, and every forwarder in the process stalls: seen as responses that never come, only in a full parallel
/// run. One at a time leaves the pool free.
@Suite(.serialized) struct LoopbackForwarderTests {
    @Test func itListensOnLoopbackOnAnEphemeralPortAndHandsBackTheBaseUrlWithTheUpstreamsPath() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        #expect(rig.base.scheme == "http" && rig.base.host == "127.0.0.1" && rig.base.path == "/v1")
        #expect((rig.base.port ?? 0) > 1023 && rig.base.port != rig.gateway.port)
        #expect(rig.forwarder.isRunning)
    }

    @Test func aPostIsForwardedWithItsBodyAndTheRealKeyInPlaceOfTheClientsCredentials() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.gateway.reply = { _ in .json(status: 200, body: "{\"ok\":true}") }
        let answer = try #require(
            Client.call(
                port: rig.port,
                Client.post(
                    body: "{\"model\":\"m\"}",
                    extra: [
                        "Authorization: Bearer forwarder", "Cookie: a=b", "X-Forwarded-For: 9.9.9.9", "Accept: text/event-stream",
                    ])))
        #expect(answer.status == 200 && answer.text == "{\"ok\":true}")
        let seen = try #require(rig.gateway.requests.first)
        #expect(seen.method == "POST" && seen.target == "/v1/chat/completions")
        #expect(String(decoding: seen.body, as: UTF8.self) == "{\"model\":\"m\"}")
        #expect(seen.headers["authorization"] == "Bearer \(realKey)", "the key is added here, and only here")
        #expect(seen.headers["cookie"] == nil && seen.headers["x-forwarded-for"] == nil)
        #expect(seen.headers["content-type"] == "application/json" && seen.headers["accept"] == "text/event-stream")
        #expect(seen.headers["host"] == "127.0.0.1:\(rig.gateway.port)", "the upstream's own host, not the client's")
    }

    @Test func aGetUnderTheBasePathIsForwarded() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.gateway.reply = { _ in .json(status: 200, body: "{\"data\":[]}", headers: ["X-Request-Id": "abc"]) }
        let answer = try #require(Client.call(port: rig.port, Client.get("/v1/models?limit=3")))
        #expect(answer.status == 200 && answer.headers["x-request-id"] == "abc" && answer.text == "{\"data\":[]}")
        #expect(rig.gateway.requests.first?.target == "/v1/models?limit=3")
    }

    @Test func aStreamedAnswerReachesTheClientBeforeTheUpstreamHasFinished() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let gate = DispatchSemaphore(value: 0)
        rig.gateway.reply = { _ in .stream(first: "data: one\n\n", gate: gate, rest: "data: two\n\ndata: [DONE]\n\n") }
        let fd = try #require(Client.dial(rig.port))
        defer { close(fd) }
        Client.say(fd, Client.post(extra: ["Accept: text/event-stream"]))
        let early = Client.readAll(fd, seconds: 8) { String(decoding: $0, as: UTF8.self).contains("data: one") }
        #expect(String(decoding: early, as: UTF8.self).contains("data: one"), "the first event is not held until the end")
        #expect(!String(decoding: early, as: UTF8.self).contains("data: two"), "the upstream has not sent the rest yet")
        gate.signal()
        let all = Client.readAll(fd, seconds: 8)
        let answer = try #require(Client.parse(early + all))
        #expect(answer.status == 200 && answer.headers["content-type"] == "text/event-stream")
        #expect(answer.text == "data: one\n\ndata: two\n\ndata: [DONE]\n\n")
    }

    @Test(arguments: [
        "/v2/models", "/admin", "/v1/../admin", "/v1/%2e%2e/admin", "/v1//x", "http://evil.example/v1/models", "//evil.example/v1/x",
    ])
    func aTargetOutsideTheBasePathNeverReachesTheUpstream(target: String) throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let answer = try #require(Client.call(port: rig.port, Client.get(target)))
        #expect([400, 403].contains(answer.status), "\(target): \(answer.status)")
        #expect(answer.text.contains("workbench_forwarder"), "a message the client can show")
        #expect(rig.gateway.requests.isEmpty, "\(target) reached the upstream")
    }

    @Test(arguments: ["PUT", "DELETE", "PATCH", "CONNECT"])
    func aMethodOtherThanGetOrPostIsRefused(method: String) throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let answer = try #require(Client.call(port: rig.port, "\(method) /v1/models HTTP/1.1\r\nHost: h\r\n\r\n"))
        #expect(answer.status == 405)
        #expect(rig.gateway.requests.isEmpty)
    }

    @Test func aChunkedRequestBodyIsRefusedAndABodyOverTheLimitIsRefusedBeforeItIsRead() throws {
        let rig = try Rig { $0.limits.maxBodyBytes = 16 }
        defer { rig.tearDown() }
        let chunked = "POST /v1/x HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        #expect(Client.call(port: rig.port, chunked)?.status == 411)
        let big = "POST /v1/x HTTP/1.1\r\nHost: h\r\nContent-Length: 1000000\r\n\r\n"
        #expect(Client.call(port: rig.port, big)?.status == 413, "answered from the head alone")
        #expect(rig.gateway.requests.isEmpty)
    }

    @Test func aRedirectIsNeverFollowedSoTheKeyCannotGoToAnotherHost() throws {
        let other = try FakeGateway()
        defer { other.stop() }
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.gateway.reply = { _ in .redirect("http://127.0.0.1:\(other.port)/v1/steal") }
        let answer = try #require(Client.call(port: rig.port, Client.post()))
        #expect(answer.status == 502 && answer.text.contains("redirect"), "\(answer.status) \(answer.text)")
        #expect(answer.headers["location"] == nil)
        #expect(other.requests.isEmpty, "nothing was sent to the host the redirect named")
    }

    @Test func anErrorAnswerIsPassedOnWithItsStatusAndTheKeyTakenOut() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.gateway.reply = { _ in
            .json(status: 401, body: "{\"error\":{\"message\":\"Invalid API key: \(realKey)\"}}", headers: ["X-Echo": realKey])
        }
        let answer = try #require(Client.call(port: rig.port, Client.post()))
        #expect(answer.status == 401)
        #expect(!answer.text.contains(realKey), "the key is gone")
        #expect(answer.text.contains("[key removed]") && answer.text.contains("Invalid API key"), "the rest is kept")
        #expect(!(answer.headers["x-echo"] ?? "").contains(realKey), "a header that echoes it is cleaned too")
        #expect(answer.headers["content-length"] == "\(answer.body.count)")
    }

    @Test func aSuccessfulAnswerWhoseHeaderEchoesTheKeyDoesNotCarryItToTheClient() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.gateway.reply = { _ in .json(status: 200, body: "{}", headers: ["X-Echo": "k=\(realKey)", "X-Other": "fine"]) }
        let answer = try #require(Client.call(port: rig.port, Client.post()))
        #expect(answer.status == 200 && answer.headers["x-other"] == "fine")
        #expect(!(answer.headers["x-echo"] ?? "").contains(realKey), "a 200 is cleaned as an error is: \(answer.headers)")
        #expect(answer.headers["x-echo"] == "k=[key removed]")
    }

    @Test func aMalformedTargetOverTheWireIsAnAnswerAndTheServerStaysUp() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        for target in ["/v1/%", "/v1/models?q=%", "/v1/%zz"] {
            #expect(Client.call(port: rig.port, Client.get(target))?.status == 400, "\(target)")
        }
        #expect(Client.call(port: rig.port, Client.get("/v1/models"))?.status == 200, "still serving")
        #expect(rig.gateway.requests.count == 1)
    }

    /// A client that sends its request and then reads nothing, with an answer that never ends.
    private func stalledClient(_ rig: Rig, pauseMs: Int) throws -> Int32 {
        rig.gateway.reply = { _ in .flood(chunkKilobytes: 64, pauseMs: pauseMs) }
        let fd = try #require(Client.dial(rig.port))
        var small: Int32 = 4096
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        Client.say(fd, Client.post())
        #expect(pollUntil { !rig.gateway.requests.isEmpty }, "the request reached the upstream")
        return fd
    }

    @Test func aClientThatStopsReadingIsDroppedWhenItsBacklogPassesTheBoundAndTheUpstreamRequestEnds() throws {
        let rig = try Rig { $0.limits.maxQueuedBytes = 256 * 1024 }
        defer { rig.tearDown() }
        let fd = try stalledClient(rig, pauseMs: 0)
        defer { close(fd) }
        #expect(pollUntil(seconds: 15) { rig.forwarder.liveConnectionCount == 0 }, "the connection was let go without a stop")
        let upstreamEnded = pollUntil(seconds: 15) { rig.gateway.connectionWasClosed }
        #expect(upstreamEnded, "and the upstream request was cancelled, not left to run on")
        #expect(rig.forwarder.isRunning, "the forwarder itself is untouched")
        #expect(
            pollUntil(seconds: 20) { Client.call(port: rig.port, Client.get("/v1/models"), seconds: 3)?.status == 200 },
            "and serves the next client")
    }

    @Test func stopEndsAConnectionThatIsBlockedWritingToAClientThatReadsNothing() throws {
        // Paced, and the backlog bound out of reach: the connection thread is stuck in its write, not dropped for a backlog.
        let rig = try Rig { $0.limits.maxQueuedBytes = 1024 * 1024 * 1024 }
        defer { rig.tearDown() }
        let fd = try stalledClient(rig, pauseMs: 5)
        defer { close(fd) }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(rig.forwarder.liveConnectionCount == 1, "still being served, and stuck")
        rig.forwarder.stop()
        let ended = pollUntil(seconds: 15) { rig.forwarder.liveConnectionCount == 0 }
        #expect(ended, "stop reached the blocked write and ended the connection")
        #expect(pollUntil(seconds: 15) { rig.gateway.connectionWasClosed }, "and the upstream request")
    }

    @Test func anUpstreamErrorBodyIsBoundedWhenItIsLarge() throws {
        let rig = try Rig { $0.limits.maxErrorBodyBytes = 100 }
        defer { rig.tearDown() }
        rig.gateway.reply = { _ in .json(status: 500, body: String(repeating: "x", count: 5000)) }
        let answer = try #require(Client.call(port: rig.port, Client.post()))
        #expect(answer.status == 500 && answer.body.count == 100)
    }

    @Test func anUnreachableUpstreamIsAGatewayErrorThatNamesNoKey() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.gateway.stop()
        #expect(pollUntil { Client.dial(rig.gateway.port) == nil }, "nothing listens there now")
        let answer = try #require(Client.call(port: rig.port, Client.post()))
        #expect([502, 504].contains(answer.status), "\(answer.status)")
        #expect(!answer.text.contains(realKey))
    }

    @Test func aClientThatGoesAwayEndsTheUpstreamRequest() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.gateway.reply = { _ in .silent }
        let fd = try #require(Client.dial(rig.port))
        Client.say(fd, Client.post())
        #expect(pollUntil { !rig.gateway.requests.isEmpty }, "the request reached the upstream")
        close(fd)
        let cancelled = pollUntil(seconds: 15) { rig.gateway.connectionWasClosed }
        #expect(cancelled, "the upstream request was cancelled when the client left")
    }

    @Test func aClientThatSendsNothingIsClosedAfterTheReadTimeout() throws {
        let rig = try Rig { $0.clientReadTimeout = 1 }
        defer { rig.tearDown() }
        let fd = try #require(Client.dial(rig.port))
        defer { close(fd) }
        let started = Date()
        let answer = Client.parse(Client.readAll(fd, seconds: 6))
        #expect(answer?.status == 400, "told why, then closed")
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(rig.gateway.requests.isEmpty)
    }

    @Test func connectionsPastTheCapAreClosedAtOnceAndANewOneIsServedWhenAnotherEnds() throws {
        let rig = try Rig { $0.maxConnections = 2 }
        defer { rig.tearDown() }
        let held = try [#require(Client.dial(rig.port)), #require(Client.dial(rig.port))]
        defer { held.forEach { close($0) } }
        // Both are admitted and waiting for a request, so a third is over the cap.
        Thread.sleep(forTimeInterval: 0.3)
        let third = try #require(Client.dial(rig.port))
        defer { close(third) }
        let closed = Client.readAll(third, seconds: 3)
        #expect(closed.isEmpty, "closed without an answer")
        close(held[0])
        #expect(pollUntil { Client.call(port: rig.port, Client.get("/v1/models"))?.status == 200 }, "room again")
    }

    @Test func stopClosesTheListenerEndsALiveConnectionAndCanBeCalledAgain() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.gateway.reply = { _ in .silent }
        let fd = try #require(Client.dial(rig.port))
        defer { close(fd) }
        Client.say(fd, Client.post())
        #expect(pollUntil { !rig.gateway.requests.isEmpty })
        rig.forwarder.stop()
        rig.forwarder.stop()
        #expect(!rig.forwarder.isRunning)
        #expect(pollUntil { Client.dial(rig.port) == nil }, "the port refuses connections")
        #expect(pollUntil(seconds: 15) { rig.gateway.connectionWasClosed }, "the upstream request was cancelled")
        _ = Client.readAll(fd, seconds: 3)
    }

    @Test func aForwarderThatWasNeverStartedStopsQuietlyAndOneCannotBeStartedTwice() throws {
        let url = try #require(URL(string: "http://127.0.0.1:9/v1"))
        let idle = try LoopbackForwarder(LoopbackForwarder.Configuration(upstream: url, apiKey: realKey))
        idle.stop()
        #expect(!idle.isRunning)
        let twice = try LoopbackForwarder(LoopbackForwarder.Configuration(upstream: url, apiKey: realKey))
        _ = try twice.start()
        defer { twice.stop() }
        #expect(throws: LoopbackForwarder.StartError.self) { try twice.start() }
    }

    @Test func aBadUpstreamOrAnEmptyKeyIsRefusedAtTheStart() throws {
        for bad in ["ftp://h/v1", "http://u:p@h/v1", "h/v1", "http:///v1"] {
            let url = try #require(URL(string: bad))
            #expect(throws: LoopbackForwarder.StartError.self, "\(bad)") {
                try LoopbackForwarder(LoopbackForwarder.Configuration(upstream: url, apiKey: realKey))
            }
        }
        let ok = try #require(URL(string: "http://127.0.0.1:9/v1"))
        #expect(throws: LoopbackForwarder.StartError.self) {
            try LoopbackForwarder(LoopbackForwarder.Configuration(upstream: ok, apiKey: ""))
        }
    }

    @Test func theKeyIsInNeitherTheDescriptionNorTheConfigurationsDump() throws {
        let url = try #require(URL(string: "http://127.0.0.1:9/v1"))
        let configuration = LoopbackForwarder.Configuration(upstream: url, apiKey: realKey)
        #expect(!"\(configuration)".contains(realKey) && !String(reflecting: configuration).contains(realKey))
    }
}

/// Polls `condition` for up to `seconds` (five by default).
private func pollUntil(seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}
