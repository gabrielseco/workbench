import Foundation

/// What `LoopbackForwarder` will and will not pass on, as pure functions of bytes and strings so every refusal is tested without a socket.
///
/// The forwarder exists because a sandboxed OpenCode can only reach loopback (`docs/plan/P28-capabilities.md`, task 1b) and because the
/// real key must never be in the environment an agent's shell can print. Everything that arrives on its port came from an agent that may
/// be hostile or confused, so it is parsed strictly and forwarded only to the one configured upstream, on paths under the base path,
/// with the key added here and nothing of the client's credentials passed on.
public enum ForwardPolicy {
    /// Why a request was not forwarded, with the status the client is told.
    public struct Refusal: Error, Equatable {
        public var status: Int
        public var message: String
        init(_ status: Int, _ message: String) {
            self.status = status
            self.message = message
        }
    }

    public struct Limits: Sendable, Equatable {
        public var maxHeaderBytes = 16 * 1024
        public var maxBodyBytes = 32 * 1024 * 1024
        public var maxTargetBytes = 2 * 1024
        /// A non-2xx answer is buffered to be cleaned of the key before it is passed on; past this it is cut.
        public var maxErrorBodyBytes = 64 * 1024
        /// What may wait to be written to a client that reads slowly. Past it the client is dropped and the upstream request ended: a
        /// model's tokens are small, so a backlog this size means the client has stopped reading.
        public var maxQueuedBytes = 4 * 1024 * 1024
        public init() {}
    }

    public struct RequestHead: Equatable {
        public var method: String
        public var target: String
        /// Lower-cased names, in order. Values are as sent, trimmed.
        public var headers: [(name: String, value: String)]
        public var contentLength: Int
        public var expectsContinue: Bool

        public static func == (lhs: RequestHead, rhs: RequestHead) -> Bool {
            lhs.method == rhs.method && lhs.target == rhs.target && lhs.contentLength == rhs.contentLength
                && lhs.expectsContinue == rhs.expectsContinue && lhs.headers.map(\.name) == rhs.headers.map(\.name)
                && lhs.headers.map(\.value) == rhs.headers.map(\.value)
        }

