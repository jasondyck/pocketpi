import Foundation
import Observation

/// Settings › Safety's state and actions, so the view only draws
/// (ios/PocketPi/Sources/SettingsSafetyPage.swift; the web twin is
/// web/manage-safety.js).
@MainActor
@Observable
public final class SafetyModel {
    public struct ProjectRow: Sendable, Equatable, Identifiable {
        public var path: String
        public var name: String
        public var mode: Safety.ProjectMode
        /// Whether pi trusts the project: the extension ignores an untrusted project's policy.
        public var trusted: Bool
        public var id: String { path }
    }

    public let client: PocketPiClient
    public private(set) var loaded = false
    public private(set) var installed = false
    public private(set) var chats = PolicyDocument()
    public private(set) var stages = PolicyDocument()
    public private(set) var projects: [ProjectRow] = []
    /// Something in progress ("Installing…"), for a spinner.
    public private(set) var working: String?
    public var problem: String?

    public init(client: PocketPiClient) {
        self.client = client
    }

    public func load() async {
        do {
            async let settings = client.config(.settings)
            async let c = client.policy(.chats)
            async let s = client.policy(.stages)
            async let t = try? client.config(.trust)
            async let p = try? client.projects()
            let set = try await settings
            installed = Safety.isInstalled(settings: set.data)
            chats = try await c
            stages = try await s
            let trust = await t?.data ?? [:]
            let defaultTrust = set.data["defaultProjectTrust"]?.string
            var rows: [ProjectRow] = []
            for pr in (await p?.projects ?? []).prefix(30) {
                let doc = (try? await client.policy(.chats, cwd: pr.path)) ?? PolicyDocument()
                rows.append(ProjectRow(path: pr.path, name: pr.name.isEmpty ? (pr.path as NSString).lastPathComponent : pr.name,
                                       mode: Safety.mode(of: doc),
                                       trusted: Safety.isTrusted(pr.path, trust: trust, defaultTrust: defaultTrust)))
            }
            projects = rows
            loaded = true
        } catch {
            problem = error.reportable
        }
    }

    private func run(_ what: String, _ body: () async throws -> Void) async {
        working = what
        defer { working = nil }
        do { try await body() } catch { problem = error.reportable }
    }

    /// Install the package and write the recommended chat policy. Returns
    /// true when chats need a restart to load it.
    @discardableResult
    public func install() async -> Bool {
        var ok = false
        await run("Installing…") {
            let job = try await client.installPermissionSystem()
            guard job.status == "ok" else {
                throw PocketPiError.unexpected("pi install failed: " + job.output.split(separator: "\n").suffix(3).joined(separator: " "))
            }
            ok = true
        }
        await load()
        return ok
    }

    public func useRecommended(_ file: PolicyFile) async {
        await run("Writing…") {
            let doc = try await client.useRecommendedPolicy(file)
            if file == .chats { chats = doc } else { stages = doc }
        }
    }

    public func setRules(_ file: PolicyFile, _ surface: String, _ rules: [PolicyRule]) async {
        await run("Saving…") {
            let doc = try await client.patchPolicy(file, Safety.setRules(surface, rules))
            if file == .chats { chats = doc } else { stages = doc }
        }
    }

    public func setMode(_ mode: Safety.ProjectMode, for path: String) async {
        guard mode != .custom else { return }
        await run("Saving…") {
            let doc = try await client.patchPolicy(.chats, Safety.patch(for: mode), cwd: path)
            if let i = projects.firstIndex(where: { $0.path == path }) { projects[i].mode = Safety.mode(of: doc) }
        }
    }

    /// The headline under the package name.
    public var statusLine: String {
        guard installed else { return "Not installed: pi runs every command without asking" }
        guard chats.exists else { return "Installed · no policy yet: everything asks" }
        return "Installed · " + Safety.timeoutText(chats.promptTimeoutMs)
    }

    /// Labels for the rule lists.
    public nonisolated static func label(_ surface: String) -> String {
        switch surface {
        case "bash": return "Commands (bash)"
        case "path": return "Files (path)"
        case "external_directory": return "Outside the project"
        case "path_read": return "Reading files"
        case "path_write": return "Writing files"
        case "external_directory_read": return "Reading outside the project"
        case "external_directory_write": return "Writing outside the project"
        default: return surface
        }
    }
}
