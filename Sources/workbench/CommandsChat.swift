import Foundation
import WorkbenchCore

extension Commands {
    /// `chat [<name-or-id>] [--message "<text>" | --message-file <path>] [--abandon-active]`: a read-only conversation with the goal
    /// agent in a thread that has no goal. A name that is not a thread starts one; an id continues it; no message prints it.
    static func chat(_ args: [String]) async throws -> Int32 {
        var a = Arguments(args)
        let text = try a.value("--message")
        let path = try a.value("--message-file")
        let abandonActive = a.flag("--abandon-active")
        let named = a.positional()
        try a.requireEmpty()
        let usage = "usage: workbench chat [<name-or-id>] [--message \"<text>\" | --message-file <path>] [--abandon-active]"
        if text != nil && path != nil { throw CLIError.usage("give the message once, as --message or --message-file. " + usage) }
        let ctx = try await Context.load()
        guard text != nil || path != nil else { return try showChat(ctx, named) }
        guard let named else { throw CLIError.usage("say which chat, or the name of a new one. " + usage) }
        let message: String
        if let text { message = text } else if let path { message = try readMessageFile(path) } else { message = "" }

        let config: Config? =
            FileManager.default.fileExists(atPath: ctx.project.configURL.path)
            ? try Config.load(from: ctx.project.configURL) : nil
        let target = resolve(named, in: ctx)
        if let agent = config?.resolvedGoalAgent {
            let model = agent.model.map { ", \($0)" } ?? ""
            out("talking with \(agent.provider)\(model) (read-only; up to \(Int(Chat.timeout / 60)) min)...")
        }
        // Ctrl-C stops the agent instead of leaving it running on its own budget.
        let holder = RunHolder()
        let signals = installStopHandlers(what: "the chat turn") { holder.stop() }
        defer { signals.forEach { $0.cancel() } }
        let result: ChatResult
        do {
            result = try await ctx.service.chat(
                target: target, message: message, config: config, abandonActive: abandonActive, attach: { holder.attach($0) })
        } catch let error as ChatRefusal {
            throw CLIError.refused("\(error)")
        }
        let cost = result.costUSD.map { String(format: "$%.4f", $0) } ?? "cost unknown"
        if result.end == "ok", let reply = result.reply {
            out(reply)
            out("")
            out("chat \(result.id)   (\(result.provider), \(result.model ?? "default model"); \(cost))")
            out("continue: workbench chat \(result.id) --message \"...\"")
            return 0
        }
        let why = result.failure ?? result.end
        let kind: FailureKind =
            holder.isStopRequested || result.end == "stopped" ? .stopped : result.end == "timeout" ? .timedOut : .failed
        return fail(kind, "no reply (\(cost)): \(why). The message and how the turn ended are in the log of \(result.id).")
    }

    /// An id continues that thread; a name continues the open chat made under it (`g-<day>-<name>`), and otherwise starts a new one.
    static func resolve(_ named: String, in ctx: Context) -> ChatTarget {
        if FileManager.default.fileExists(atPath: ctx.project.threadDirectory(named).path) { return .existing(id: named) }
        if let active = ctx.store.activeThreadID(), active.hasSuffix("-\(named)"), ctx.store.state(of: active).isChat {
            return .existing(id: active)
        }
        return .newThread(name: named)
    }

    /// The conversation of a chat thread, or what is known of the thread if it is not one.
    private static func showChat(_ ctx: Context, _ named: String?) throws -> Int32 {
        let id = try ctx.threadIDForViewing(named)
        let state = ctx.store.state(of: id)
        guard state.isChat, let chat = state.chat else {
            throw CLIError.refused("thread \(id) is not a chat: use `workbench chat <name> --message \"...\"` to start one.")
        }
        for message in chat.messages {
            out(message.role == .user ? "you:" : "agent:")
            out(message.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  \($0)" }.joined(separator: "\n"))
            out("")
        }
        let cost = chat.costUnknown ? "cost unknown" : String(format: "$%.4f", chat.costUSD)
        let open = chat.open ? "; a turn is open (it ends on the next command)" : ""
        let last = chat.lastEnd.map { "; the last turn ended: \($0)" } ?? ""
        out("chat \(id): \(chat.turns) turn(s), \(cost)\(last)\(open)\(state.decision.map { "; \($0)" } ?? "")")
        return 0
    }

    private static func readMessageFile(_ path: String) throws -> String {
        let fd = sysOpen(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CLIError.usage("no message file at \(path)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CLIError.usage("\(path) is not a regular file")
        }
        guard info.st_size <= Chat.messageLimit else {
            throw CLIError.usage("\(path) is over \(Chat.messageLimit / 1024) KiB; shorten the message")
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: Chat.messageLimit + 1)
        return String(decoding: data, as: UTF8.self)
    }
}
