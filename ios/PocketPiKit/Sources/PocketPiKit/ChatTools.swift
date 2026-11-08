import Foundation
import Observation

// A chat's tools (the "Tools" screen from the chat's title menu;
// docs/pi-parity-plan.md F5): what pocketpi-control's `/pp-tools` lists,
// grouped the way pi's docs group them, and the active list to send when one
// is switched. The web twin is web/chat-tools.js.
//
// pi saves a change of tools in the session (a system message with
// toolsAdded / toolsRemoved), so it lasts for this chat, including after it's
// reopened; new chats start from `defaultTools` (Settings › pi settings).

/// Where a tool comes from.
public enum PiToolGroup: String, CaseIterable, Sendable {
    /// pi's own tools and its built-in extensions' (codemode, tool_search).
    case builtin
    /// Installed or local extensions'.
    case extensions
    /// MCP servers' (`mcp__<server>__<tool>`).
    case mcp

    public var title: String {
        switch self {
        case .builtin: "Built-in"
        case .extensions: "Extensions"
        case .mcp: "MCP servers"
        }
    }
}

extension PiTool {
    public var group: PiToolGroup {
        if name.hasPrefix("mcp__") { return .mcp }
        return source == "builtin" || source == "sdk" ? .builtin : .extensions
    }

    /// Withdrawn by its extension: pi won't turn it on.
    public var isHidden: Bool { exposure == "hidden" }

    /// The MCP server of an `mcp__<server>__<tool>` tool.
    public var mcpServer: String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst(5)
        guard let r = rest.range(of: "__") else { return nil }
        return String(rest[..<r.lowerBound])
    }

    /// The description's first line, at most `limit` characters.
    public func summary(limit: Int = 140) -> String {
        let first = (description ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.count > limit ? String(t.prefix(limit - 1)) + "…" : t
    }

    /// What the switch means for tools the model doesn't see directly.
    public var exposureNote: String? {
        switch exposure {
        case "codemode": "Scripts in codemode can call it even when off."
        case "deferred": "tool_search can find and turn it on."
        case "model-only": "The model sees it; scripts can't call it."
        default: nil
        }
    }
}

public enum ChatTools {
    /// Said under the list on both clients.
    public static let note = "Changes apply to this chat only. pi saves them with the chat, so they're back when it's reopened. New chats start with the default tools (Settings › pi settings)."

    /// The tools to show, grouped, each group in pi's order; hidden tools left out.
    public static func sections(_ tools: [PiTool]) -> [(group: PiToolGroup, tools: [PiTool])] {
        PiToolGroup.allCases.compactMap { g in
            let list = tools.filter { $0.group == g && !$0.isHidden }
            return list.isEmpty ? nil : (g, list)
        }
    }

    /// The active list after switching one tool: the others keep their
    /// state and order; a tool turned on goes at the end.
    public static func active(after name: String, on: Bool, in tools: [PiTool]) -> [String] {
        var list = tools.filter { $0.active && !$0.isHidden }.map(\.name)
        list.removeAll { $0 == name }
        if on { list.append(name) }
        return list
    }

    /// The active list with every tool of a group on or off.
    public static func active(setting group: PiToolGroup, on: Bool, in tools: [PiTool]) -> [String] {
        var list = tools.filter { $0.active && !$0.isHidden && $0.group != group }.map(\.name)
        if on { list += tools.filter { $0.group == group && !$0.isHidden }.map(\.name) }
        return list
    }

    /// "4 of 9 on".
    public static func count(_ tools: [PiTool]) -> String {
        let shown = tools.filter { !$0.isHidden }
        return "\(shown.filter(\.active).count) of \(shown.count) on"
    }
}

/// The Tools screen's state: the chat's tools, loaded and switched through
/// pocketpi-control. One per open screen.
@MainActor
@Observable
public final class ChatToolsModel {
    public let client: PocketPiClient
    public let key: String
    public private(set) var tools: [PiTool] = []
    public private(set) var loaded = false
    /// A call is in flight; switches wait.
    public private(set) var busy = false
    public var problem: String?

    public init(client: PocketPiClient, key: String) {
        self.client = client
        self.key = key
    }

    public var sections: [(group: PiToolGroup, tools: [PiTool])] { ChatTools.sections(tools) }
    public var count: String { ChatTools.count(tools) }

    public func load() async {
        do {
            tools = try await client.tools(key: key)
            loaded = true
        } catch {
            problem = error.reportable
        }
    }

    public func set(_ name: String, on: Bool) async {
        await apply(ChatTools.active(after: name, on: on, in: tools))
    }

    public func set(_ group: PiToolGroup, on: Bool) async {
        await apply(ChatTools.active(setting: group, on: on, in: tools))
    }

    private func apply(_ active: [String]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            tools = try await client.setActiveTools(key: key, active)
        } catch {
            problem = error.reportable
        }
    }
}
