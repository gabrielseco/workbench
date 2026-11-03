import SwiftUI
import WorkbenchCore

/// What the chat's composer and its buttons allow, from the chat's log and what the app is doing. Pure, so the rules are tested
/// without a window.
struct ChatComposerState: Equatable {
    var text = ""
    /// A turn is going: the log shows a message with no end yet, or this app holds the turn (a new chat the log does not show yet).
    var replying = false
    /// The goal agent is drafting a goal from this chat.
    var drafting = false
    /// The agent has answered at least once: there is a conversation to make a goal from.
    var hasExchange = false
    /// The chat was ended (abandoned or discarded): it takes nothing more.
    var ended = false

    init(snapshot: ThreadSnapshot, replying: Bool, drafting: Bool, text: String) {
        let chat = snapshot.state.chat
        self.text = text
        self.replying = replying || chat?.open == true
        self.drafting = drafting
        hasExchange = chat?.messages.contains { $0.role == .assistant } == true
        ended = snapshot.state.decision != nil
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var busy: Bool { replying || drafting }
    var canType: Bool { !ended && !busy }
    var canSend: Bool { !ended && !busy && !isBlank }
    var canMakeGoal: Bool { !ended && !busy && hasExchange }

    /// One line of text high, growing a line at a time to six: the text box is not left to take what it is given.
    static func editorHeight(for text: String) -> CGFloat {
        let lines = min(6, max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count))
        return 30 + CGFloat(lines - 1) * 20
    }

    enum Key: Equatable { case send, newline }
    /// Return sends; Shift-Return (or Option-Return) goes on a new line.
    static func key(shift: Bool, option: Bool) -> Key { shift || option ? .newline : .send }
}

/// A chat thread's screen is the conversation, not the feed: it has no goal, no run and nothing to accept.
extension ThreadSnapshot {
    var showsChat: Bool { state.isChat && approval == nil }
}

/// The messages of a chat, in order, and the row that says the agent is replying.
struct ChatRows: View {
    var snapshot: ThreadSnapshot
    var store: ProjectStore

    var body: some View {
        let messages = snapshot.state.chat?.messages ?? []
        if messages.isEmpty {
            Text("Say what you are thinking about. Nothing runs and nothing is written to the repository.")
                .font(.callout).foregroundStyle(.secondary)
        }
        // What the log says about itself (a damaged line, a cut tail) is part of the conversation too.
        ForEach(snapshot.feed.filter(\.isNotice)) { FeedRow(item: $0) }
        ForEach(messages, id: \.seq) { ChatMessageRow(message: $0) }
        if ChatComposerState(snapshot: snapshot, replying: store.replyingHere, drafting: store.drafting, text: "").replying {
            ReplyingRow(store: store)
        }
    }
}

struct ChatMessageRow: View {
    var message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You").font(.caption).foregroundStyle(.secondary)
                    Text(message.text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Goal agent").font(.caption).foregroundStyle(.secondary)
                Text(message.text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

struct ReplyingRow: View {
    var store: ProjectStore

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Replying…").font(.callout).foregroundStyle(Theme.blue)
            Spacer()
            Button("Stop") { store.stopChat() }.buttonStyle(.borderless).accessibilityLabel("Stop the reply")
        }
        .accessibilityElement(children: .contain)
    }
}

/// The foot of a chat: what the last action said, the text box, and the two buttons.
struct ChatComposer: View {
    var snapshot: ThreadSnapshot
    var store: ProjectStore
    @FocusState private var focused: Bool

    private var state: ChatComposerState {
        ChatComposerState(
            snapshot: snapshot, replying: store.replyingHere, drafting: store.drafting, text: store.chatDraft)
    }

    var body: some View {
        let state = state
        VStack(alignment: .leading, spacing: 8) {
            if let said = store.actionError {
                // A refusal (too long, no goal agent, a draft that did not come out) asks the person to change something: amber.
                MessageRow(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, text: said)
            }
            MessageRows(error: nil, note: store.actionNote, notice: store.notice, handoff: nil)
            if state.ended {
                Text("This chat has ended.").font(.callout).foregroundStyle(.secondary)
            } else {
                editor(state)
                HStack(spacing: 10) {
                    if store.drafting {
                        ProgressView().controlSize(.small)
                        Text("Drafting the goal…").font(.callout).foregroundStyle(Theme.blue)
                        Button("Stop") { store.stopDrafting() }.buttonStyle(.borderless)
                    } else {
                        Button("Make this a goal") { Task { await store.makeChatGoal() } }
                            .disabled(!state.canMakeGoal)
                            .help(
                                state.hasExchange
                                    ? "The goal agent drafts a goal from this conversation; you read it and approve it next"
                                    : "Available once the agent has answered")
                    }
                    Spacer()
                    Button("Send") { send() }
                        .buttonStyle(.borderedProminent).disabled(!state.canSend)
                        .accessibilityLabel("Send the message")
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
    }

    private func editor(_ state: ChatComposerState) -> some View {
        TextEditor(text: Binding(get: { store.chatDraft }, set: { store.chatDraft = $0 }))
            .font(.body).scrollContentBackground(.hidden).focused($focused)
            .frame(height: ChatComposerState.editorHeight(for: state.text)).padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .disabled(!state.canType)
            .opacity(state.replying ? 0.6 : 1)
            .overlay(alignment: .topLeading) {
                if state.isBlank {
                    Text(state.busy ? "Waiting for the agent…" : "Reply…  (Return sends, Shift-Return adds a line)")
                        .foregroundStyle(.tertiary).padding(.leading, 11).padding(.top, 6).allowsHitTesting(false)
                }
            }
            .onKeyPress(.return, phases: .down) { press in
                let key = ChatComposerState.key(
                    shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option))
                guard key == .send else { return .ignored }
                if state.canSend { send() }
                return .handled
            }
            .accessibilityLabel("Message")
            // A box that takes no typing does not keep the caret.
            .onChange(of: state.canType) { focused = state.canType }
            .task {
                try? await Task.sleep(for: .milliseconds(40))
                focused = state.canType
            }
    }

    private func send() { Task { await store.sendChat() } }
}

extension FeedItem {
    var isNotice: Bool {
        if case .notice = kind { return true }
        return false
    }
}
