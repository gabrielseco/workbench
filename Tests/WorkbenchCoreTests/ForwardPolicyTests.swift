import Foundation
import Testing

@testable import WorkbenchCore

private let base = URL(string: "https://gw.example/v1")!  // swiftlint:disable:this force_unwrapping

private func head(_ lines: [String]) -> Data { Data(lines.joined(separator: "\r\n").utf8) }

private func refusal(_ body: () throws -> Void) -> ForwardPolicy.Refusal? {
    do {
        try body()
        return nil
    } catch { return error as? ForwardPolicy.Refusal }
}

@Suite struct ForwardPolicyHeadTests {
    @Test func aPlainPostIsParsedWithItsHeadersAndLength() throws {
        let parsed = try ForwardPolicy.parseHead(
            head([
                "POST /v1/chat/completions HTTP/1.1", "Host: 127.0.0.1:4100", "Content-Type: application/json",
                "Content-Length: 12",
            ]))
        #expect(parsed.method == "POST" && parsed.target == "/v1/chat/completions" && parsed.contentLength == 12)
        #expect(parsed.header("content-type") == "application/json" && parsed.header("host") == "127.0.0.1:4100")
        #expect(!parsed.expectsContinue)
    }

    @Test(arguments: ["PUT", "DELETE", "PATCH", "CONNECT", "OPTIONS", "HEAD", "TRACE", "get"])
    func onlyGetAndPostArePassedOn(method: String) {
        let found = refusal { _ = try ForwardPolicy.parseHead(head(["\(method) /v1/models HTTP/1.1", "Host: h"])) }
        #expect(found?.status == 405, "\(method)")
    }

    @Test(arguments: [
        "POST /v1/x", "POST /v1/x HTTP/2", "POST  /v1/x HTTP/1.1", "POST /v1/x HTTP/1.1 extra", "", "POST /v1/x HTTP/0.9",
    ])
    func aRequestLineThatIsNotMethodTargetVersionIsRefused(line: String) {
        #expect(refusal { _ = try ForwardPolicy.parseHead(head([line, "Host: h"])) }?.status == 400, "\(line)")
    }

    @Test func aChunkedRequestBodyIsRefusedWithLengthRequired() {
        let found = refusal {
            _ = try ForwardPolicy.parseHead(head(["POST /v1/x HTTP/1.1", "Transfer-Encoding: chunked", "Content-Length: 4"]))
        }
        #expect(found?.status == 411, "smuggling needs two framings; there is only one")
    }

    @Test(arguments: [
        ["Content-Length: 4", "Content-Length: 4"], ["Content-Length: -1"], ["Content-Length: 1e3"], ["Content-Length: 4 5"],
        ["Content-Length: 99999999999999999999"], ["Bad Header: x"], [" folded: x"], ["NoColon"], [": empty name"],
    ])
    func aMalformedOrRepeatedHeaderIsRefused(lines: [String]) {
        let found = refusal { _ = try ForwardPolicy.parseHead(head(["POST /v1/x HTTP/1.1"] + lines)) }
        #expect(found?.status == 400, "\(lines)")
    }

    @Test func limitsAreEnforcedOnTheHeadTheTargetAndTheBody() {
        var limits = ForwardPolicy.Limits()
        limits.maxHeaderBytes = 64
        let big = Data(repeating: UInt8(ascii: "a"), count: 100)
        #expect(refusal { _ = try ForwardPolicy.parseHead(big, limits: limits) }?.status == 431)
        let long = "/v1/" + String(repeating: "a", count: 3000)
        #expect(refusal { _ = try ForwardPolicy.parseHead(head(["GET \(long) HTTP/1.1", "Host: h"])) }?.status == 414)
        limits = ForwardPolicy.Limits()
        limits.maxBodyBytes = 10
        let over = head(["POST /v1/x HTTP/1.1", "Content-Length: 11"])
        #expect(refusal { _ = try ForwardPolicy.parseHead(over, limits: limits) }?.status == 413)
        #expect(refusal { _ = try ForwardPolicy.parseHead(head(["GET /v1/x HTTP/1.1", "Content-Length: 5"])) }?.status == 400)
    }

