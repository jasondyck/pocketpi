import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// pi's configuration as pocketpi exposes it (src/pi_admin.rs, src/pi_cli.rs):
// its JSON files read and patched, its CLI run as jobs, chats restarted to
// pick changes up, and the pocketpi-control extension's commands.

/// One of pi's config files. `settings` and `mcp` also exist per project.
public enum PiConfigFile: String, Sendable, CaseIterable {
    case settings, auth, models, mcp, trust
}

/// A config file as the server returns it. `data` is the whole document,
/// except that secrets are never in it: `auth` comes back as
/// `{providers: [{provider, type, hasKey}]}`, and credential-looking values in
/// `models` and `mcp` read `"<redacted>"`.
public struct PiConfigDocument: Codable, Sendable, Equatable {
    public var file: String
    /// "global" or "project".
    public var scope: String
    public var path: String
    public var exists: Bool
    public var data: JSONValue
    /// The server's config epoch after this read or write.
    public var epoch: UInt64

    /// For `auth`: which providers have credentials.
    public var authProviders: [PiAuthProvider] {
        (data["providers"]?.array ?? []).compactMap(PiAuthProvider.init)
    }
}

/// What `auth.json` says about a provider, without its credential.
public struct PiAuthProvider: Sendable, Equatable, Hashable {
    public var provider: String
    /// "api_key", "oauth", ...
    public var type: String
    public var hasKey: Bool

    init?(_ v: JSONValue) {
        guard let p = v["provider"]?.string else { return nil }
        provider = p
        type = v["type"]?.string ?? "unknown"
        hasKey = v["hasKey"]?.bool ?? false
    }
}

/// A change to a config file: dotted paths to set and to remove. Keys
/// pocketpi doesn't know about are left alone, so this never loses a setting.
public struct PiConfigPatch: Sendable, Equatable {
    public var set: [String: JSONValue]
    public var unset: [String]

    public init(set: [String: JSONValue] = [:], unset: [String] = []) {
        self.set = set
        self.unset = unset
    }

    /// One path segment, with its dots escaped (model ids have dots:
    /// `PiConfigPatch.path("modelThinkingLevels", "anthropic/claude-4.5")`).
    public static func path(_ segments: String...) -> String {
        segments.map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ".", with: "\\.") }
            .joined(separator: ".")
    }

    var json: JSONValue { ["set": .object(set), "unset": .array(unset.map(JSONValue.string))] }
}

/// A running pi, from `/api/pi/status`.
public struct LivePi: Codable, Sendable, Equatable, Identifiable {
    public var key: String
    public var file: String?
    public var cwd: String
    /// "chat", "chat_tab" or "stage".
    public var kind: String
    public var streaming: Bool
    public var epoch: UInt64
    /// Started before the last config change: needs a restart to apply it.
    public var stale: Bool
    public var id: String { key }
}

public struct PiStatus: Codable, Sendable, Equatable {
    public var configEpoch: UInt64
    public var live: [LivePi]
    /// Chats get the pocketpi-control extension.
    public var control: Bool

    enum CodingKeys: String, CodingKey {
        case live, control
        case configEpoch = "config_epoch"
    }
}

/// `/api/pi/reload`: idle chats restarted, busy ones left for later.
public struct PiReloadResult: Codable, Sendable, Equatable {
    public struct Failure: Codable, Sendable, Equatable {
        public var key: String
        public var error: String
    }
    public var restarted: [String]
    public var busy: [String]
    public var failed: [Failure]
    public var configEpoch: UInt64

    enum CodingKeys: String, CodingKey {
        case restarted, busy, failed
        case configEpoch = "config_epoch"
    }
}

/// `/api/s/{key}/restart`: the same key, a new pi on the same session file.
public struct PiRestartResult: Codable, Sendable, Equatable {
    public var key: String
    public var file: String?
    public var epoch: UInt64
}

