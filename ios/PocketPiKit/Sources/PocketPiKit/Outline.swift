import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The turn outline (docs/dsh-features-plan.md §3.7): one line per prompt of
// the person on the chat's active branch, from the server's
// `GET /api/sessions/outline?path=`, which reads the session file. Same
// feature as web/outline.js.

/// One prompt and what came of it.
public struct OutlineTurn: Sendable, Equatable, Identifiable, Decodable {
    /// The user message's session entry.
    public var entryId: String
    /// Its text, at most 50 characters ("(image)" for an image-only message).
    public var prompt: String
    /// The last assistant text of the turn, at most 120 characters; "" when
    /// the turn had none (still running, tools only, an error).
    public var response: String

    public var id: String { entryId }

    public init(entryId: String, prompt: String, response: String = "") {
        self.entryId = entryId
        self.prompt = prompt
        self.response = response
    }

    enum CodingKeys: String, CodingKey { case entryId, prompt, response }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entryId = try c.decode(String.self, forKey: .entryId)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        response = try c.decodeIfPresent(String.self, forKey: .response) ?? ""
    }
}

public enum OutlineMap {
    /// The transcript row (`TranscriptRow.id`) of the user message that is
    /// session entry `entryId`, or nil when it isn't on screen (compacted
    /// away). `shown` are the user messages on screen, oldest first, with
    /// their item ids; they are lined up with the fork points like
    /// `ChatSession.fork` does (`ForkMap`).
    public static func rowId(for entryId: String, shown: [(id: Int, text: String)], points: [ForkPoint]) -> String? {
        let ids = ForkMap.entryIds(for: shown.map(\.text), in: points)
        guard let n = ids.firstIndex(of: entryId) else { return nil }
        return "i\(shown[n].id)" // TranscriptRow.item's id
    }
}

extension PocketPiClient {
    /// The server path of a session file's outline.
    public static func outlinePath(_ path: String) -> String {
        var c = URLComponents()
        c.path = "/api/sessions/outline"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        // "+" would read as a space in a query.
        return (c.string ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    /// The outline of the session file `path`, oldest prompt first.
    public func outline(path: String) async throws -> [OutlineTurn] {
        try await get(Self.outlinePath(path))
    }
}

extension ChatSession {
    /// This chat's outline; empty before its session file exists.
    public func loadOutline() async throws -> [OutlineTurn] {
        guard let path else { return [] }
        return try await client.outline(path: path)
    }

    /// The transcript row to scroll to for an outline line, or nil when that
    /// message isn't on screen.
    public func transcriptRow(forEntry entryId: String) async -> String? {
        let shown = transcript.userMessages.map { (id: $0.id, text: ForkMap.text(of: $0.message)) }
        guard let points = try? await activeForkPoints() else { return nil }
        return OutlineMap.rowId(for: entryId, shown: shown, points: points)
    }
}