    @Test func expectContinueIsRecognisedAndOtherExpectationsAreNot() throws {
        let ok = try ForwardPolicy.parseHead(head(["POST /v1/x HTTP/1.1", "Expect: 100-continue", "Content-Length: 1"]))
        #expect(ok.expectsContinue)
        #expect(refusal { _ = try ForwardPolicy.parseHead(head(["POST /v1/x HTTP/1.1", "Expect: yes"])) }?.status == 417)
    }

    @Test func aHeadWithANulOrNotText() {
        #expect(refusal { _ = try ForwardPolicy.parseHead(Data("POST /v1/x HTTP/1.1\r\nX: a\0b".utf8)) }?.status == 400)
        #expect(refusal { _ = try ForwardPolicy.parseHead(Data([0xFF, 0xFE, 0x41])) }?.status == 400)
    }
}

@Suite struct ForwardPolicyPathTests {
    @Test(arguments: ["/v1", "/v1/models", "/v1/chat/completions", "/v1/models?limit=5", "/v1/a/b/c", "/v1/a-b_c.d"])
    func aPathUnderTheBasePathIsForwardedToTheUpstreamsOwnHost(target: String) throws {
        let url = try ForwardPolicy.upstreamURL(base: base, target: target)
        #expect(url.scheme == "https" && url.host == "gw.example" && url.port == nil, "\(url)")
        #expect(url.absoluteString == "https://gw.example\(target)")
    }

    @Test(arguments: [
        "/", "/v2/models", "/v1x", "/admin", "/v1/../admin", "/v1/./models", "/v1/a/../../b", "/v1//models", "/v1/%2e%2e/admin",
        "/v1/%2E%2E/admin", "/v1/a%2fb", "/v1/a%5Cb", "/v1/a\\b", "/v1/%00", "/v1/a b", "/v1/a\tb",
    ])
    func aPathOutsideTheBaseOrWithTraversalInAnyFormIsForbidden(target: String) {
        let found = refusal { _ = try ForwardPolicy.upstreamURL(base: base, target: target) }
        #expect(found != nil && [400, 403].contains(found?.status ?? 0), "\(target)")
    }

    @Test(arguments: ["http://evil.example/v1/models", "https://evil.example/v1", "//evil.example/v1/models", "evil.example:443", "*"])
    func aTargetThatNamesAnotherHostIsNeverForwardedAnywhere(target: String) {
        #expect(refusal { _ = try ForwardPolicy.upstreamURL(base: base, target: target) } != nil, "\(target)")
    }

    @Test(arguments: [
        "/v1/%", "/v1/%z", "/v1/%zz", "/v1/%2", "/v1/a%", "/v1/models?q=%", "/v1/models?q=%g1", "/v1/ü", "/v1/models?q=ü",
        "/v1/a{b}", "/v1/a\"b", "/v1/a<b>", "/v1/a|b", "/v1/a^b", "/v1/a`b",
    ])
    func aTargetThatIsNotValidPercentEncodingIsRefusedAndNeverReachesFoundation(target: String) {
        // Foundation's percentEncoded setters raise on an invalid string, which would end the process, so it must not get one.
        let found = refusal { _ = try ForwardPolicy.upstreamURL(base: base, target: target) }
        #expect(found?.status == 400, "\(target)")
    }

    @Test(arguments: ["/v1/a%20b", "/v1/models?q=a%20b", "/v1/a%C3%BCb", "/v1/models?q=%41", "/v1/a:b@c", "/v1/models?a=b&c=d;e"])
    func validPercentEscapesAndTheCharactersAUrlMayHoldAreKept(target: String) throws {
        #expect(try ForwardPolicy.upstreamURL(base: base, target: target).absoluteString == "https://gw.example\(target)")
    }

