import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Carries one upstream answer to one client socket. A successful answer is streamed chunk by chunk as it arrives; any other is held
/// (bounded), cleaned of the key and sent whole; a redirect is never followed and is told to the client as a gateway error, because
/// following it would send the key to a host nobody configured.
///
/// All of an exchange's state is touched on the session's one serial delegate queue, then read by the connection's thread after
/// `finished` is signalled.
final class UpstreamRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    final class Exchange: @unchecked Sendable {
        enum State { case waiting, streaming, buffering }
        let client: Int32
        let finished = DispatchSemaphore(value: 0)
        var state = State.waiting
        var status = 0
        var headers: [(String, String)] = []
        var body = Data()
        var truncated = false

        init(client: Int32) { self.client = client }
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
        exchange.headers = http.allHeaderFields.compactMap { name, value in
            guard let name = name as? String, let value = value as? String, ForwardPolicy.passesBack(name) else { return nil }
            return (name, value)
        }
        guard (200..<300).contains(http.statusCode) else {
            exchange.state = .buffering
            completionHandler(.allow)
            return
        }
        var head = "HTTP/1.1 \(http.statusCode) \(ForwardPolicy.reason(http.statusCode))\r\n"
        for (name, value) in exchange.headers where !value.contains("\r") && !value.contains("\n") {
            head += "\(name): \(value)\r\n"
        }
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        guard ForwarderSocket.deliver(exchange.client, Data(head.utf8)) else {
            completionHandler(.cancel)
            return
        }
        exchange.state = .streaming
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask) else { return }
        switch exchange.state {
        case .streaming:
            let frame = Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8)
            if !ForwarderSocket.deliver(exchange.client, frame) { dataTask.cancel() }
        case .buffering:
            let room = limits.maxErrorBodyBytes - exchange.body.count
            if data.count > room { exchange.truncated = true }
            if room > 0 { exchange.body.append(data.prefix(room)) }
        case .waiting:
            break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchange(for: task) else { return }
        defer { exchange.finished.signal() }
        switch exchange.state {
        case .streaming:
            // A clean end is the terminating chunk. After an error nothing is sent: the client sees the connection drop mid-body,
            // which its library reports as a failed request, not as a complete answer that is really a part of one.
            if error == nil { ForwarderSocket.deliver(exchange.client, Data("0\r\n\r\n".utf8)) }
        case .buffering:
            if (300..<400).contains(exchange.status) {
                ForwarderSocket.respond(
                    exchange.client, status: 502,
                    body: ForwardPolicy.errorBody("the gateway answered with a redirect, which the forwarder does not follow"))
            } else {
                sendBuffered(exchange)
            }
        case .waiting:
            if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
            let timedOut = (error as? URLError)?.code == .timedOut
            ForwarderSocket.respond(
                exchange.client, status: timedOut ? 504 : 502,
                body: ForwardPolicy.errorBody(
                    timedOut ? "the gateway did not answer in time" : "the gateway could not be reached"))
        }
    }

    /// A non-2xx answer: what the gateway said, with the key removed (an authentication error may echo what it was given).
    private func sendBuffered(_ exchange: Exchange) {
        let body = ForwardPolicy.redact(exchange.body, key: key)
        var head = "HTTP/1.1 \(exchange.status) \(ForwardPolicy.reason(exchange.status))\r\n"
        for (name, value) in exchange.headers where !value.contains("\r") && !value.contains("\n") {
            head += "\(name): \(String(data: ForwardPolicy.redact(Data(value.utf8), key: key), encoding: .utf8) ?? "")\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        ForwarderSocket.deliver(exchange.client, Data(head.utf8) + body)
    }
}
