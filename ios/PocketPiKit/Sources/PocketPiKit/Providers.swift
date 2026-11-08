import Foundation

// Settings › Providers (src/pi_providers.rs): which model providers pi can
// use, from `pi auth check` for each, and API keys for the ones that take
// one. Keys go to the server and never come back; OAuth sign-ins stay in a
// terminal (pi → /login <provider>). The web twin is web/manage-providers.js.

/// One provider as `/api/pi/providers` reports it.
public struct PiProvider: Sendable, Equatable, Identifiable, Hashable {
    /// What pi's `auth check` said, simplified.
    public enum Status: String, Sendable, Equatable, Hashable {
        case ready
        case invalid
        /// No credential pi can find.
        case notConfigured = "not_configured"
        /// Saved, but pi's CLI can't check it (extension providers like llama.cpp).
        case unknown
    }

    /// What `auth.json` holds for it: the kind and whether there is a secret, never the secret.
    public struct Stored: Sendable, Equatable, Hashable {
        /// "api_key", "oauth", ...
        public var type: String
        public var hasKey: Bool
    }

    public var id: String
    public var name: String
    /// "builtin", "custom" (models.json) or "stored" (only in auth.json).
    public var source: String
    /// One of the providers shown before "more providers".
    public var common: Bool
    /// Takes an API key; the page can add one.
    public var apiKey: Bool
    /// Has an OAuth sign-in (in pi's terminal UI).
    public var oauth: Bool
    /// That sign-in is a subscription (ChatGPT, SuperGrok, Claude...).
    public var subscription: Bool
    /// Environment variables pi would read a key from.
    public var env: [String]
    /// Those of them set in pocketpi's environment (names only).
    public var envSet: [String]
    public var stored: Stored?
    public var status: Status
    /// pi's reason, e.g. "credentials_not_configured", "invalid_state".
    public var reason: String?
    /// How pi authenticates when ready: "api_key" or "oauth".
    public var authType: String?
    /// The command to type in pi, e.g. "/login xai".
    public var login: String

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.string else { return nil }
        self.id = id
        name = v["name"]?.string ?? id
        source = v["source"]?.string ?? "builtin"
        common = v["common"]?.bool ?? false
        apiKey = v["apiKey"]?.bool ?? false
        oauth = v["oauth"]?.bool ?? false
        subscription = v["subscription"]?.bool ?? false
        env = v["env"]?.array?.compactMap(\.string) ?? []
        envSet = v["envSet"]?.array?.compactMap(\.string) ?? []
        if let s = v["stored"], s.object != nil {
            stored = Stored(type: s["type"]?.string ?? "unknown", hasKey: s["hasKey"]?.bool ?? false)
        }
        status = Status(rawValue: v["status"]?.string ?? "") ?? .unknown
        reason = v["reason"]?.string
        authType = v["authType"]?.string
        login = v["login"]?.string ?? "/login \(id)"
    }

    /// Ready, broken, or saved: listed under "Set up".
    public var isSetUp: Bool { status == .ready || status == .invalid || stored != nil }
    /// An API key pocketpi saved (or pi's /login did) that can be replaced or removed here.
    public var hasStoredKey: Bool { stored?.type == "api_key" && stored?.hasKey == true }
    public var isSignedIn: Bool { stored?.type == "oauth" }
    /// Show the terminal sign-in command.
    public var needsTerminal: Bool { oauth || !apiKey }

    /// The status as a short label.
    public var statusLabel: String {
        switch status {
        case .ready: "Ready"
        case .invalid: "Invalid"
        case .notConfigured: "Not set up"
        case .unknown: "Unchecked"
        }
    }

    /// How it is (or could be) set up, one line.
    public var detail: String {
        if isSignedIn { return "Signed in" + (subscription ? " (subscription)" : "") }
        if hasStoredKey { return "API key saved in pi" }
        if let v = envSet.first { return "From $\(v)" }
        if status == .ready, let t = authType { return t == "oauth" ? "Signed in" : "API key" }
        if stored != nil { return status == .unknown ? "Saved in pi; the CLI can't check it" : "Saved in pi" }
        if apiKey, let v = env.first { return "Add a key, or set \(v)" }
        if apiKey { return "Add an API key" }
        return oauth ? "Sign in from a terminal" : "Set up from a terminal"
    }

    /// pi's reason in words, when it says more than the status does.
    public var reasonText: String? {
        guard let r = reason, r != "credentials_not_configured" else { return nil }
        switch r {
        case "provider_not_found": return "pi's CLI can't check this provider"
        case "invalid_state": return "The saved sign-in doesn't work any more (expired or revoked)"
        default: return r.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// The whole answer: every provider plus the default and fallback models.
public struct PiProvidersReport: Sendable, Equatable {
    public var providers: [PiProvider]
    /// settings.json's defaultProvider / defaultModel.
    public var defaultProvider: String?
    public var defaultModel: String?
    /// Where the subscription-fallback extension switches to, e.g. "opencode-go/deepseek-v4.1-flash".
    public var fallbackModel: String?
    public var fallbackProvider: String?
    /// The subscription providers it falls back from.
    public var fallbackFrom: [String]
    /// When pi was asked (ms since 1970).
    public var checked: UInt64?
    public var cached: Bool

    init(_ v: JSONValue) {
        providers = v["providers"]?.array?.compactMap(PiProvider.init) ?? []
        let m = v["models"]
        defaultProvider = m?["default"]?["provider"]?.string
        defaultModel = m?["default"]?["model"]?.string
        fallbackModel = m?["fallback"]?["model"]?.string
        fallbackProvider = m?["fallback"]?["provider"]?.string
        fallbackFrom = m?["fallback"]?["from"]?.array?.compactMap(\.string) ?? []
        checked = v["checked"]?.double.map { UInt64($0) }
        cached = v["cached"]?.bool ?? false
    }

    public var setUp: [PiProvider] { providers.filter(\.isSetUp) }
    public var popular: [PiProvider] { providers.filter { !$0.isSetUp && $0.common } }
    public var more: [PiProvider] { providers.filter { !$0.isSetUp && !$0.common } }

    /// "xai/grok-4.3", when settings.json names both.
    public var defaultLabel: String? {
        guard let p = defaultProvider, let m = defaultModel else { return nil }
        return "\(p)/\(m)"
    }

    public func provider(_ id: String) -> PiProvider? { providers.first { $0.id == id } }

    /// The fallback's provider isn't ready, so a hit usage limit has nowhere to go.
    public var fallbackBroken: Bool {
        guard let id = fallbackProvider, let p = provider(id) else { return false }
        return p.status != .ready
    }

    /// Put a re-checked row in place (after a key change).
    public mutating func replace(_ p: PiProvider) {
        if let i = providers.firstIndex(where: { $0.id == p.id }) { providers[i] = p } else { providers.append(p) }
    }
}

public enum ProviderKey {
    /// Why `key` can't be saved, or nil. The server checks the same: literal
    /// keys only, since a value starting with "!" is a command pi would run.
    public static func problem(_ key: String) -> String? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { return "Paste a key first." }
        if k.hasPrefix("!") { return "Keys starting with ! are commands pi runs. Set those up in auth.json from a terminal." }
        if k.contains(where: { $0.isWhitespace || $0.isNewline }) { return "An API key has no spaces or line breaks." }
        if k.count > 4096 { return "That key is too long." }
        return nil
    }
}

extension PocketPiClient {
    private static func providerPath(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? id
    }

    /// Every provider with pi's verdict. Cached on the server for a few
    /// seconds; `refresh` asks pi again.
    public func providers(refresh: Bool = false) async throws -> PiProvidersReport {
        PiProvidersReport(try await get("/api/pi/providers\(refresh ? "?refresh=1" : "")", as: JSONValue.self))
    }

    /// Save (or replace) an API key. Returns the provider re-checked; the key
    /// itself never comes back. Chats need a restart to use it.
    @discardableResult
    public func setProviderKey(_ id: String, key: String) async throws -> PiProvider {
        if let p = ProviderKey.problem(key) { throw PocketPiError.command(p) }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let r: JSONValue = try await post("/api/pi/providers/\(Self.providerPath(id))/key", ["key": .string(k)])
        guard let p = r["provider"].flatMap(PiProvider.init) else { throw PocketPiError.unexpected("no provider in the answer") }
        return p
    }

    /// Remove a saved API key (not an OAuth sign-in: that's `/logout` in pi).
    @discardableResult
    public func removeProviderKey(_ id: String) async throws -> PiProvider {
        let r: JSONValue = try await post("/api/pi/providers/\(Self.providerPath(id))/remove", [:])
        guard let p = r["provider"].flatMap(PiProvider.init) else { throw PocketPiError.unexpected("no provider in the answer") }
        return p
    }
}
