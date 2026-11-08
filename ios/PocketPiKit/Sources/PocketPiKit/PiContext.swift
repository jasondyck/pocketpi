import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Settings › Context (docs/pi-parity-plan.md E6, src/pi_context.rs): pi's
// context files (AGENTS.md and friends) and system prompt files (SYSTEM.md,
// APPEND_SYSTEM.md), global and per project, and which of them pi loads.
// Also the raw settings.json editor (E3, src/pi_settings_raw.rs). The web
// twins are web/manage-context.js and the raw editor in
// web/manage-settings.js.

/// One file the Context page can show.
public struct PiContextFile: Sendable, Equatable, Identifiable, Hashable {
    /// "global" or "project".
    public var scope: String
    public var name: String
    public var path: String
    public var exists: Bool
    public var size: Int?
    /// CLAUDE.md, AGENTS.MD and CLAUDE.MD are shown, not edited.
    public var editable: Bool
    /// "context", "system" or "append".
    public var kind: String
    /// pi reads it for this project (or, without one, everywhere).
    public var loaded: Bool
    public var id: String { "\(scope)/\(name)" }

    init?(_ v: JSONValue) {
        guard let s = v["scope"]?.string, let n = v["name"]?.string else { return nil }
        scope = s
        name = n
        path = v["path"]?.string ?? ""
        exists = v["exists"]?.bool ?? false
        size = v["size"]?.int
        editable = v["editable"]?.bool ?? false
        kind = v["kind"]?.string ?? "context"
        loaded = v["loaded"]?.bool ?? false
    }

    /// What the file is for, in a line.
    public var role: String {
        switch kind {
        case "system": "Replaces pi's system prompt"
        case "append": "Added to pi's system prompt"
        default: name == "AGENTS.override.md" ? "Used instead of AGENTS.md in this folder" : "Instructions for every chat here"
        }
    }

    /// Why it is or isn't used, given the overview it came from.
    public func status(in overview: PiContextOverview) -> String {
        if !exists { return "Not created" }
        if loaded { return "Loaded" }
        switch kind {
        case "system", "append":
            if scope == "project", overview.trusted == false { return "Ignored: pi doesn't trust this project" }
            return "Not used: the project's file wins"
        default:
            return "Not used: another file in this folder wins"
        }
    }
}

/// `GET /api/pi/context[?cwd=]`.
public struct PiContextOverview: Sendable, Equatable {
    public struct Loaded: Sendable, Equatable, Hashable {
        public var path: String
        /// "global", "parent" or "project".
        public var scope: String
    }

    public var agentDir: String
    public var cwd: String?
    public var maxBytes: Int
    public var files: [PiContextFile]
    /// Context files in the order pi reads them.
    public var context: [Loaded]
    public var system: Loaded?
    public var append: Loaded?
    /// For a project: whether pi trusts it (its .pi/ files need that;
    /// AGENTS.md doesn't). Nil without a project.
    public var trusted: Bool?

    init(_ v: JSONValue) {
        agentDir = v["agentDir"]?.string ?? ""
        cwd = v["cwd"]?.string
        maxBytes = v["maxBytes"]?.int ?? 262_144
        files = (v["files"]?.array ?? []).compactMap(PiContextFile.init)
        func loaded(_ x: JSONValue?) -> Loaded? {
            guard let x, let p = x["path"]?.string else { return nil }
            return Loaded(path: p, scope: x["scope"]?.string ?? "")
        }
        context = (v["loaded"]?["context"]?.array ?? []).compactMap { loaded($0) }
        system = loaded(v["loaded"]?["system"])
        append = loaded(v["loaded"]?["append"])
        trusted = v["trust"]?["trusted"]?.bool
    }

    public func files(scope: String) -> [PiContextFile] { files.filter { $0.scope == scope } }

    /// Context files from folders above the project (read only here).
    public var parents: [Loaded] { context.filter { $0.scope == "parent" } }

    /// "pi's own" / the file that replaces it.
    public var systemSummary: String {
        system.map { "Replaced by \($0.scope) SYSTEM.md" } ?? "pi's own"
    }
}

/// One context file's text.
public struct PiContextText: Sendable, Equatable {
    public var scope: String
    public var name: String
    public var path: String
    public var exists: Bool
    public var editable: Bool
    public var content: String

    init(_ v: JSONValue) {
        scope = v["scope"]?.string ?? ""
        name = v["name"]?.string ?? ""
        path = v["path"]?.string ?? ""
        exists = v["exists"]?.bool ?? false
        editable = v["editable"]?.bool ?? false
        content = v["content"]?.string ?? ""
    }
}

