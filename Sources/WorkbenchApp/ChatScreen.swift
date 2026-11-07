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
    /// Staged screenshots still being read: Send waits for them, so none that was just added is left out.
    var pending = 0

    init(snapshot: ThreadSnapshot, replying: Bool, drafting: Bool, text: String, pending: Int = 0) {
        self.pending = pending
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
    var canSend: Bool { !ended && !busy && !isBlank && pending == 0 }
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
                .role(.detail)
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
    var spoken: String { "\(speaker): \(text)" + (images.isEmpty ? "" : " (with \(images.count) screenshot(s))") }
}

/// One message as the artboard draws it: the person's in a bubble on the right with no label, the agent's as plain text beside a small
/// avatar. Both wrap, stay selectable, and say who spoke to VoiceOver.
struct ChatMessageRow: View {
    var message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Space.xs) {
                    Text(message.text).textStyle(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if !message.images.isEmpty {
                        Label(
                            message.images.count == 1 ? "1 screenshot" : "\(message.images.count) screenshots",
                            systemImage: "photo"
                        )
                        .textStyle(.caption, .secondary)
                    }
                }
                .padding(.horizontal, Spacing.inset).padding(.vertical, Space.m)
                .background(
                        Theme.raised,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14))
                    .frame(maxWidth: FeedLayout.userBubble, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(message.spoken)
        } else {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: "sparkle").textStyle(.captionMedium, .secondary)
                    .frame(width: 22, height: 22)
                    .background(Theme.raised, in: Circle()).overlay(Circle().stroke(Theme.line))
                // As tall as the avatar, centred: a one-line reply sits level with the disc, a longer one starts level with it.
                Text(message.text).textStyle(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
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
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text("Replying…").textStyle(.callout, .blue)
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
            Image(systemName: "arrow.up")
        }
        .iconButton().disabled(!enabled)
        .accessibilityLabel("Send the message").help("Sends the message (Return)")
    }
}

struct ChatComposer: View {
    var snapshot: ThreadSnapshot
    var store: ProjectStore
    @FocusState private var focused: Bool

    private var state: ChatComposerState {
        ChatComposerState(
            snapshot: snapshot, replying: store.replyingHere, drafting: store.drafting, text: store.chatDraft,
            pending: staging.pending)
    }

    private var staging: AttachmentStaging { store.chatStaging }

    var body: some View {
        let state = state
        composerBody(state)
            // A chat opened on a relaunch has not read the config yet: the footer names the agent once it has.
            .task { await store.refreshAgentSetup() }
    }

    private func composerBody(_ state: ChatComposerState) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let said = store.actionError {
                // A refusal (too long, no goal agent, a draft that did not come out) asks the person to change something: amber.
                MessageRow(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, text: said)
            }
            if let problem = staging.problem {
                MessageRow(symbol: "exclamationmark.triangle.fill", tint: Theme.amber, text: problem)
            }
            MessageRows(error: nil, note: store.actionNote, notice: store.notice, handoff: nil)
            if state.ended {
                Text("This chat has ended.").role(.detail)
            } else {
                panel(state)
                footer(state)
            }
        }
        .frame(maxWidth: FeedLayout.maxColumn)
        .padding(.horizontal, Spacing.gutter).padding(.top, Space.m).padding(.bottom, Space.l).frame(maxWidth: .infinity)
        .screenshotDrop(staging, allowed: state.canType)
        .pastesScreenshots(
            { [store] in store.chatStaging },
            allowed: { [store] in
                if case .thread = store.screen { return !store.replyingHere && !store.drafting }
                return false
            })
    }

    /// The composer: a rounded panel with the text box and a square arrow-up button inside it, as the artboard draws it.
    private func panel(_ state: ChatComposerState) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if !staging.items.isEmpty { StagedThumbnails(staging: staging) }
            HStack(alignment: .bottom, spacing: Space.m) {
                AddScreenshotsButton(staging: staging, disabled: !state.canType, size: .compact)
                editor(state)
                if staging.pending > 0 { ProgressView().controlSize(.small) }
                ComposerSendButton(enabled: state.canSend) { send() }
            }
        }
        .padding(.leading, Space.l).padding([.vertical, .trailing], Space.s).frame(minHeight: 46)
        .card()
    }

    /// Under the panel: what a chat is, and the one prominent button.
    private func footer(_ state: ChatComposerState) -> some View {
        HStack(spacing: Space.m) {
            Circle().strokeBorder(Theme.grey, lineWidth: 1.5).frame(width: 9, height: 9).accessibilityHidden(true)
            Text("Chat only. No worktree, no run, no cost.").role(.caption)
            if let note = store.chatAgentNote {
                Text("· \(note)").role(.caption).accessibilityLabel("Agent: \(note)")
            }
            Spacer(minLength: 12)
            if store.drafting {
                ProgressView().controlSize(.small)
                Text("Drafting the goal…").textStyle(.callout, .blue)
                Button("Stop") { store.stopDrafting() }.buttonStyle(.borderless)
            } else {
                Button { Task { await store.makeChatGoal() } } label: {
                    HStack(spacing: Space.s) {
                        Text("Make this a goal")
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                }
                .primaryButton().disabled(!state.canMakeGoal)
                .accessibilityLabel("Make this a goal")
                .help(
                    state.hasExchange
                        ? "The goal agent drafts a goal from this conversation; you read it and approve it next"
                        : "Available once the agent has answered")
            }
        }
    }

    private func editor(_ state: ChatComposerState) -> some View {
        PlaceholderTextEditor(
            text: Binding(get: { store.chatDraft }, set: { store.chatDraft = $0 }),
            placeholder: state.busy ? "Waiting for the agent…" : "Reply, or keep brainstorming…", style: .body,
            hidesScroller: true, showsPlaceholder: state.isBlank, accessibilityLabel: "Message", focus: $focused,
            onReturn: { press in
                let key = ChatComposerState.key(
                    shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option))
                guard key == .send else { return .ignored }
                if state.canSend { send() }
                return .handled
            }
        )
        // The text view starts its text at the top edge, so the box is pushed down by Space.s and shortened by as much: one line then sits
        // level with the + and Send squares beside it, and the row keeps its height.
        .frame(height: ChatComposerState.editorHeight(for: state.text) - Space.s)
        .padding(.top, Space.s)
        .disabled(!state.canType)
        .opacity(state.replying ? 0.6 : 1)
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
