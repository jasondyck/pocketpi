import Foundation

// MCP servers (plan F7, F8; the server side is src/pi_packages.rs and
// `pi mcp` jobs in src/pi_cli.rs; the web twin is web/manage-mcp.js): what
// the mcp.json files define merged with `pi mcp list --json`'s report, the
// edits pi's /mcp makes (enabled, exposure, a project override), adding a
// server, and signing in through a chat.

/// How the model reaches a server's tools.
public enum McpExposure: String, Sendable, CaseIterable, Identifiable {
    case codemode, deferred, direct, hidden
    public var id: String { rawValue }

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public var detail: String {
        switch self {
        case .codemode: "Callable from codemode scripts; not declared to the model."
        case .deferred: "Declared once tool_search finds them."
        case .direct: "Declared to the model like built-in tools."
        case .hidden: "Registered but unreachable."
        }
    }

    /// pi's value, with its alias.
    public init(pi: String?) { self = McpExposure(rawValue: pi == "codemode-deferred" ? "codemode" : pi ?? "codemode") ?? .codemode }
}

public struct McpServer: Sendable, Equatable, Identifiable {
    public var name: String
    /// "global" or "project": where it's defined (pi's report when there is one).
    public var scope: String
    /// The file that defines it ("global"/"project"), or nil for a server pi
    /// reports that no file here names.
    public var definedIn: String?
    /// The defining entry (secrets redacted) and the project's override entry.
    public var entry: JSONValue
    public var override: JSONValue?
    public var enabled: Bool
    public var exposure: McpExposure
    public var transport: String
    public var isURL: Bool
    /// connected, needs-auth, failed, disabled; "checking" before pi answers.
    public var state: String
    public var tools: [String]
    public var toolExposure: [String: String]
    public var error: String?
    public var source: String?
    public var id: String { name }

    /// The state in a few words, and whether it's good, a warning or bad.
    public var stateText: (text: String, tone: Int) {
        switch state {
        case "connected": ("\(tools.count) tool\(tools.count == 1 ? "" : "s")", 0)
        case "needs-auth": ("needs sign-in", 1)
        case "failed": ("failed", 2)
        case "disabled": ("off", 1)
        default: (state, -1)
        }
    }

    /// The enabled switch reads the defining file.
    public var enabledInFile: Bool { entry["enabled"]?.bool != false }

    /// The exposure the sheet shows: the override's when it sets one.
    public var shownExposure: McpExposure { McpExposure(pi: override?["exposure"]?.string ?? entry["exposure"]?.string) }

    /// A global server in this project: `.inherit` unless the project's override says on or off.
    public var projectState: PiToggleState {
        guard let e = override?["enabled"]?.bool else { return .inherit }
        return e ? .on : .off
    }

    public var description: String? { entry["description"]?.string }
}

/// An `mcp.json` entry without command, url or type: only overrides switches.
func isMcpOverride(_ v: JSONValue?) -> Bool {
    guard case .object(let o)? = v else { return false }
    return o["command"] == nil && o["url"] == nil && o["type"] == nil
}

/// `pi mcp list --json`, or why there isn't one.
public struct McpReport: Sendable, Equatable {
    public var servers: [JSONValue]
    public var errors: [String]
    /// pi's note when the project's mcp.json is ignored (not trusted).
    public var note: String?
    public var error: String?

    public init(_ r: PiCLIResult) {
        if let j = r.json {
            servers = j["servers"]?.array ?? []
            errors = j["errors"]?.array?.compactMap(\.string) ?? []
            note = j["note"]?.string
        } else {
            servers = []; errors = []
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            error = msg.isEmpty ? "pi mcp list exited with \(r.code ?? -1)" : msg
        }
    }
}