/// What pocketpi may run of pi's CLI. Each becomes one fixed command line on
/// the server; nothing goes through a shell.
public enum PiAction: Sendable, Equatable {
    case install(source: String, local: Bool = false, cwd: String? = nil)
    case remove(source: String, local: Bool = false, cwd: String? = nil)
    case list(cwd: String? = nil)
    /// pi itself with no options; or one package, all packages, the model catalogs, everything.
    /// With `cwd`, the project's packages are updated too.
    case update(source: String? = nil, extensions: Bool = false, models: Bool = false, all: Bool = false, cwd: String? = nil)
    case mcpList(cwd: String? = nil)
    /// A stdio server (`command` + `args` + `env` as KEY=VALUE) or an HTTP one (`url` + `headers`).
    case mcpAdd(name: String, local: Bool = false, cwd: String? = nil, url: String? = nil, headers: [String] = [],
                command: String? = nil, args: [String] = [], env: [String] = [], exposure: String? = nil, description: String? = nil)
    case mcpRemove(name: String, local: Bool = false, cwd: String? = nil)
    /// `pi mcp logout`: forget the server's OAuth tokens (signing in needs a chat: `mcpSignin`).
    case mcpLogout(name: String, local: Bool = false, cwd: String? = nil)
    case authCheck(provider: String)
    case version

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        func put(_ k: String, _ v: String?) { if let v { o[k] = .string(v) } }
        switch self {
        case .install(let s, let l, let c), .remove(let s, let l, let c):
            if case .install = self { o["action"] = "install" } else { o["action"] = "remove" }
            o["source"] = .string(s); o["local"] = .bool(l); put("cwd", c)
        case .list(let c):
            o["action"] = "list"; put("cwd", c)
        case .update(let s, let e, let m, let a, let c):
            o["action"] = "update"; put("source", s); put("cwd", c)
            o["extensions"] = .bool(e); o["models"] = .bool(m); o["all"] = .bool(a)
        case .mcpList(let c):
            o["action"] = "mcp_list"; put("cwd", c)
        case .mcpAdd(let n, let l, let c, let u, let h, let cmd, let args, let env, let x, let d):
            o["action"] = "mcp_add"; o["name"] = .string(n); o["local"] = .bool(l); put("cwd", c)
            put("url", u); put("command", cmd); put("exposure", x); put("description", d)
            o["headers"] = .array(h.map(JSONValue.string))
            o["args"] = .array(args.map(JSONValue.string))
            o["env"] = .array(env.map(JSONValue.string))
        case .mcpRemove(let n, let l, let c), .mcpLogout(let n, let l, let c):
            if case .mcpRemove = self { o["action"] = "mcp_remove" } else { o["action"] = "mcp_logout" }
            o["name"] = .string(n); o["local"] = .bool(l); put("cwd", c)
        case .authCheck(let p):
            o["action"] = "auth_check"; o["provider"] = .string(p)
        case .version:
            o["action"] = "version"
        }
        return .object(o)
    }
}

/// A pi CLI job. Its output also streams on `/api/runs/events` as
/// `{"type":"job","id":…,"event":"start"|"output"|"end",…}`.
public struct PiJob: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var action: JSONValue
    public var argv: [String]
    /// "running", "ok" or "failed".
    public var status: String
    public var code: Int?
    public var output: String
    public var started: UInt64
    public var ended: UInt64?

    public var isRunning: Bool { status == "running" }
}

/// A quick pi CLI call: its exit code, output, and stdout parsed as JSON
/// when it is JSON. A non-zero code is information (auth "not ready", an MCP
/// server that didn't connect), not a failed request.
public struct PiCLIResult: Codable, Sendable, Equatable {
    public var code: Int?
    public var stdout: String
    public var stderr: String
    public var json: JSONValue?
}

/// `pi auth check`'s answer for one provider.
public struct PiAuthStatus: Sendable, Equatable {
    public var provider: String
    /// "ready", "not_ready" or "invalid".
    public var status: String
    public var reason: String?
    public var isReady: Bool { status == "ready" }

    init?(_ v: JSONValue?) {
        guard let v, let s = v["status"]?.string else { return nil }
        provider = v["provider"]?.string ?? ""
        status = s
        reason = v["reason"]?.string
    }
}

/// One of the chat's tools, from pocketpi-control's `/pp-tools`.
public struct PiTool: Sendable, Equatable, Identifiable, Hashable {
    public var name: String
    public var description: String?
    /// "direct", "codemode", "model-only", ...
    public var exposure: String?
    /// "builtin", "cli", a package...
    public var source: String?
    public var path: String?
    public var active: Bool
    public var id: String { name }

    init?(_ v: JSONValue) {
        guard let n = v["name"]?.string else { return nil }
        name = n
        description = v["description"]?.string
        exposure = v["exposure"]?.string
        source = v["source"]?.string
        path = v["path"]?.string
        active = v["active"]?.bool ?? false
    }
}

extension PocketPiClient {
    private static func query(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        return "?cwd=" + (cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? cwd)
    }

