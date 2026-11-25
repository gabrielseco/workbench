import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A local HTTP server that carries one sandboxed OpenCode turn's model traffic to the real gateway and adds the key on the way, so the
/// sandbox needs no network but loopback (seatbelt cannot allow a host) and the key is never in an environment a shell can print.
///
/// - Binds `127.0.0.1` on an ephemeral port; `start()` returns the base URL the client is told, with the upstream's own path (`/v1`).
/// - **One upstream, fixed:** scheme, host and port come from the configuration, never from a request. Only `GET` and `POST` on paths
///   under the base path are passed on (`ForwardPolicy`); a redirect is never followed, so the key cannot be sent anywhere else.
/// - The client's `Authorization` is dropped and the real key set; an upstream error body is cleaned of the key before the client sees it.
/// - A successful answer is streamed as it arrives (the model's tokens are server-sent events); an error is buffered, bounded, cleaned.
/// - One request per connection (`Connection: close`), a cap on live connections, a read timeout, a write timeout, an idle timeout
///   upstream, and bounded head, body and error sizes. A client that goes away ends the upstream request.
/// - `stop()` ends everything, is idempotent and never waits; the listener closes as soon as its thread sees the wake-up.
///
/// It logs nothing and its description names no key.
public final class LoopbackForwarder: @unchecked Sendable {
    public struct Configuration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public var upstream: URL
        public var apiKey: String
        public var limits = ForwardPolicy.Limits()
        public var maxConnections = 16
        /// How long a client may take to send its request.
        public var clientReadTimeout: TimeInterval = 30
        /// The longest the upstream may be silent. A model that thinks for a while is not silent: it streams.
        public var upstreamIdleTimeout: TimeInterval = 300
        /// The longest one request may take in all.
        public var maxRequestDuration: TimeInterval = 3600

        public init(upstream: URL, apiKey: String) {
            self.upstream = upstream
            self.apiKey = apiKey
        }