        public func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }
    }

    public static let allowedMethods: Set<String> = ["GET", "POST"]

    /// The request line and headers, from the bytes before the blank line.
    public static func parseHead(_ bytes: Data, limits: Limits = Limits()) throws -> RequestHead {
        guard bytes.count <= limits.maxHeaderBytes else { throw Refusal(431, "the request head is too large") }
        guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
            throw Refusal(400, "the request head is not text")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            throw Refusal(400, "the request line is not METHOD TARGET HTTP/1.x")
        }
        let method = requestLine[0]
        guard allowedMethods.contains(method) else { throw Refusal(405, "only GET and POST are forwarded") }
        let target = requestLine[1]
        guard target.utf8.count <= limits.maxTargetBytes else { throw Refusal(414, "the target is too long") }

        var headers: [(name: String, value: String)] = []
        var contentLength: Int?
        var expectsContinue = false
        for line in lines where !line.isEmpty {
            // No line folding: a continuation line has no name, and a name with a space or no colon is not a header.
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw Refusal(400, "a header is malformed")
            }
            let name = String(line[..<colon])
            guard name.range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+\z"#, options: .regularExpression) != nil else {
                throw Refusal(400, "a header name is not a token")
            }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            let lower = name.lowercased()
            switch lower {
            case "content-length":
                guard contentLength == nil, value.range(of: #"^[0-9]{1,12}\z"#, options: .regularExpression) != nil,
                    let n = Int(value)
                else { throw Refusal(400, "Content-Length is missing, repeated or not a number") }
                contentLength = n
            case "transfer-encoding":
                throw Refusal(411, "a chunked request body is not accepted; send Content-Length")
            case "expect":
                guard value.lowercased() == "100-continue" else { throw Refusal(417, "only Expect: 100-continue is understood") }
                expectsContinue = true
            default: break
            }
            headers.append((lower, value))
        }
        let length = contentLength ?? 0
        if method == "GET", length != 0 { throw Refusal(400, "a GET has no body here") }
        guard length <= limits.maxBodyBytes else { throw Refusal(413, "the request body is too large") }
        return RequestHead(
            method: method, target: target, headers: headers, contentLength: length, expectsContinue: expectsContinue)
    }

    /// The upstream URL for a target, or why not. The target must be a path under the base path (`/v1/…`): no absolute form, no query
    /// before the path, no dot segments, no empty segment, no backslash, and no percent-encoded dot, slash or backslash, whatever the
    /// upstream would make of them. The host, scheme and port are the upstream's own and never come from the client.
    public static func upstreamURL(base: URL, target: String) throws -> URL {
        guard target.hasPrefix("/"), !target.hasPrefix("//") else { throw Refusal(400, "the target must be a path") }
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split[0])
        let query = split.count > 1 ? String(split[1]) : nil
        let basePath = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        guard path == basePath || path.hasPrefix(basePath + "/") else {
            throw Refusal(403, "only paths under \(basePath.isEmpty ? "/" : basePath) are forwarded")
        }
        let lowered = path.lowercased()
        let bad =
            path.contains("\\") || path.contains("//") || lowered.contains("%2e") || lowered.contains("%2f")
            || lowered.contains("%5c") || lowered.contains("%00")
            || path.unicodeScalars.contains { $0.value < 0x21 || $0.value == 0x7F }
            || path.split(separator: "/").contains { $0 == "." || $0 == ".." }
        guard !bad else { throw Refusal(403, "the path is not one the forwarder passes on") }
        // Foundation's `percentEncoded…` setters raise on a string that is not valid percent-encoding, which would end the process: only
        // RFC 3986 path and query characters and `%XX` get that far.
        guard isEncoded(path, allowing: "") else { throw Refusal(400, "the path is not valid percent-encoded text") }
        if let query, !isEncoded(query, allowing: "?") { throw Refusal(400, "the query is not valid percent-encoded text") }
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw Refusal(500, "the upstream is not a URL")
        }
        parts.percentEncodedPath = path
        parts.percentEncodedQuery = query
        guard let url = parts.url else { throw Refusal(400, "the target is not a URL") }
        return url
    }

    /// Only unreserved and sub-delimiter characters, `:`, `@`, `/` (and `allowing`), and `%` followed by two hex digits.
    static func isEncoded(_ text: String, allowing extra: String) -> Bool {
        let allowed = "A-Za-z0-9._~!$&'()*+,;=:@/\\-" + NSRegularExpression.escapedPattern(for: extra)
        let pattern = "^(?:[\(allowed)]|%[0-9A-Fa-f]{2})*\\z"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The headers passed upstream: the ones a model call needs, by name. The client's `Authorization`, cookies and anything that names
    /// another host or proxy are dropped; `Authorization` is set here from the key.
    public static func upstreamHeaders(for head: RequestHead, key: String) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in head.headers where ["content-type", "accept"].contains(name) {
            guard !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) else { continue }
            out[name] = value
        }
        out["authorization"] = "Bearer \(key)"
        return out
    }

    /// The headers of the upstream answer that are passed back. Hop-by-hop headers, length and encoding (the body is re-framed and the
    /// client's library has already decoded it), cookies and anything that could carry a credential are not.
    public static func passesBack(_ name: String) -> Bool {
        let drop: Set<String> = [
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding",
            "upgrade",
            "content-length", "content-encoding", "set-cookie", "set-cookie2", "www-authenticate", "authorization", "location",
        ]
        return !drop.contains(name.lowercased())
    }

    /// An answer's headers as they are passed back: only the ones that may be, with the exact key removed from every value, for a
    /// success as for an error.
    public static func cleanedHeaders(_ headers: [(String, String)], key: String) -> [(String, String)] {
        headers.compactMap { name, value in
            guard passesBack(name), !value.contains("\r"), !value.contains("\n") else { return nil }
            return (name, String(decoding: redact(Data(value.utf8), key: key), as: UTF8.self))
        }
    }

    /// `text` with the exact key removed. A key under 8 characters is left alone: it is not one, and removing it would only damage words.
    public static func redact(_ text: Data, key: String) -> Data {
        guard key.utf8.count >= 8, let keyData = key.data(using: .utf8), !keyData.isEmpty else { return text }
        var out = Data()
        var rest = text[...]
        while let found = rest.range(of: keyData) {
            out.append(rest[..<found.lowerBound])
            out.append(Data("[key removed]".utf8))
            rest = rest[found.upperBound...]
        }
        out.append(rest)
        return out
    }

    public static func reason(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 414: "URI Too Long"
        case 417: "Expectation Failed"
        case 431: "Request Header Fields Too Large"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 200..<300: "OK"
        case 300..<400: "Redirect"
        case 400..<500: "Client Error"
        default: "Error"
        }
    }

    /// An error body in the shape OpenAI-compatible clients read, so OpenCode reports the message and not a parse failure.
    public static func errorBody(_ message: String) -> Data {
        let object: [String: Any] = ["error": ["message": message, "type": "workbench_forwarder"]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}
