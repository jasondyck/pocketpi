import Foundation

// Shared plumbing for pocketpi's per-chat feature extensions (goal mode, plan
// mode, todos, permission presets; docs/dsh-features-plan.md). Each feature
// publishes its state as JSON with `ctx.ui.setStatus("pp-<name>", json)` and
// takes commands through `/api/s/{key}/control`.

extension ExtensionUIState {
    /// A pocketpi feature's published state ("pp-goal", "pp-todo", …), or nil
    /// when the extension hasn't set it (or cleared it).
    public func feature(_ key: String) -> JSONValue? {
        guard let s = statuses.first(where: { $0.key == key }) else { return nil }
        return try? JSONValue.parse(Data(s.text.utf8))
    }

    /// Status chips for the generic chip row: everything except pocketpi's
    /// own "pp-" keys, which the app draws natively.
    public var genericStatuses: [Status] { statuses.filter { !$0.key.hasPrefix("pp-") } }
}

extension ChatSession {
    /// Runs a pocketpi extension command in this chat's pi.
    public func control(_ command: String, args: JSONValue? = nil) async throws -> JSONValue {
        guard let key else { throw PocketPiError.command("This chat isn't open") }
        return try await client.control(key: key, command, args: args)
    }
}
