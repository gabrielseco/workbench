import Foundation

/// One message of a chat: what the person said, or what the agent answered.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var text: String
    public var seq: Int
    /// The screenshots the person sent with it, by the names they are kept under (`3.png`), in the order sent. Empty for the agent's.
    public var images: [String] = []

    public init(role: Role, text: String, seq: Int, images: [String] = []) {
        (self.role, self.text, self.seq, self.images) = (role, text, seq, images)
    }
}

/// A chat thread as its log says it (P22 slice 6): the conversation, how many turns it had and what they cost. Nil on a thread
/// that never had a `chat.message`, so every older log derives as before.
public struct ChatState: Sendable, Equatable {
    public var messages: [ChatMessage] = []
    /// Turns that ended, however they ended.
    public var turns = 0
    /// How the latest ended turn ended: `ok`, `stopped`, `timeout` or `failed`, or `interrupted` when a killed process was recovered.
    public var lastEnd: String?
    public var costUSD: Double = 0
    /// A turn ended without a cost: the total is then not known, and is never shown as a sum.
    public var costUnknown = false
    /// A user message with no `chat.ended` yet: a turn is going, or its process died and nothing has recovered it.
    public var open = false

    public init() {}

    /// How the log wrote an end: `ok`, or the reason words the writer uses.
    static func end(_ event: Event) -> String {
        if event.data["ok"] == true { return "ok" }
        let reason = event.data["reason"]?.stringValue ?? ""
        switch reason {
        case "stopped", "timeout", "interrupted": return reason
        default: return "failed"
        }
    }

    mutating func apply(_ event: Event) {
        switch event.kind {
        case .chatMessage:
            guard let role = event.data["role"]?.stringValue.flatMap(ChatMessage.Role.init(rawValue:)),
                let text = event.data["text"]?.stringValue
            else { return }
            // A name that is not one this feature writes is dropped: a log edited by hand cannot point a read at another file.
            var images: [String] = []
            if role == .user, case .array(let names)? = event.data["images"] {
                images = names.compactMap { $0.stringValue }.filter { GoalAttachments.number(inStoredName: $0) != nil }
            }
            messages.append(ChatMessage(role: role, text: text, seq: event.seq, images: images))
            if role == .user { open = true }
        case .chatEnded:
            open = false
            turns += 1
            lastEnd = Self.end(event)
            switch event.data["cost_usd"] {
            case .double(let d)?: costUSD += d
            case .int(let i)?: costUSD += Double(i)
            default: costUnknown = true
            }
        default:
            break
        }
    }
}
