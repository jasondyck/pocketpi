import Foundation

// The resource browser (plan F1; the server side is src/pi_resources.rs):
// pi's extensions, skills and prompt templates for a project, where each
// comes from and whether it loads. Each resource keeps its `toggle` (the
// settings array and entry a +/- override would use); Packages.swift turns
// it into a request for `/api/pi/resources/toggle`.

public enum PiResourceKind: String, Sendable, CaseIterable, Identifiable {
    case extensionFile = "extension", skill, prompt
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .extensionFile: "Extensions"
        case .skill: "Skills"
        case .prompt: "Prompt templates"
        }
    }
}

/// Where a resource comes from.
public enum PiResourceScope: String, Sendable, CaseIterable {
    case project, global, package, temporary, builtin

    public var label: String {
        switch self {
        case .builtin: "built-in"
        case .temporary: "-e"
        default: rawValue
        }
    }

    /// The order resources are listed in within a kind.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 9 }
}

/// The settings change that would turn a resource on or off.
public struct PiResourceToggle: Sendable, Equatable {
    /// `extensions`, `skills`, `prompts`, or `packages` (a package's filter).
    public var key: String
    /// "global" or "project".
    public var scope: String
    /// The exact entry, relative to the settings file's folder when inside it.
    public var entry: String?
    /// For package resources: the package's source.
    public var package: String?

    init?(_ v: JSONValue?) {
        guard let v, let k = v["key"]?.string, let s = v["scope"]?.string else { return nil }
        key = k; scope = s
        entry = v["entry"]?.string
        package = v["package"]?.string
    }
}

public struct PiResource: Sendable, Equatable, Identifiable {
    public var kind: PiResourceKind
    public var name: String
    public var description: String?
    public var argumentHint: String?
    /// The file (`builtin:<name>` for built-ins).
    public var path: String
    public var scope: PiResourceScope
    /// "auto" (folder scan), "settings", "package", "builtin" or "live".
    public var origin: String
    /// The package's source, for package resources.
    public var package: String?
    /// "user" or "project": which settings file names the package.
    public var packageScope: String?
    /// Not turned off by a settings override.
    public var enabled: Bool
    /// Enabled and not skipped: pi loads it.
    public var loads: Bool
    /// Why pi skips it even though it's enabled ("project not trusted").
    public var skipped: String?
    public var disabledBy: String?
    /// An extension's commands, from the running chat.
    public var commands: [String]
    /// Seen in the running chat's `get_commands`.
    public var live: Bool
    public var toggle: PiResourceToggle?
    public var id: String { kind.rawValue + ":" + path + ":" + name }

    init?(_ v: JSONValue) {
        guard let k = v["kind"]?.string.flatMap(PiResourceKind.init(rawValue:)), let n = v["name"]?.string else { return nil }
        kind = k
        name = n
        description = v["description"]?.string
        argumentHint = v["argumentHint"]?.string
        path = v["path"]?.string ?? ""
        scope = PiResourceScope(rawValue: v["scope"]?.string ?? "") ?? .global
        origin = v["origin"]?.string ?? "auto"
        package = v["package"]?["source"]?.string
        packageScope = v["package"]?["scope"]?.string
        enabled = v["enabled"]?.bool ?? true
        loads = v["loads"]?.bool ?? enabled
        skipped = v["skipped"]?.string
        disabledBy = v["disabledBy"]?.string
        commands = v["commands"]?.array?.compactMap(\.string) ?? []
        live = v["live"]?.bool ?? false
        toggle = PiResourceToggle(v["toggle"])
    }

    /// How it's used in a chat: `/fix-tests <file>`, `/skill:review`, or the
    /// extension's commands.
    public var invocation: String {
        switch kind {
        case .prompt: "/\(name)" + (argumentHint.map { " " + $0 } ?? "")
        case .skill: "/skill:\(name)"
        case .extensionFile: commands.map { "/" + $0 }.joined(separator: " ")
        }
    }

