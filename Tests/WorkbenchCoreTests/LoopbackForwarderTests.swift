import Foundation
import Testing

@testable import WorkbenchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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

    @Test func anUpstreamWhoseBasePathIsPercentEncodedStartsAndIsForwardedTo() throws {
        let gateway = try FakeGateway()
        defer { gateway.stop() }
        let upstream = try #require(URL(string: "http://127.0.0.1:\(gateway.port)/team%20one/v1"))
        let forwarder = try LoopbackForwarder(LoopbackForwarder.Configuration(upstream: upstream, apiKey: realKey))
        let base = try forwarder.start()
        defer { forwarder.stop() }
        #expect(base.absoluteString.hasSuffix("/team%20one/v1"), "the same encoded path, \(base)")
        let port = try #require(base.port)
        let answer = try #require(Client.call(port: port, Client.get("/team%20one/v1/models")))
        #expect(answer.status == 200)
        #expect(gateway.requests.first?.target == "/team%20one/v1/models")
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

    /// With a pipe this ended the process (SIGPIPE) instead of returning.
    @Test func wakingAnAcceptLoopThatAlreadyClosedItsEndRaisesNoSignal() throws {
        let ends = try #require(ForwarderSocket.wakePair())
        defer { close(ends.writer) }
        close(ends.reader)
        ForwarderSocket.wake(ends.writer)
        ForwarderSocket.wake(ends.writer)
    }

    @Test func sendingToAConnectionTheOtherSideClosedRaisesNoSignal() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let fd = try #require(Client.dial(rig.port))
        defer { close(fd) }
        // A refused request: answered and closed by the forwarder, after which the client goes on writing.
        Client.say(fd, "DELETE /v1/models HTTP/1.1\r\nHost: h\r\n\r\n")
        _ = Client.readAll(fd, seconds: 8)
        for _ in 0..<3 { Client.say(fd, Client.get("/v1/models")) }
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
        // Paced: the bound (256 KiB) is passed in the first few chunks, and an upstream that saturates the CPU is not what this is about.
        let fd = try stalledClient(rig, pauseMs: 1)
        defer { close(fd) }
        #expect(pollUntil(seconds: 15) { rig.forwarder.liveConnectionCount == 0 }, "the connection was let go without a stop")
        let upstreamEnded = pollUntil(seconds: 15) { rig.gateway.connectionWasClosed }
        #expect(upstreamEnded, "and the upstream request was cancelled, not left to run on")
        #expect(rig.forwarder.isRunning, "the forwarder itself is untouched")
        // The next client gets an ordinary short answer: with the endless one still configured it would be fed the same flood, and
        // reading and decoding that took longer the slower the machine (seen as a flake on Linux, never on macOS).
        rig.gateway.reply = { _ in .json(status: 200, body: "{\"data\":[]}") }
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
        // `held[0]` is closed below, once: a second close would close whatever another test had opened under that number since (it
        // did, to an event log: "Bad file descriptor" in an unrelated suite).
        defer { close(held[1]) }
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

    @Test func aKeyTooShortToBeRemovedFromAnAnswerIsRefusedAtTheStart() throws {
        // A key shorter than eight characters cannot be told from ordinary text, so it cannot be kept out of an answer that echoes it:
        // it is refused here, not let through.
        let url = try #require(URL(string: "http://127.0.0.1:9/v1"))
        #expect(throws: LoopbackForwarder.StartError.self) {
            try LoopbackForwarder(LoopbackForwarder.Configuration(upstream: url, apiKey: "secret"))
        }
        #expect(throws: Never.self) { try LoopbackForwarder(LoopbackForwarder.Configuration(upstream: url, apiKey: "12345678")) }
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
