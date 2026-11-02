import Foundation

/// The chat feed preview (P22): one switch, kept as an app preference, that swaps the thread screen for the feed.
extension ProjectStore {
    /// Turns the preview on or off, remembers it, and reads the thread again so the feed's items are there (or gone) at once.
    func setChatFeed(_ on: Bool) async {
        guard on != chatFeedOn else { return }
        preferences.chatFeed = on
        chatFeedOn = on
        await reload()
    }
}