    /// The short tags under a row: scope, package, off/skipped, running.
    public var badges: [String] {
        var b = [scope.label]
        if let package { b.append(package.replacingOccurrences(of: "npm:", with: "").split(separator: "/").last.map(String.init) ?? package) }
        if !enabled { b.append("off") } else if let skipped { b.append(skipped == "project not trusted" ? "skipped: not trusted" : skipped) }
        if live { b.append("running") }
        return b
    }

    /// Why it does or doesn't load, in a sentence.
    public var loadsText: String {
        if loads { return "Yes" }
        if !enabled { return "No: " + (disabledBy ?? "turned off in settings") }
        return "No: " + (skipped ?? "skipped")
    }

    /// "folder scan", "settings entry", ...
    public var originText: String {
        ["auto": "folder scan", "settings": "settings entry", "package": "package", "builtin": "built in", "live": "the running chat"][origin] ?? origin
    }
}

public struct PiPackageInfo: Sendable, Equatable, Identifiable {
    public var source: String
    /// "user" or "project".
    public var scope: String
    public var installedPath: String?
    public var filtered: Bool
    public var id: String { scope + ":" + source }

    init?(_ v: JSONValue) {
        guard let s = v["source"]?.string else { return nil }
        source = s
        scope = v["scope"]?.string ?? "user"
        installedPath = v["installedPath"]?.string
        filtered = v["filtered"]?.bool ?? false
    }
}

/// One kind's resources, for a list section.
public struct PiResourceSection: Sendable, Equatable, Identifiable {
    public var kind: PiResourceKind
    public var items: [PiResource]
    public var id: PiResourceKind { kind }
}

/// `GET /api/pi/resources[?cwd=]`.
public struct PiResources: Sendable, Equatable {
    /// The project (canonical), or nil for global resources only.
    public var cwd: String?
    public var home: String
    public var resources: [PiResource]
    public var packages: [PiPackageInfo]
    public var packagesError: String?
    /// The project's trust, when a project was asked for.
    public var trust: ProjectTrust?
    public var defaultTrust: ProjectTrustDefault
    /// How many commands a chat open in the project reported, if one is.
    public var liveCommands: Int?
    public var liveError: String?

    public init(_ v: JSONValue) {
        cwd = v["cwd"]?.string
        home = v["home"]?.string ?? ""
        resources = v["resources"]?.array?.compactMap(PiResource.init) ?? []
        packages = v["packages"]?.array?.compactMap(PiPackageInfo.init) ?? []
        packagesError = v["packagesError"]?.string
        if case .object(var t)? = v["trust"] {
            t["path"] = .string(cwd ?? "")
            trust = ProjectTrust(.object(t))
        }
        defaultTrust = ProjectTrustDefault(rawValue: v["defaultTrust"]?.string ?? "ask") ?? .ask
        liveCommands = v["live"]?["commands"]?.int
        liveError = v["liveError"]?.string
    }

    /// One kind's resources, project first, then global, package, -e and
    /// built-in, each by name.
    public func list(_ kind: PiResourceKind) -> [PiResource] {
        resources.filter { $0.kind == kind }.sorted {
            ($0.scope.rank, $0.name.lowercased()) < ($1.scope.rank, $1.name.lowercased())
        }
    }

    /// Kinds to show for a filter (nil = all), with their resources.
    public func sections(_ filter: PiResourceKind?) -> [PiResourceSection] {
        PiResourceKind.allCases.filter { filter == nil || $0 == filter }.map { PiResourceSection(kind: $0, items: list($0)) }
    }

    /// The project isn't trusted but has things trust gates: say so.
    public var untrustedWarning: String? {
        guard let t = trust, t.needsTrust, !t.trusted else { return nil }
        let why = t.decision == nil ? " (no decision; the default is “\(defaultTrust.rawValue)”)" : ""
        return "This project isn't trusted, so pi skips its .pi resources\(why)."
    }

    public func tilde(_ p: String) -> String { ProjectTrust.tilde(p, home: home) }
}

extension PocketPiClient {
    /// What pi loads for `cwd` (or only the global resources).
    public func resources(cwd: String? = nil) async throws -> PiResources {
        var q = ""
        if let cwd, !cwd.isEmpty {
            q = "?cwd=" + (cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? cwd)
        }
        return PiResources(try await get("/api/pi/resources\(q)", as: JSONValue.self))
    }
}