public enum McpServers {
    /// Every server: from the files, with pi's report when it has come.
    public static func merge(global: JSONValue?, project: JSONValue?, report: McpReport?) -> [McpServer] {
        let g = global?["mcpServers"]?.object ?? [:]
        let p = project?["mcpServers"]?.object ?? [:]
        let reported = Dictionary((report?.servers ?? []).compactMap { s in s["name"]?.string.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        var names: [String] = []
        for n in Array(p.keys) + Array(g.keys) + Array(reported.keys) where !names.contains(n) { names.append(n) }
        let list = names.map { name -> McpServer in
            let r = reported[name]
            let projectDefines = p[name] != nil && !isMcpOverride(p[name])
            let own: JSONValue = projectDefines ? p[name]! : g[name] ?? .object([:])
            let ov: JSONValue? = !projectDefines && p[name] != nil ? p[name] : nil
            let confEnabled = ov?["enabled"]?.bool ?? own["enabled"]?.bool ?? true
            let args = own["args"]?.array?.compactMap(\.string) ?? []
            let transport = r?["transport"]?.string ?? own["url"]?.string ?? ([own["command"]?.string].compactMap { $0 } + args).joined(separator: " ")
            var state = r?["state"]?.string ?? (report == nil ? "checking" : confEnabled ? "unknown" : "disabled")
            if report?.error != nil && r == nil { state = confEnabled ? "unknown" : "disabled" }
            return McpServer(
                name: name,
                scope: r?["scope"]?.string ?? (projectDefines ? "project" : "global"),
                definedIn: projectDefines ? "project" : g[name] != nil ? "global" : nil,
                entry: own, override: ov,
                enabled: r?["enabled"]?.bool ?? confEnabled,
                exposure: McpExposure(pi: r?["exposure"]?.string ?? ov?["exposure"]?.string ?? own["exposure"]?.string),
                transport: transport,
                isURL: own["url"] != nil || transport.hasPrefix("http"),
                state: state,
                tools: r?["tools"]?.array?.compactMap(\.string) ?? [],
                toolExposure: (r?["toolExposure"]?.object ?? [:]).compactMapValues(\.string),
                error: r?["error"]?.string,
                source: r?["source"]?.string)
        }
        return list.sorted { ($0.scope == "project" ? 0 : 1, $0.name) < ($1.scope == "project" ? 0 : 1, $1.name) }
    }
}

/// A change to one server in an mcp.json (`POST /api/pi/mcp/server`).
public struct McpEdit: Sendable, Equatable {
    public var name: String
    /// The project, for `scope: project`.
    public var cwd: String?
    public var project: Bool
    public var enabled: Bool?
    public var exposure: McpExposure?
    /// Add a project override when the project's file doesn't name it.
    public var override: Bool
    /// Remove the project override.
    public var clear: Bool

    public init(name: String, cwd: String? = nil, project: Bool = false, enabled: Bool? = nil, exposure: McpExposure? = nil,
                override: Bool = false, clear: Bool = false) {
        self.name = name; self.cwd = cwd; self.project = project; self.enabled = enabled
        self.exposure = exposure; self.override = override; self.clear = clear
    }

    /// Turn it on or off in the file that defines it.
    public static func enabled(_ s: McpServer, _ on: Bool, cwd: String?) -> McpEdit {
        McpEdit(name: s.name, cwd: cwd, project: s.definedIn == "project", enabled: on)
    }

    /// Change the exposure; a project override keeps its own.
    public static func exposure(_ s: McpServer, _ x: McpExposure, cwd: String?) -> McpEdit {
        McpEdit(name: s.name, cwd: cwd, project: s.definedIn == "project" || s.override != nil, exposure: x)
    }

    /// A global server in one project: on, off, or like global.
    public static func inProject(_ s: McpServer, _ state: PiToggleState, cwd: String) -> McpEdit {
        state == .inherit
            ? McpEdit(name: s.name, cwd: cwd, project: true, clear: true)
            : McpEdit(name: s.name, cwd: cwd, project: true, enabled: state == .on, override: true)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "scope": .string(project ? "project" : "global")]
        if project, let cwd { o["cwd"] = .string(cwd) }
        if let enabled { o["enabled"] = .bool(enabled) }
        if let exposure { o["exposure"] = .string(exposure.rawValue) }
        if override { o["override"] = true }
        if clear { o["clear"] = true }
        return .object(o)
    }
}

/// The add-a-server form, turned into a `pi mcp add` job.
public struct McpAddForm: Sendable, Equatable {
    public var name = ""
    public var useURL = false
    public var command = ""
    /// One argument per line.
    public var args = ""
    /// KEY=VALUE per line.
    public var env = ""
    public var url = ""
    /// Name=Value per line.
    public var headers = ""
    public var description = ""
    public var exposure: McpExposure = .codemode
    public var inProject = false

    public init() {}

