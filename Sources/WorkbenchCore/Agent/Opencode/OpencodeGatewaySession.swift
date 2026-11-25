import Foundation

/// A forwarder and the OpenCode adapter built to use it, for one turn. Every OpenCode turn, coding or read-only, goes through one: the real
/// key lives in the forwarder and the child gets a placeholder, so a turn whose output ends up in the log (a judge's verdict, a plan, a
/// description) cannot be made to print the key, however hostile the diff or the page it was asked to read. The caller stops the session
/// on every way out of the turn (`defer`); `stop()` is safe to call twice and never waits.
public final class OpencodeGatewaySession: @unchecked Sendable {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    public let provider: OpencodeProvider
    private let forwarder: LoopbackForwarder

    private init(provider: OpencodeProvider, forwarder: LoopbackForwarder) {
        self.provider = provider
        self.forwarder = forwarder
    }

    deinit { forwarder.stop() }

    public func stop() { forwarder.stop() }

    /// The key from `environment` for `gateway`, or why OpenCode cannot reach it: the key's variable unset, or a key too short to be kept
    /// out of an answer that echoes it. Nothing is started.
    public static func key(for gateway: OpencodeProvider.Gateway, environment: [String: String]) throws -> String {
        let name = gateway.apiKeyVariable
        guard let key = environment[name], !key.isEmpty else {
            throw Failure("opencode reads its gateway key from $\(name), which is not set")
        }
        guard key.utf8.count >= ForwardPolicy.minimumKeyLength else {
            let length = ForwardPolicy.minimumKeyLength
            throw Failure(
                "the gateway key in $\(name) is shorter than \(length) characters, so it could not be kept out of an answer that "
                    + "echoes it; use a longer key")
        }
        return key
    }

    /// The configured gateway and its key, or why OpenCode cannot reach its gateway (no `[providers.opencode]`, or `key(for:)`).
    public static func gateway(
        config: Config, environment: [String: String]
    ) throws -> (gateway: OpencodeProvider.Gateway, key: String) {
        guard let gateway = config.agents.opencode else {
            throw Failure("opencode needs [providers.opencode] with a base_url")
        }
        return (gateway, try key(for: gateway, environment: environment))
    }

    public static func start(config: Config, environment: [String: String]) throws -> OpencodeGatewaySession {
        guard let gateway = config.agents.opencode else {
            throw Failure("opencode needs [providers.opencode] with a base_url")
        }
        return try start(gateway: gateway, executable: config.executable(for: .opencode), environment: environment)
    }

    /// Starts a forwarder to `gateway` and the adapter that talks to it.
    public static func start(
        gateway: OpencodeProvider.Gateway, executable: String, environment: [String: String]
    ) throws -> OpencodeGatewaySession {
        let key = try key(for: gateway, environment: environment)
        guard let upstream = URL(string: gateway.baseURL) else { throw Failure("[providers.opencode] base_url is not a URL") }
        do {
            let forwarder = try LoopbackForwarder(LoopbackForwarder.Configuration(upstream: upstream, apiKey: key))
            let base = try forwarder.start()
            let provider = OpencodeProvider(
                executable: executable, gateway: gateway, forwarder: OpencodeProvider.Forwarder(baseURL: base.absoluteString))
            return OpencodeGatewaySession(provider: provider, forwarder: forwarder)
        } catch {
            throw Failure("the gateway forwarder could not start: \(error)")
        }
    }
}

extension OpencodeGatewaySession {
    /// For a read-only turn whose provider was built elsewhere (goal drafting, the chat, a task edit): the provider to run and the session
    /// to stop when the turn is over. Anything but an OpenCode provider without a forwarder is returned as it is, with no session.
    public static func around(
        _ provider: any AgentProvider, environment: [String: String]
    ) throws -> (provider: any AgentProvider, session: OpencodeGatewaySession?) {
        guard let opencode = provider as? OpencodeProvider, opencode.forwarder == nil else { return (provider, nil) }
        let session = try start(gateway: opencode.gateway, executable: opencode.executable, environment: environment)
        return (session.provider, session)
    }

    /// Why text from a turn is no answer although there is some: the provider did not report the turn as finished (OpenCode's stream
    /// with no final stop). Nil when it finished, or when there is no text to doubt.
    public static func unfinished(_ completion: AgentCompletion, name: String) -> String? {
        guard completion.summary != nil, completion.provider != .succeeded else { return nil }
        return "\(name) did not finish its turn, so there is no answer"
    }
}
