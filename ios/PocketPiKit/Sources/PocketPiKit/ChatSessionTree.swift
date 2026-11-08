import Foundation

/// Everything the session info sheet shows.
public struct SessionInfoSheet: Sendable, Equatable {
    public var header: SessionHeader
    public var summary: SessionSummary
    public var stats: JSONValue
    /// pi's own totals (`get_session_stats`).
    public var totalTokens: Int? { stats["tokens"]?["total"]?.int }
    public var cost: Double? { stats["cost"]?.double }
}

extension ChatSession {
    /// The chat's session tree (`get_tree`).
    public func loadTree() async throws -> SessionTree {
        SessionTree(try await command(["type": "get_tree"]))
    }

    /// Carry on from another point of the tree (pocketpi-control's
    /// /pp-goto). Going to a prompt puts it back in the message box, like
    /// pi's /tree. With `summarize`, pi first summarizes the branch being
    /// left (a model call). The session file stays the same; the messages
    /// on screen change. False if nothing happened; `problem` says why.
    @discardableResult
    public func goto(_ row: TreeRow, summarize: Bool = false, instructions: String? = nil) async -> Bool {
        guard !isStreaming else { problem = "Wait for pi to finish first."; return false }
        do {
            if key == nil, path != nil { try await reopen() }
            guard let key else { throw PocketPiError.unexpected("no session") }
            let r = try await client.goto(key: key, entryId: row.id, summarize: summarize, instructions: instructions)
            if r.cancelled {
                problem = "An extension cancelled the move."
                return false
            }
            // The server tells every client to reload too (pocketpi_resync),
            // which can overtake this one: wait for the screen to have it.
            await reloadAfterSwitch()
            if let t = r.editorText {
                composer = t
                composerFocusRequests += 1
            }
            onTurnFinished?()
            return true
        } catch {
            problem = error.reportable
            return false
        }
    }

    /// Set or (nil / "") clear an entry's label.
    @discardableResult
    public func setLabel(_ entryId: String, _ label: String?) async -> Bool {
        do {
            if key == nil, path != nil { try await reopen() }
            guard let key else { throw PocketPiError.unexpected("no session") }
            try await client.setLabel(key: key, entryId: entryId, label: label)
            return true
        } catch {
            problem = error.reportable
            return false
        }
    }

    /// The session info sheet's numbers: the file's header, counts and cost
    /// per model over every entry, and pi's totals.
    public func loadInfo() async throws -> SessionInfoSheet {
        async let entries = command(["type": "get_entries"])
        async let stats = command(["type": "get_session_stats"])
        let (e, s) = try await (entries, stats)
        guard let key else { throw PocketPiError.unexpected("no session") }
        let header = try await client.sessionHeader(key: key)
        return SessionInfoSheet(header: header, summary: SessionSummary(entries: e["entries"]?.array ?? []), stats: s)
    }

    /// `get_fork_messages`, narrowed to the prompts on the chat's current
    /// branch: pi lists every user message in the file, abandoned branches
    /// too, so a prompt repeated on another branch could otherwise be
    /// matched. Unnarrowed when the tree can't be read.
    func activeForkPoints() async throws -> [ForkPoint] {
        let points = (try await command(["type": "get_fork_messages"])["messages"]?.array ?? []).compactMap(ForkPoint.init)
        guard let tree = try? await loadTree() else { return points }
        let onPath = Set(tree.pathUserIds)
        return points.filter { onPath.contains($0.entryId) }
    }
}