    // MARK: config files

    /// Read a config file (the project's with `cwd`, for settings and mcp).
    public func config(_ file: PiConfigFile, cwd: String? = nil) async throws -> PiConfigDocument {
        try await get("/api/pi/config/\(file.rawValue)\(Self.query(cwd))")
    }

    /// Change a config file; returns it as it is now. Chats keep their old
    /// settings until restarted (`reload()` or `restart(key:)`).
    @discardableResult
    public func patchConfig(_ file: PiConfigFile, _ patch: PiConfigPatch, cwd: String? = nil) async throws -> PiConfigDocument {
        try await post("/api/pi/config/\(file.rawValue)\(Self.query(cwd))", patch.json)
    }

    // MARK: restart and reload

    /// The running pis and which of them have old settings.
    public func piStatus() async throws -> PiStatus { try await get("/api/pi/status") }

    /// Restart the idle chats that have old settings (or every idle chat).
    public func reload(all: Bool = false) async throws -> PiReloadResult {
        try await post("/api/pi/reload", ["all": .bool(all)])
    }

    /// Restart one chat's pi on the same session file. The key stays the
    /// same: an open `ChatSession` reconnects by itself.
    @discardableResult
    public func restart(key: String) async throws -> PiRestartResult {
        try await post("/api/s/\(key)/restart", [:])
    }

    // MARK: pocketpi-control

    /// Run a pocketpi-control command in a chat's pi and return its data.
    /// Throws `.command` when the extension reports a failure.
    public func control(key: String, _ command: String, args: JSONValue? = nil) async throws -> JSONValue {
        var body: [String: JSONValue] = ["command": .string(command)]
        if let args { body["args"] = args }
        let r: JSONValue = try await post("/api/s/\(key)/control", .object(body))
        if r["success"]?.bool != true {
            throw PocketPiError.command(r["error"]?.string ?? "\(command) failed")
        }
        return r["data"] ?? .null
    }

    /// The chat's tools and which are on.
    public func tools(key: String) async throws -> [PiTool] {
        try await control(key: key, "tools")["tools"]?.array?.compactMap(PiTool.init) ?? []
    }

    /// Turn exactly these tools on for this chat; returns the tools after.
    @discardableResult
    public func setActiveTools(key: String, _ names: [String]) async throws -> [PiTool] {
        let data = try await control(key: key, "tools", args: ["active": .array(names.map(JSONValue.string))])
        return data["tools"]?.array?.compactMap(PiTool.init) ?? []
    }

    // MARK: pi CLI

    /// Start a pi CLI job; returns its id. 409 while another job runs.
    public func startJob(_ action: PiAction) async throws -> String {
        let r: JSONValue = try await post("/api/pi/jobs", action.json)
        guard let id = r["id"]?.string else { throw PocketPiError.unexpected("no job id in the answer") }
        return id
    }

    public func job(id: String) async throws -> PiJob {
        guard let j = try await get("/api/pi/jobs/\(id)", as: JSONValue.self)["job"] else {
            throw PocketPiError.unexpected("no job in the answer")
        }
        return try JSONDecoder().decode(PiJob.self, from: try j.encoded())
    }

    /// Recent jobs, newest first.
    public func jobs() async throws -> [PiJob] {
        struct R: Decodable { var jobs: [PiJob] }
        return try await get("/api/pi/jobs", as: R.self).jobs
    }

    /// `pi --version`, e.g. "1.5.0".
    public func piVersion() async throws -> String {
        try await get("/api/pi/version", as: JSONValue.self)["version"]?.string ?? ""
    }

    /// `pi auth check` for one provider.
    public func authCheck(provider: String) async throws -> PiAuthStatus {
        let p = provider.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? provider
        let r: PiCLIResult = try await get("/api/pi/auth/\(p)")
        guard let s = PiAuthStatus(r.json) else { throw PocketPiError.unexpected(r.stderr.isEmpty ? r.stdout : r.stderr) }
        return s
    }

    /// `pi mcp list --json`: `{servers: [...], errors: [...]}` in `json`.
    public func mcpList(cwd: String? = nil) async throws -> PiCLIResult {
        try await get("/api/pi/mcp\(Self.query(cwd))")
    }

    /// `pi list` (plain text in `stdout`).
    public func packages(cwd: String? = nil) async throws -> PiCLIResult {
        try await get("/api/pi/packages\(Self.query(cwd))")
    }
}
