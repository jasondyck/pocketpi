import PocketPiKit
import SwiftUI

// Settings › Project trust (plan E5): which projects may load their own .pi
// resources, and the default for the rest. The web twin is
// web/manage-trust.js; the logic is PocketPiKit's Trust.swift.

extension SettingsPage {
    static let trust = SettingsPage(id: "trust", title: "Project trust", subtitle: "Which projects may load their own .pi resources",
                                    systemImage: "checkmark.shield", order: 30) { SettingsTrustPage() }
}

private struct SettingsTrustPage: View {
    @Environment(SettingsHub.self) private var hub
    @State private var overview: TrustOverview?
    @State private var home = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("A project's .pi folder can hold extensions (code that runs inside pi), skills, prompts, settings and MCP servers. pi only loads them for trusted projects. AGENTS.md and CLAUDE.md load either way.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let e = overview?.error {
                    Text(e + " pocketpi won't change it until it is fixed.").font(.footnote).foregroundStyle(.red)
                }
            }
            if let o = overview {
                Section("Projects without a decision") {
                    ForEach(ProjectTrustDefault.allCases) { d in
                        Button { Task { await write { try await hub.client.setDefaultProjectTrust(d) } } } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: o.defaultTrust == d ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(o.defaultTrust == d ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.title).foregroundStyle(.primary)
                                    Text(d.explanation).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(o.defaultTrust == d)
                        .accessibilityIdentifier("trust-default-\(d.rawValue)")
                    }
                }
                Section("Projects") {
                    if o.projects.isEmpty { Text("No projects yet.").foregroundStyle(.secondary) }
                    ForEach(o.projects) { p in
                        ProjectTrustRow(project: p, summary: p.summary(default: o.defaultTrust, home: home)) { choice in
                            Task { await write { try await hub.client.setTrust(choice, for: p.canonical) } }
                        }
                    }
                }
                if !o.otherEntries.isEmpty {
                    Section("Other saved decisions") {
                        ForEach(o.otherEntries, id: \.path) { e in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(e.path).font(.footnote.monospaced())
                                    Text(e.trusted ? "trusted" : "not trusted").font(.caption).foregroundStyle(e.trusted ? .green : .orange)
                                }
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    Task { await write { try await hub.client.setTrust(.none, for: e.path) } }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section {
                    Text("Saved in \(o.path). A decision for a folder also covers the folders inside it. Chats pick changes up when they restart.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            async let o = hub.client.trustOverview()
            async let p = try? hub.client.projects()
            overview = try await o
            home = await p?.home ?? home
            error = nil
        } catch {
            self.error = error.reportable
        }
    }

    private func write(_ change: () async throws -> PiConfigDocument) async {
        do {
            _ = try await change()
            await hub.changed()
        } catch {
            hub.problem = error.reportable
        }
        await load()
    }
}

private struct ProjectTrustRow: View {
    let project: ProjectTrust
    let summary: String
    let choose: (TrustChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(project.name).font(.body.weight(.medium))
            Text(project.canonical).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(summary).font(.footnote).foregroundStyle(project.trusted ? .green : .orange)
            if project.needsTrust {
                Text(project.protected.joined(separator: "  ")).font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                Text("Nothing in it needs trust right now.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Trust", selection: Binding(get: { project.choice }, set: { if $0 != project.choice { choose($0) } })) {
                Text("Trust").tag(TrustChoice.trust)
                Text("Don't trust").tag(TrustChoice.distrust)
                Text(project.noneLabel).tag(TrustChoice.none)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("trust-\(project.name)")
        }
        .padding(.vertical, 4)
    }
}
