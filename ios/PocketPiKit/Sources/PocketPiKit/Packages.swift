import Foundation
import Observation

// Turning resources on and off, pi packages and the package gallery (plan
// F2, F3, F4; the server side is src/pi_packages.rs and src/pi_cli.rs).
// The web twins are web/manage-resources.js and web/manage-packages.js.

/// What a resource switch asks for.
public enum PiToggleState: String, Sendable, CaseIterable {
    case on, off
    /// Drop a project override, so the global setting applies.
    case inherit
}

extension PiResource {
    /// Whether a switch can change it (not `-e` extensions, not what only the
    /// running chat reported).
    public var canToggle: Bool { toggle != nil && scope != .temporary }

    /// A global file a project's settings name to override it (`pi config
    /// --local`): the scan lists it as the project's.
    public func isProjectOverride(cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        return scope == .project && origin == "settings" && !path.hasPrefix(cwd + "/")
    }

    /// A built-in whose project settings decide it.
    public var isBuiltinSetInProject: Bool { scope == .builtin && toggle?.scope == "project" }

    /// Global (or built-in): it can also be turned on or off in one project.
    public func canSetPerProject(cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty, canToggle, toggle?.key != "packages" else { return false }
        return scope == .global || scope == .builtin || isProjectOverride(cwd: cwd)
    }

    /// Its state in the project: `.inherit` when only global settings say.
    public func projectState(cwd: String?) -> PiToggleState {
        isProjectOverride(cwd: cwd) || isBuiltinSetInProject ? (enabled ? .on : .off) : .inherit
    }

    /// The body for `POST /api/pi/resources/toggle`. `projectOnly`: change it
    /// in the project `cwd` only (a global resource's override).
    public func toggleRequest(_ state: PiToggleState, cwd: String?, projectOnly: Bool = false) -> JSONValue? {
        guard let t = toggle, canToggle else { return nil }
        var o: [String: JSONValue] = ["kind": .string(kind.rawValue), "path": .string(path), "state": .string(state.rawValue)]
        if let cwd, !cwd.isEmpty { o["cwd"] = .string(cwd) }
        if t.key == "packages" {
            guard let source = t.package, let entry = t.entry else { return nil }
            o["scope"] = .string(t.scope)
            o["package"] = ["source": .string(source), "scope": .string(t.scope == "project" ? "project" : "user"), "entry": .string(entry)]
        } else if projectOnly || isProjectOverride(cwd: cwd) {
            o["scope"] = "project"
            o["override"] = .bool(scope != .builtin)
        } else {
            o["scope"] = .string(t.scope)
        }
        return .object(o)
    }

    /// Where a switch writes, in words.
    public func toggleWhere(cwd: String?) -> String {
        if toggle?.key == "packages" { return "in the package's settings entry" }
        return isProjectOverride(cwd: cwd) || toggle?.scope == "project" ? "in this project's settings" : "in global settings"
    }
}

/// `/api/pi/resources/toggle`'s answer.
public struct PiToggleResult: Sendable, Equatable {
    /// Whether pi loads it now (after a restart).
    public var enabled: Bool
    /// The settings key written: extensions, skills, prompts or packages.
    public var key: String
    public var scope: String
    public var entries: JSONValue

    init(_ v: JSONValue) {
        enabled = v["enabled"]?.bool ?? false
        key = v["key"]?.string ?? ""
        scope = v["scope"]?.string ?? "global"
        entries = v["entries"] ?? .null
    }
}

extension PiPackageInfo {
    /// "npm:@a/b@1.2" → "@a/b"; "git:github.com/x/y@v1" → "x/y"; a path → its folder.
    public var shortName: String { Self.shortName(source) }

    public static func shortName(_ src: String) -> String {
        if src.hasPrefix("npm:") {
            let s = String(src.dropFirst(4))
            if let at = s.dropFirst().firstIndex(of: "@") { return String(s[..<at]) }
            return s
        }
        for p in ["git:", "https://", "http://", "ssh://", "git@"] where src.hasPrefix(p) {
            var rest = String(src.dropFirst(p.count))
            if let at = rest.lastIndex(of: "@"), !rest[at...].contains("/") { rest = String(rest[..<at]) }
            if rest.hasSuffix(".git") { rest = String(rest.dropLast(4)) }
            let parts = rest.split(whereSeparator: { $0 == "/" || $0 == ":" })
            return parts.suffix(2).joined(separator: "/")
        }
        let trimmed = src.hasSuffix("/") ? String(src.dropLast()) : src
        return trimmed.split(separator: "/").last.map(String.init) ?? src
    }

    public var isProject: Bool { scope == "project" }
}

extension PiResources {
    /// What a package provides.
    public func resources(of p: PiPackageInfo) -> [PiResource] {
        resources.filter { $0.package == p.source && ($0.packageScope ?? "user") == p.scope }
    }

    /// "1 extension · 2 skills (1 off)".
    public func summary(of p: PiPackageInfo) -> String {
        let list = resources(of: p)
        let parts = PiResourceKind.allCases.compactMap { k -> String? in
            let n = list.filter { $0.kind == k }.count
            guard n > 0 else { return nil }
            let word = k == .extensionFile ? "extension" : k.rawValue
            return "\(n) \(word)\(n == 1 ? "" : "s")"
        }
        let off = list.filter { !$0.enabled }.count
        return (parts.isEmpty ? "nothing pi loads" : parts.joined(separator: " · ")) + (off > 0 ? " (\(off) off)" : "")
    }