    static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The job, or what's wrong with the form.
    public func action(cwd: String?) -> Result<PiAction, McpFormError> {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            return .failure(.init("The name can only have letters, digits, _ and -"))
        }
        let local = inProject && !(cwd ?? "").isEmpty
        let x = exposure == .codemode ? nil : exposure.rawValue
        let d = description.trimmingCharacters(in: .whitespaces)
        if useURL {
            let u = url.trimmingCharacters(in: .whitespaces)
            guard u.hasPrefix("https://") || u.hasPrefix("http://") else { return .failure(.init("The URL starts with https://")) }
            let h = Self.lines(headers)
            guard h.allSatisfy({ $0.contains("=") }) else { return .failure(.init("Each header is Name=Value")) }
            return .success(.mcpAdd(name: n, local: local, cwd: local ? cwd : nil, url: u, headers: h, exposure: x, description: d.isEmpty ? nil : d))
        }
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return .failure(.init("Give the command")) }
        let e = Self.lines(env)
        guard e.allSatisfy({ $0.contains("=") }) else { return .failure(.init("Each environment line is KEY=VALUE")) }
        return .success(.mcpAdd(name: n, local: local, cwd: local ? cwd : nil, command: c, args: Self.lines(args), env: e,
                                exposure: x, description: d.isEmpty ? nil : d))
    }
}

public struct McpFormError: Error, Equatable, Sendable {
    public var message: String
    init(_ m: String) { message = m }
}

/// What `/mcp login|logout|reconnect` showed in the chat it ran in.
public struct McpSignin: Sendable, Equatable {
    public var key: String
    public var cwd: String
    public var file: String?
    /// The command finished (no dialog left open).
    public var done: Bool
    public var error: String?
    public var notices: [String]
    /// The page to approve pi on.
    public var url: String?
    /// The dialog asking for the address the browser ended on.
    public var dialogID: String?
    public var dialogTitle: String?
    public var placeholder: String?

    public init(_ v: JSONValue) {
        key = v["key"]?.string ?? ""
        cwd = v["cwd"]?.string ?? ""
        file = v["file"]?.string
        done = v["done"]?.bool ?? false
        error = v["error"]?.string
        let link = v["url"]?.string
        url = link
        let all = v["notices"]?.array?.compactMap { $0["message"]?.string } ?? []
        // The URL has its own button.
        notices = all.filter { n in link.map { !n.contains($0) } ?? true }
        dialogID = v["dialog"]?["id"]?.string
        dialogTitle = v["dialog"]?["title"]?.string
        placeholder = v["dialog"]?["placeholder"]?.string
    }
}

public enum McpChatAction: String, Sendable {
    case login, logout, reconnect
}

extension PocketPiClient {
    /// Both mcp.json files (redacted) and pi's report. The report connects to
    /// every server, so it's a separate call: `mcpReport`.
    public func mcpFiles(cwd: String?) async throws -> (global: PiConfigDocument, project: PiConfigDocument?) {
        let g = try await config(.mcp)
        let p: PiConfigDocument? = (cwd ?? "").isEmpty ? nil : try await config(.mcp, cwd: cwd)
        return (g, p)
    }

    public func mcpReport(cwd: String?) async throws -> McpReport { McpReport(try await mcpList(cwd: cwd)) }

    /// Change one server's settings in mcp.json. Chats need a restart.
    @discardableResult
    public func editMcpServer(_ e: McpEdit) async throws -> PiConfigDocument {
        try await post("/api/pi/mcp/server", e.json)
    }

    /// Run `/mcp <action> <server>` in a chat for `cwd` (`key`'s, else the
    /// open one, else a new one; reconnect needs an open one).
    public func mcpChat(_ action: McpChatAction, server: String, cwd: String?, key: String? = nil) async throws -> McpSignin {
        var o: [String: JSONValue] = ["name": .string(server), "action": .string(action.rawValue)]
        if let cwd, !cwd.isEmpty { o["cwd"] = .string(cwd) }
        if let key { o["key"] = .string(key) }
        return McpSignin(try await post("/api/pi/mcp/signin", .object(o), as: JSONValue.self))
    }

    /// Answer the sign-in's dialog (the pasted address, or cancel with nil).
    public func finishSignin(_ s: McpSignin, redirect: String?) async throws {
        guard let id = s.dialogID else { return }
        var o: [String: JSONValue] = ["type": "extension_ui_response", "id": .string(id)]
        if let redirect { o["value"] = .string(redirect) } else { o["cancelled"] = true }
        let _: JSONValue = try await post("/api/s/\(s.key)/cmd", .object(o))
    }
}
