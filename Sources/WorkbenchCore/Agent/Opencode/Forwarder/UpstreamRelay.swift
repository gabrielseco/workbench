import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Turns one upstream answer into the bytes for one client, and hands them to that client's own connection thread through a bounded
/// outbox. **It never touches a socket**: writing from the session's one serial delegate queue stalled every other stream behind a
/// client that had stopped reading, and let a callback write to a descriptor its connection had already closed (and the system had
/// given to another). Now the connection thread, which owns the descriptor, is the only writer, and a client that does not read
/// fills the outbox and is dropped.
///
/// A successful answer is streamed frame by frame as it arrives; any other is held (bounded), cleaned of the key and sent whole; a
/// redirect is never followed and is told to the client as a gateway error, because following it would send the key to a host nobody
/// configured. The key is removed from every header value, on every status.
final class UpstreamRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    final class Exchange: @unchecked Sendable {
        enum State { case waiting, streaming, buffering }
        /// Signalled when there is something to write or the answer is over.
        let ready = DispatchSemaphore(value: 0)

        // Touched on the delegate queue only.
        var state = State.waiting
        var status = 0
        var headers: [(String, String)] = []
        var body = Data()
        /// The delegate has asked for the task to be cancelled: once is enough, and every later chunk of a flood would only ask again.
        var cancelAsked = false

        private let lock = NSLock()
        private var outbox: [Data] = []
        private var queued = 0
        private var isDone = false
        private var isOverflowed = false

        /// False when the client has fallen too far behind to be kept: nothing was added.
        func enqueue(_ data: Data, limit: Int) -> Bool {
            let kept = lock.withLock { () -> Bool in
                guard !isOverflowed, queued + data.count <= limit else {
                    isOverflowed = true
                    return false
                }
                outbox.append(data)
                queued += data.count
                return true
            }
            ready.signal()
            return kept
        }

        /// The client was dropped for falling too far behind: whoever is writing to it should stop.
        var overflowed: Bool { lock.withLock { isOverflowed } }

        func finish() {
            lock.withLock { isDone = true }
            ready.signal()
        }

        /// What is waiting to be written, and whether the answer is over.
        struct Batch {
            var frames: [Data]
            var done: Bool
        }

        func take() -> Batch {
            lock.withLock {
                defer {
                    outbox = []
                    queued = 0
                }
                return Batch(frames: outbox, done: isDone)
            }
        }
    }

    private let limits: ForwardPolicy.Limits
    private let key: String
    private let lock = NSLock()
    private var exchanges: [Int: Exchange] = [:]

    init(limits: ForwardPolicy.Limits, key: String) {
        self.limits = limits
        self.key = key
    }

    func register(_ exchange: Exchange, for task: URLSessionTask) {
        lock.withLock { exchanges[task.taskIdentifier] = exchange }
    }

    func unregister(_ task: URLSessionTask) {
        lock.withLock { _ = exchanges.removeValue(forKey: task.taskIdentifier) }
    }

    private func exchange(for task: URLSessionTask) -> Exchange? {
        lock.withLock { exchanges[task.taskIdentifier] }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let exchange = exchange(for: dataTask), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        exchange.status = http.statusCode
        exchange.headers = ForwardPolicy.cleanedHeaders(
            http.allHeaderFields.compactMap { name, value in
                guard let name = name as? String, let value = value as? String else { return nil }
                return (name, value)
            }, key: key)
        guard (200..<300).contains(http.statusCode) else {
            exchange.state = .buffering
            completionHandler(.allow)
            return
        }
        var head = "HTTP/1.1 \(http.statusCode) \(ForwardPolicy.reason(http.statusCode))\r\n"
        for (name, value) in exchange.headers { head += "\(name): \(value)\r\n" }
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        exchange.state = .streaming
        completionHandler(exchange.enqueue(Data(head.utf8), limit: limits.maxQueuedBytes) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask) else { return }
        switch exchange.state {
        case .streaming:
            let frame = Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8)
            if !exchange.enqueue(frame, limit: limits.maxQueuedBytes), !exchange.cancelAsked {
                exchange.cancelAsked = true
                dataTask.cancel()
            }
        case .buffering:
            let room = limits.maxErrorBodyBytes - exchange.body.count
            if room > 0 { exchange.body.append(data.prefix(room)) }
        case .waiting:
            break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchange(for: task) else { return }
        defer { exchange.finish() }
        let limit = limits.maxQueuedBytes
        switch exchange.state {
        case .streaming:
            // A clean end is the terminating chunk. After an error nothing is sent: the client sees the connection drop mid-body,
            // which its library reports as a failed request, not as a complete answer that is really a part of one.
            if error == nil { _ = exchange.enqueue(Data("0\r\n\r\n".utf8), limit: limit) }
        case .buffering:
            if (300..<400).contains(exchange.status) {
                let message = "the gateway answered with a redirect, which the forwarder does not follow"
                _ = exchange.enqueue(Self.response(502, ForwardPolicy.errorBody(message)), limit: limit)
            } else {
                _ = exchange.enqueue(buffered(exchange), limit: limit)
            }
        case .waiting:
            if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
            let timedOut = (error as? URLError)?.code == .timedOut
            let message = timedOut ? "the gateway did not answer in time" : "the gateway could not be reached"
            let status = timedOut ? 504 : 502
            _ = exchange.enqueue(Self.response(status, ForwardPolicy.errorBody(message)), limit: limit)
        }
    }

    /// A non-2xx answer: what the gateway said, with the key removed (an authentication error may echo what it was given).
    private func buffered(_ exchange: Exchange) -> Data {
        let body = ForwardPolicy.redact(exchange.body, key: key)
        var head = "HTTP/1.1 \(exchange.status) \(ForwardPolicy.reason(exchange.status))\r\n"
        for (name, value) in exchange.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// A complete JSON answer of the forwarder's own.
    static func response(_ status: Int, _ body: Data) -> Data {
        ForwarderSocket.responseBytes(status: status, body: body)
    }
}
