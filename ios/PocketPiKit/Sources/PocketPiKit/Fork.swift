import Foundation

/// A user message pi can fork from (`get_fork_messages`).
public struct ForkPoint: Sendable, Equatable {
    public var entryId: String
    public var text: String
    public init(entryId: String, text: String) {
        self.entryId = entryId
        self.text = text
    }
    public init?(_ v: JSONValue) {
        guard let id = v["entryId"]?.string else { return nil }
        self.init(entryId: id, text: v["text"]?.string ?? "")
    }
}

/// Which session entry a user message on screen is.
///
/// `get_messages` (what the transcript is built from) carries no entry ids;
/// `get_fork_messages` has them, but it is a different list: every user
/// message with text in the whole session file, in the order they were
/// appended, including history compacted away (which `get_messages` leaves
/// out) and abandoned branches. Its text is pi's `contentText(content, "")`:
/// the text blocks joined with nothing between them; image-only messages
/// aren't in it.
///
/// So the two are lined up from the end: the newest message on screen is
/// matched with the newest fork point with the same text, the one before it
/// with the closest earlier fork point with the same text, and so on. That
/// skips messages compacted away (only on pi's side) and image-only ones
/// (only on screen), and gives the right entry for repeated prompts ("go
/// on"). Abandoned branches only exist after moving around the session tree
/// (the TUI's /tree, which pocketpi doesn't offer yet); a message there is
/// matched only if it repeats a later prompt word for word.
public enum ForkMap {
    /// A user message's text the way pi reports it in `get_fork_messages`.
    public static func text(of m: ChatMessage) -> String {
        m.content.compactMap(\.text).joined()
    }

    /// For each user message on screen (oldest first), the entry id to fork
    /// at, or nil where there is none.
    public static func entryIds(for shown: [String], in points: [ForkPoint]) -> [String?] {
        var out = [String?](repeating: nil, count: shown.count)
        var next = points.count - 1
        for i in shown.indices.reversed() where !shown[i].isEmpty {
            var k = next
            while k >= 0, points[k].text != shown[i] { k -= 1 }
            guard k >= 0 else { continue } // not on pi's side: leave the cursor where it was
            out[i] = points[k].entryId
            next = k - 1
        }
        return out
    }
}

extension Transcript {
    /// The user messages on screen, oldest first, with their item ids.
    public var userMessages: [(id: Int, message: ChatMessage)] {
        items.compactMap { item in
            if case .user(let m) = item.kind { return (item.id, m) }
            return nil
        }
    }

    /// Whether a user message can be forked from: it has text (pi doesn't
    /// list image-only messages) and pi isn't working.
    public func canFork(_ item: Item) -> Bool {
        guard !isStreaming, case .user(let m) = item.kind else { return false }
        return !ForkMap.text(of: m).isEmpty
    }
}

extension SessionInfo {
    /// The chat list's "forked from …" line for a chat that was forked or
    /// cloned (nil otherwise): the parent's title while it's still listed.
    public func forkHint(in all: [SessionInfo]) -> String? {
        guard let parent else { return nil }
        guard let p = all.first(where: { $0.path == parent }) else { return "Forked" }
        return "Forked from \(p.displayTitle)"
    }
}