        public var description: String { "forwarder configuration for \(upstream.host ?? "?")" }
        public var debugDescription: String { description }
    }

    public struct StartError: Error, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    private let configuration: Configuration
    private let relay: UpstreamRelay
    private let lock = NSLock()
    private var wakeWriter: Int32 = -1
    private var stopped = false
    private var started = false
    private var live = 0
    private var session: URLSession?

    public init(_ configuration: Configuration) throws {
        guard let scheme = configuration.upstream.scheme, ["http", "https"].contains(scheme),
            let host = configuration.upstream.host, !host.isEmpty, configuration.upstream.user == nil,
            configuration.upstream.password == nil
        else { throw StartError("the upstream must be an http or https URL with a host and no credentials") }
        guard configuration.apiKey.utf8.count >= ForwardPolicy.minimumKeyLength else {
            let why = "so it could not be removed from an answer that echoes it"
            throw StartError("the gateway key is shorter than \(ForwardPolicy.minimumKeyLength) characters, \(why)")
        }
        self.configuration = configuration
        self.relay = UpstreamRelay(limits: configuration.limits, key: configuration.apiKey)
    }

    deinit { stop() }

    public var isRunning: Bool { lock.withLock { started && !stopped } }

    /// Connections being served now. For tests and for whoever starts the forwarder to check it has let go.
    var liveConnectionCount: Int { lock.withLock { live } }

    private var isStopped: Bool { lock.withLock { stopped } }

    #if canImport(Darwin)
        private static let streamType = SOCK_STREAM
    #else
        private static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    /// Starts listening. The URL is what OpenCode's `baseURL` becomes.
    public func start() throws -> URL {
        try lock.withLock {
            guard !started else { throw StartError("the forwarder is already started") }
            let (listener, port) = try Self.bindLoopback()
            var pipes: [Int32] = [-1, -1]
            guard pipe(&pipes) == 0 else {
                close(listener)
                throw StartError("no wake-up pipe")
            }
            started = true
            wakeWriter = pipes[1]
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.upstreamIdleTimeout
            config.timeoutIntervalForResource = configuration.maxRequestDuration
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            // Its callbacks must not wait behind whatever else the process is running at the default priority: with that bucket's
            // threads all blocked (a busy process, or a test run), every forwarder stalled behind them.
            queue.qualityOfService = .userInitiated
            session = URLSession(configuration: config, delegate: relay, delegateQueue: queue)
            let reader = pipes[0]
            let thread = Thread { [self] in acceptLoop(listener: listener, wake: reader) }
            thread.name = "workbench.forwarder.accept"
            thread.start()
            var base = URLComponents()
            base.scheme = "http"
            base.host = "127.0.0.1"
            base.port = port
            // As written (encoded): `URL.path` is decoded, and the setter raises on text that is not valid percent-encoding.
            let written = URLComponents(url: configuration.upstream, resolvingAgainstBaseURL: false)
            base.percentEncodedPath = written?.percentEncodedPath ?? ""
            guard let url = base.url else { throw StartError("the base URL could not be made") }
            return url
        }
    }

    /// Ends the listener, every connection and every upstream request. Safe to call again, and from anywhere.
    public func stop() {
        let (writer, active): (Int32, URLSession?) = lock.withLock {
            guard started, !stopped else { return (-1, nil) }
            stopped = true
            defer { wakeWriter = -1 }
            return (wakeWriter, session)
        }
        if writer >= 0 {
            var byte: UInt8 = 1
            _ = write(writer, &byte, 1)
            close(writer)
        }
        active?.invalidateAndCancel()
    }

    private static func bindLoopback() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw StartError("no socket: errno \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw StartError("could not listen on loopback: errno \(code)")
        }
        var length = size
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            throw StartError("could not read the port")
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }

    // MARK: The accept loop and one connection

    private func acceptLoop(listener: Int32, wake: Int32) {
        defer {
            close(listener)
            close(wake)
        }
        while true {
            var fds = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
            ]
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 || isStopped { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { continue }
                return
            }
            let admitted: Bool = lock.withLock {
                guard live < configuration.maxConnections, !stopped else { return false }
                live += 1
                return true
            }
            guard admitted else {
                close(client)
                continue
            }
            let thread = Thread { [self] in
                serve(client)
                lock.withLock { live -= 1 }
            }
            thread.name = "workbench.forwarder.connection"
            thread.start()
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        ForwarderSocket.configure(client)
        do {
            let (head, leftover) = try readHead(client)
            let upstream = try ForwardPolicy.upstreamURL(base: configuration.upstream, target: head.target)
            if head.expectsContinue { ForwarderSocket.deliver(client, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
            let body = try readBody(client, head: head, leftover: leftover)
            var request = URLRequest(url: upstream, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = head.method
            request.httpShouldHandleCookies = false
            for (name, value) in ForwardPolicy.upstreamHeaders(for: head, key: configuration.apiKey) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            if head.method == "POST" { request.httpBody = body }
            forward(request, to: client)
        } catch let refusal as ForwardPolicy.Refusal {
            ForwarderSocket.respond(client, status: refusal.status, body: ForwardPolicy.errorBody(refusal.message))
        } catch {
            ForwarderSocket.respond(client, status: 400, body: ForwardPolicy.errorBody("the request could not be read"))
        }
    }

    private func forward(_ request: URLRequest, to client: Int32) {
        guard let session = lock.withLock({ stopped ? nil : self.session }) else {
            ForwarderSocket.respond(client, status: 503, body: ForwardPolicy.errorBody("the forwarder is stopping"))
            return
        }
        let exchange = UpstreamRelay.Exchange()
        let task = session.dataTask(with: request)
        relay.register(exchange, for: task)
        defer { relay.unregister(task) }
        task.resume()
        // This thread owns the socket and is the only one that writes it. It writes what the delegate queued, and ends the upstream
        // request when the forwarder stops, the client goes away or stops reading (a write that makes no progress, or an outbox past
        // its bound). Once it has cancelled it returns at once and the caller closes the socket: the delegate never touches the
        // socket, and an exchange that is no longer registered is ignored, so nothing waits for a completion a stopped session may
        // never deliver.
        while true {
            _ = exchange.ready.wait(timeout: .now() + .milliseconds(Int(ForwarderSocket.slice)))
            let batch = exchange.take()
            for frame in batch.frames {
                let written = ForwarderSocket.deliver(
                    client, frame, stopped: { self.isStopped || exchange.overflowed },
                    timeout: self.configuration.clientReadTimeout)
                if !written {
                    task.cancel()
                    return
                }
            }
            if exchange.overflowed || (!batch.done && (isStopped || ForwarderSocket.hasHungUp(client))) {
                task.cancel()
                return
            }
            if batch.done { return }
        }
    }

    // MARK: Reading the request

    private func readHead(_ client: Int32) throws -> (ForwardPolicy.RequestHead, leftover: Data) {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        let deadline = Date().addingTimeInterval(configuration.clientReadTimeout)
        while true {
            if let end = buffer.range(of: terminator) {
                let head = try ForwardPolicy.parseHead(Data(buffer[..<end.lowerBound]), limits: configuration.limits)
                return (head, Data(buffer[end.upperBound...]))
            }
            if buffer.count > configuration.limits.maxHeaderBytes {
                throw ForwardPolicy.Refusal(431, "the request head is too large")
            }
            guard let chunk = ForwarderSocket.receive(client, deadline: deadline, stopped: { self.isStopped }) else {
                throw ForwardPolicy.Refusal(400, "the request did not arrive")
            }
            buffer.append(chunk)
        }
    }

    private func readBody(_ client: Int32, head: ForwardPolicy.RequestHead, leftover: Data) throws -> Data {
        var body = leftover
        guard body.count <= head.contentLength else { throw ForwardPolicy.Refusal(400, "more bytes than Content-Length") }
        let deadline = Date().addingTimeInterval(configuration.clientReadTimeout)
        while body.count < head.contentLength {
            guard let chunk = ForwarderSocket.receive(client, deadline: deadline, stopped: { self.isStopped }) else {
                throw ForwardPolicy.Refusal(400, "the request body did not arrive")
            }
            body.append(chunk)
        }
        guard body.count == head.contentLength else { throw ForwardPolicy.Refusal(400, "more bytes than Content-Length") }
        return body
    }
}