    /// Packages, the project's first, then by name.
    public var sortedPackages: [PiPackageInfo] {
        packages.sorted { ($0.isProject ? 0 : 1, $0.shortName.lowercased()) < ($1.isProject ? 0 : 1, $1.shortName.lowercased()) }
    }

    /// Whether an npm package from the gallery is installed (any version, either scope).
    public func isInstalled(npm name: String) -> Bool {
        packages.contains { $0.source == "npm:\(name)" || $0.source.hasPrefix("npm:\(name)@") }
    }
}

/// One package from the gallery (npm, keyword `pi-package`).
public struct PiGalleryPackage: Sendable, Equatable, Identifiable {
    public var name: String
    public var version: String?
    public var description: String?
    public var date: String?
    public var publisher: String?
    public var npm: String?
    public var monthly: Int?
    /// What `pi install` takes: `npm:<name>`.
    public var source: String
    public var id: String { name }

    init?(_ v: JSONValue) {
        guard let n = v["name"]?.string else { return nil }
        name = n
        version = v["version"]?.string
        description = v["description"]?.string
        date = v["date"]?.string
        publisher = v["publisher"]?.string
        npm = v["npm"]?.string
        monthly = v["monthly"]?.int
        source = v["source"]?.string ?? "npm:\(n)"
    }

    /// "v1.2.0 · 3.1k/month · someone · 2026-11-07".
    public var line: String {
        var bits: [String] = []
        if let version { bits.append("v" + version) }
        if let monthly { bits.append(Self.short(monthly) + "/month") }
        if let publisher { bits.append(publisher) }
        if let date { bits.append(String(date.prefix(10))) }
        return bits.joined(separator: " · ")
    }

    public static func short(_ n: Int) -> String {
        func f(_ x: Double, _ unit: String) -> String {
            let s = String(format: "%.1f", x)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
        }
        if n >= 1_000_000 { return f(Double(n) / 1_000_000, "M") }
        if n >= 1_000 { return f(Double(n) / 1_000, "k") }
        return String(n)
    }
}

public struct PiGallery: Sendable, Equatable {
    public var total: Int
    public var packages: [PiGalleryPackage]

    public init(_ v: JSONValue) {
        packages = v["packages"]?.array?.compactMap(PiGalleryPackage.init) ?? []
        total = v["total"]?.int ?? packages.count
    }
}

/// One pi CLI job at a time for a page, with its output as it comes, for
/// the Packages and MCP pages' log.
@MainActor
@Observable
public final class PiJobLog {
    public private(set) var title = ""
    public private(set) var output = ""
    /// nil (nothing yet), "running", "ok" or "failed".
    public private(set) var status: String?
    public var busy: Bool { status == "running" }

    public init() {}

    /// "Installing x…", "Installing x: done", "Installing x: failed".
    public var headline: String {
        switch status {
        case "running": "\(title)…"
        case "ok": "\(title): done"
        case nil: ""
        default: "\(title): failed"
        }
    }

    /// Run `action`; nil when another job of this page is running. A request
    /// that fails (another client's job holds the runner: 409) ends as
    /// "failed" with the server's message.
    @discardableResult
    public func run(_ title: String, _ action: PiAction, client: PocketPiClient) async -> PiJob? {
        guard !busy else { return nil }
        self.title = title
        output = ""
        status = "running"
        do {
            let job = try await client.runJob(action) { text in await MainActor.run { self.output = text } }
            output = job.output
            status = job.status == "ok" ? "ok" : "failed"
            return job
        } catch {
            output = error.localizedDescription
            status = "failed"
            return nil
        }
    }
}

extension PocketPiClient {
    /// Turn a resource on or off (or drop its project override). Chats need
    /// a restart to see it (`SettingsHub.changed()`).
    @discardableResult
    public func setResource(_ r: PiResource, _ state: PiToggleState, cwd: String?, projectOnly: Bool = false) async throws -> PiToggleResult {
        guard let body = r.toggleRequest(state, cwd: cwd, projectOnly: projectOnly) else {
            throw PocketPiError.unexpected("\(r.name) can't be turned on or off here")
        }
        return PiToggleResult(try await post("/api/pi/resources/toggle", body, as: JSONValue.self))
    }

    /// npm packages with the `pi-package` keyword (searched by the server, cached 10 minutes).
    public func gallery(query: String = "") async throws -> PiGallery {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? ""
        return PiGallery(try await get("/api/pi/gallery?q=\(q)", as: JSONValue.self))
    }

    /// Start a job and wait for it, handing over its output as it grows.
    public func runJob(_ action: PiAction, every: Duration = .milliseconds(500), timeout: Duration = .seconds(900),
                       output: (@Sendable (String) async -> Void)? = nil) async throws -> PiJob {
        let id = try await startJob(action)
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: timeout)
        var seen = ""
        while true {
            let j = try await job(id: id)
            if j.output != seen { seen = j.output; await output?(j.output) }
            if !j.isRunning { return j }
            if clock.now > end { throw PocketPiError.unexpected("pi is taking too long") }
            try await Task.sleep(for: every)
        }
    }
}