    @Test func aBadQueryIsRefusedAndAGoodOneIsKept() throws {
        #expect(refusal { _ = try ForwardPolicy.upstreamURL(base: base, target: "/v1/models?a=b c") }?.status == 400)
        #expect(refusal { _ = try ForwardPolicy.upstreamURL(base: base, target: "/v1/models?a=b#x") }?.status == 400)
        #expect(try ForwardPolicy.upstreamURL(base: base, target: "/v1/models?a=b&c=d").query == "a=b&c=d")
    }

    @Test func theUpstreamsPortAndAnEmptyBasePathAreKept() throws {
        let withPort = try #require(URL(string: "http://127.0.0.1:9000/api/v1/"))
        #expect(try ForwardPolicy.upstreamURL(base: withPort, target: "/api/v1/models").absoluteString == "http://127.0.0.1:9000/api/v1/models")
        let root = try #require(URL(string: "https://gw.example"))
        #expect(try ForwardPolicy.upstreamURL(base: root, target: "/anything").absoluteString == "https://gw.example/anything")
    }
}

@Suite struct ForwardPolicyCredentialTests {
    private func parsed(_ extra: [String]) throws -> ForwardPolicy.RequestHead {
        try ForwardPolicy.parseHead(head(["POST /v1/x HTTP/1.1", "Content-Length: 0"] + extra))
    }

    @Test func theClientsOwnCredentialsAreReplacedByTheKeyAndNothingElseIsPassed() throws {
        let sent = try parsed([
            "Authorization: Bearer forwarder", "Cookie: a=b", "X-Forwarded-For: 1.2.3.4", "Host: evil.example",
            "Proxy-Authorization: x",
            "Content-Type: application/json", "Accept: text/event-stream", "X-Api-Key: other", "User-Agent: opencode",
        ])
        let out = ForwardPolicy.upstreamHeaders(for: sent, key: "the-real-key")
        let expected = ["authorization": "Bearer the-real-key", "content-type": "application/json", "accept": "text/event-stream"]
        #expect(out == expected)
    }

    @Test func aHeaderValueWithAControlCharacterIsDropped() throws {
        let sent = try parsed(["Accept: text/plain\u{1}"])
        #expect(ForwardPolicy.upstreamHeaders(for: sent, key: "k").keys.sorted() == ["authorization"])
    }

    @Test func hopByHopAndCredentialCarryingAnswerHeadersAreNotPassedBack() {
        let dropped = ["Connection", "Transfer-Encoding", "Content-Length", "Content-Encoding", "Set-Cookie"]
        for name in dropped + ["WWW-Authenticate", "Location", "Keep-Alive"] {
            #expect(!ForwardPolicy.passesBack(name), "\(name)")
        }
        for name in ["Content-Type", "X-Request-Id", "Retry-After", "X-RateLimit-Remaining", "Cache-Control"] {
            #expect(ForwardPolicy.passesBack(name), "\(name)")
        }
    }

    @Test func theExactKeyIsRemovedEverywhereAndAShortOneIsNot() {
        let key = "sk-abcdefgh12345678"
        let text = Data("Invalid key \(key); again \(key). tail".utf8)
        let cleaned = String(decoding: ForwardPolicy.redact(text, key: key), as: UTF8.self)
        #expect(cleaned == "Invalid key [key removed]; again [key removed]. tail")
        #expect(ForwardPolicy.redact(Data("an abc of".utf8), key: "abc") == Data("an abc of".utf8))
        #expect(ForwardPolicy.redact(Data(), key: key).isEmpty)
        #expect(ForwardPolicy.redact(Data("nothing here".utf8), key: key) == Data("nothing here".utf8))
    }

    @Test func anErrorBodyIsTheShapeOpenaiCompatibleClientsRead() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: ForwardPolicy.errorBody("no \"way\"")) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["message"] as? String == "no \"way\"" && error["type"] as? String == "workbench_forwarder")
    }
}