/// settings.json as text, for the raw editor.
public struct PiRawSettings: Sendable, Equatable {
    public var scope: String
    public var path: String
    public var exists: Bool
    public var text: String
    /// Where the schema came from: pi's package, or "bundled".
    public var schema: String

    init(_ v: JSONValue) {
        scope = v["scope"]?.string ?? "global"
        path = v["path"]?.string ?? ""
        exists = v["exists"]?.bool ?? false
        text = v["text"]?.string ?? ""
        schema = v["schema"]?.string ?? ""
    }

    /// What to start the editor with: the file, or `{}` for a new one.
    public var editorText: String { exists && !text.isEmpty ? text : "{\n}\n" }
}

public struct PiSchemaProblem: Sendable, Equatable, Hashable {
    /// "retry.maxRetries", "enabledModels[2]", "" for the whole file.
    public var path: String
    public var message: String
    public var line: String { path.isEmpty ? message : "\(path): \(message)" }
}

public enum RawSettings {
    /// A quick local check before asking the server: valid JSON, and an
    /// object. Nil when fine.
    public static func syntaxProblem(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return "Not text" }
        guard let v = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "Not valid JSON"
        }
        return v is [String: Any] ? nil : "settings.json must be a JSON object ({…})"
    }
}

/// Which settings.json a page edits.
public enum SettingsScope: Hashable, Sendable {
    case global
    case project(String)

    public var cwd: String? {
        if case .project(let c) = self { return c }
        return nil
    }

    public var isProject: Bool { cwd != nil }
}

extension PocketPiClient {
    private static func q(_ items: [(String, String?)]) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+/?"))
        let parts = items.compactMap { k, v in
            v.flatMap { $0.isEmpty ? nil : "\(k)=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0)" }
        }
        return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
    }

    // MARK: context files

    /// The context and system prompt files for a project (or only the
    /// global ones), and what pi loads.
    public func contextOverview(cwd: String? = nil) async throws -> PiContextOverview {
        PiContextOverview(try await get("/api/pi/context\(Self.q([("cwd", cwd)]))") as JSONValue)
    }

    public func contextFile(scope: String, name: String, cwd: String? = nil) async throws -> PiContextText {
        PiContextText(try await get("/api/pi/context/file\(Self.q([("scope", scope), ("name", name), ("cwd", cwd)]))") as JSONValue)
    }

    /// Write a context file (backed up first). Chats need a restart to see it.
    @discardableResult
    public func saveContextFile(scope: String, name: String, cwd: String? = nil, content: String) async throws -> PiContextText {
        PiContextText(try await post("/api/pi/context/file\(Self.q([("scope", scope), ("name", name), ("cwd", cwd)]))",
                                     ["content": .string(content)]) as JSONValue)
    }

    /// Remove a context file (kept as its newest backup).
    @discardableResult
    public func deleteContextFile(scope: String, name: String, cwd: String? = nil) async throws -> PiContextText {
        PiContextText(try await post("/api/pi/context/file\(Self.q([("scope", scope), ("name", name), ("cwd", cwd)]))",
                                     ["delete": true]) as JSONValue)
    }

    // MARK: raw settings.json

    public func rawSettings(cwd: String? = nil) async throws -> PiRawSettings {
        PiRawSettings(try await get("/api/pi/config/settings/raw\(Self.q([("cwd", cwd)]))") as JSONValue)
    }

    /// What's wrong with `text` as pi's settings (pi's schema), without saving.
    public func checkRawSettings(_ text: String, cwd: String? = nil) async throws -> [PiSchemaProblem] {
        let r: JSONValue = try await post("/api/pi/config/settings/raw\(Self.q([("cwd", cwd)]))",
                                          ["text": .string(text), "check": true])
        return (r["problems"]?.array ?? []).map {
            PiSchemaProblem(path: $0["path"]?.string ?? "", message: $0["message"]?.string ?? "")
        }
    }

    /// Replace settings.json with `text`. The server refuses (422, the
    /// problems in the message) what isn't JSON or doesn't fit pi's schema.
    @discardableResult
    public func saveRawSettings(_ text: String, cwd: String? = nil) async throws -> PiConfigDocument {
        try await post("/api/pi/config/settings/raw\(Self.q([("cwd", cwd)]))", ["text": .string(text)])
    }
}
