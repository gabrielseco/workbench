import AppKit
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

extension ChatMessage {
    /// Who said it, for VoiceOver: the bubbles and the avatar carry no label on screen.
    var speaker: String { role == .user ? "You" : "Goal agent" }
    /// What VoiceOver reads for the message: the speaker, then the words.
    var spoken: String { "\(speaker): \(text)" }
}

/// One message as the artboard draws it: the person's in a bubble on the right with no label, the agent's as plain text beside a small
/// avatar. Both wrap, stay selectable, and say who spoke to VoiceOver.
struct ChatMessageRow: View {
    var message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(message.text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(
                        Theme.raised,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14))
                    .frame(maxWidth: FeedLayout.userBubble, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(message.spoken)
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkle").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Theme.raised, in: Circle()).overlay(Circle().stroke(Theme.line))
                    .padding(.top, 1)
                Text(message.text).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: FeedLayout.agentText, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(message.spoken)
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
/// The composer's Send button: a 30 pt rounded square with an up arrow, dimmed while there is nothing to send.
struct ComposerSendButton: View {
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up").font(.callout.weight(.semibold)).frame(width: 30, height: 30)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel("Send the message").help("Sends the message (Return)")
    }
}

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
        VStack(alignment: .leading, spacing: 12) {
            if let said = store.actionError {
                // A refusal (too long, no goal agent, a draft that did not come out) asks the person to change something: amber.
                MessageRow(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, text: said)
            }
            MessageRows(error: nil, note: store.actionNote, notice: store.notice, handoff: nil)
            if state.ended {
                Text("This chat has ended.").font(.callout).foregroundStyle(.secondary)
            } else {
                panel(state)
                footer(state)
            }
        }
        .frame(maxWidth: FeedLayout.maxColumn)
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 16).frame(maxWidth: .infinity)
    }

    /// The composer: a rounded panel with the text box and a square arrow-up button inside it, as the artboard draws it.
    private func panel(_ state: ChatComposerState) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            editor(state)
            ComposerSendButton(enabled: state.canSend) { send() }
        }
        .padding(.leading, 14).padding([.vertical, .trailing], 8).frame(minHeight: 46)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    /// Under the panel: what a chat is, and the one prominent button.
    private func footer(_ state: ChatComposerState) -> some View {
        HStack(spacing: 10) {
            Circle().strokeBorder(Theme.grey, lineWidth: 1.5).frame(width: 9, height: 9).accessibilityHidden(true)
            Text("Chat only. No worktree, no run, no cost.").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if store.drafting {
                ProgressView().controlSize(.small)
                Text("Drafting the goal…").font(.callout).foregroundStyle(Theme.blue)
                Button("Stop") { store.stopDrafting() }.buttonStyle(.borderless)
            } else {
                Button { Task { await store.makeChatGoal() } } label: {
                    HStack(spacing: 6) {
                        Text("Make this a goal")
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderedProminent).disabled(!state.canMakeGoal)
                .accessibilityLabel("Make this a goal")
                .help(
                    state.hasExchange
                        ? "The goal agent drafts a goal from this conversation; you read it and approve it next"
                        : "Available once the agent has answered")
            }
        }
    }

    private func editor(_ state: ChatComposerState) -> some View {
        TextEditor(text: Binding(get: { store.chatDraft }, set: { store.chatDraft = $0 }))
            .font(.body).scrollContentBackground(.hidden).focused($focused)
            // One line high, the box scrolls only past six. `.scrollIndicators(.hidden)` is not honoured by `TextEditor` on macOS, and its
            // scroll bar, a knob filling its track, sat in the panel as a stray grey pill beside the Send button.
            .background(TextScrollerHider())
            .frame(height: ChatComposerState.editorHeight(for: state.text))
            .disabled(!state.canType)
            .opacity(state.replying ? 0.6 : 1)
            .overlay(alignment: .topLeading) {
                if state.isBlank {
                    Text(state.busy ? "Waiting for the agent…" : "Reply, or keep brainstorming…")
                        .foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 6).allowsHitTesting(false)
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

/// A scroller that draws nothing: its knob and its slot are blank, and it takes no room.
final class BlankScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {}
    override func drawKnob() {}
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override static func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 0 }
}

/// Takes the scroll bar off the `TextEditor` it sits behind. `TextEditor` is an `NSScrollView` around an `NSTextView`; SwiftUI does not
/// honour `.scrollIndicators(.hidden)` there, and turning the scrollers off once is not enough: AppKit brings the vertical one back on a
/// later layout, and its knob, filling its track, shows as a grey pill beside the Send button. So this finds that scroll view (the one in
/// the window that holds a text view and this view's centre) and puts a scroller in it that draws nothing, again on every update. The box
/// still scrolls, with the wheel and the keyboard.
struct TextScrollerHider: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            hide()
        }

        override func layout() {
            super.layout()
            hide()
        }

        func hide() {
            // After the layout that puts the text editor where it is.
            DispatchQueue.main.async { [weak self] in
                guard let self, let root = self.window?.contentView else { return }
                let centre = self.convert(NSPoint(x: self.bounds.midX, y: self.bounds.midY), to: nil)
                func scan(_ view: NSView) {
                    if let scroll = view as? NSScrollView, scroll.documentView is NSTextView,
                        scroll.convert(scroll.bounds, to: nil).contains(centre) {
                        TextScrollerHider.blank(scroll)
                    }
                    view.subviews.forEach(scan)
                }
                scan(root)
            }
        }
    }

    /// What is done to the scroll view: a scroller that draws nothing, no horizontal one, and the vertical one transparent and hidden
    /// (the overlay style paints its knob through a layer, which `draw` does not reach). Safe to repeat.
    static func blank(_ scroll: NSScrollView) {
        if !(scroll.verticalScroller is BlankScroller) { scroll.verticalScroller = BlankScroller() }
        scroll.verticalScroller?.alphaValue = 0
        scroll.verticalScroller?.isHidden = true
        scroll.hasHorizontalScroller = false
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.hide() }
}
