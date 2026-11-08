import PocketPiKit
import SwiftUI

// Settings › Resources (plan F1, F2): pi's extensions, skills and prompt
// templates for a project, where each comes from and whether it loads, and
// switches (swipe a row, or in its details; a global one can also be set
// for the picked project only). The web twin is web/manage-resources.js;
// the logic is PocketPiKit's Resources.swift and Packages.swift.

extension SettingsPage {
    static let resources = SettingsPage(id: "resources", title: "Resources", subtitle: "Extensions, skills and prompt templates",
                                        systemImage: "square.stack.3d.up", order: 40) { SettingsResourcesPage() }
}

private struct SettingsResourcesPage: View {
    @Environment(SettingsHub.self) private var hub
    @State private var projects: [Project] = []
    /// "" = no project: global resources only.
    @State private var project = ""
    @State private var filter: PiResourceKind?
    @State private var data: PiResources?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Picker("Project", selection: $project) {
                    Text("No project").tag("")
                    ForEach(projects) { p in Text(p.name).tag(p.path) }
                }
                .accessibilityIdentifier("resources-project")
                if let d = data {
                    if let w = d.untrustedWarning {
                        Label(w, systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(.orange)
                    }
                    if let n = d.liveCommands {
                        Text("An open chat here reports \(n) command\(n == 1 ? "" : "s"); “running” marks what its pi loaded.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let e = d.liveError {
                        Text("Couldn't ask the open chat: \(e)").font(.footnote).foregroundStyle(.orange)
                    } else if !project.isEmpty {
                        Text("From the files. Open a chat in this project to also see what pi really loaded.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Picker("Show", selection: $filter) {
                    Text("All").tag(PiResourceKind?.none)
                    ForEach(PiResourceKind.allCases) { k in Text(k.title).tag(PiResourceKind?.some(k)) }
                }
                .pickerStyle(.segmented)
            }
            if let d = data {
                ForEach(d.sections(filter)) { section in
                    Section(section.kind.title) {
                        if section.items.isEmpty { Text("None").foregroundStyle(.secondary) }
                        ForEach(section.items) { r in
                            NavigationLink {
                                ResourceDetail(resource: r, data: d, project: project) { await load() }
                            } label: { ResourceRow(resource: r) }
                            .swipeActions(edge: .trailing) {
                                if r.canToggle {
                                    Button(r.enabled ? "Turn off" : "Turn on") { Task { await set(r, r.enabled ? .off : .on) } }
                                        .tint(r.enabled ? .orange : .green)
                                }
                            }
                        }
                    }
                }
                if filter == nil {
                    Section("Packages") {
                        if d.packages.isEmpty { Text("No packages").foregroundStyle(.secondary) }
                        ForEach(d.packages) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.source).font(.footnote.monospaced())
                                Text("\(p.scope == "project" ? "project" : "global")\(p.filtered ? " · filtered" : "") · \(p.installedPath.map(d.tilde) ?? "not installed")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let e = d.packagesError { Text("pi list: \(e)").font(.footnote).foregroundStyle(.orange) }
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .task(id: project) { await load() }
        .refreshable { await load() }
    }

    private func set(_ r: PiResource, _ state: PiToggleState) async {
        do {
            try await hub.client.setResource(r, state, cwd: data?.cwd ?? (project.isEmpty ? nil : project))
            await hub.changed()
            await load()
        } catch {
            hub.problem = error.reportable
        }
    }

    private func load() async {
        if projects.isEmpty, let p = try? await hub.client.projects() { projects = p.projects }
        do {
            data = try await hub.client.resources(cwd: project.isEmpty ? nil : project)
            error = nil
        } catch {
            self.error = error.reportable
        }
    }
}

private struct ResourceRow: View {
    let resource: PiResource

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.body.monospaced()).strikethrough(!resource.loads).foregroundStyle(resource.loads ? .primary : .secondary)
                if let h = resource.argumentHint, resource.kind == .prompt { Text(h).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            if let d = resource.description { Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 4) {
                ForEach(resource.badges + resource.commands.map { "/" + $0 }, id: \.self) { b in
                    Text(b).font(.caption2.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(b == "running" ? Color.green : b == "off" || b.hasPrefix("skipped") ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private var title: String {
        switch resource.kind {
        case .prompt: "/" + resource.name
        case .skill: "/skill:" + resource.name
        case .extensionFile: resource.name
        }
    }
}

private struct ResourceDetail: View {
    @Environment(SettingsHub.self) private var hub
    @State private var resource: PiResource
    let data: PiResources
    let project: String
    let reload: () async -> Void
    @State private var busy = false

    init(resource: PiResource, data: PiResources, project: String, reload: @escaping () async -> Void) {
        _resource = State(initialValue: resource)
        self.data = data
        self.project = project
        self.reload = reload
    }

    private var cwd: String? { data.cwd ?? (project.isEmpty ? nil : project) }

    var body: some View {
        List {
            if resource.canToggle {
                Section {
                    Toggle("On", isOn: Binding(get: { resource.enabled }, set: { on in Task { await set(on ? .on : .off, projectOnly: false) } }))
                        .disabled(busy)
                        .accessibilityIdentifier("resource-toggle")
                } footer: {
                    Text("Changes it \(resource.toggleWhere(cwd: cwd)). Chats pick it up when they restart.")
                }
                if resource.canSetPerProject(cwd: cwd) {
                    Section {
                        Picker("In this project", selection: Binding(get: { resource.projectState(cwd: cwd) },
                                                                    set: { s in Task { await set(s, projectOnly: true) } })) {
                            Text("Like global").tag(PiToggleState.inherit)
                            Text("On").tag(PiToggleState.on)
                            Text("Off").tag(PiToggleState.off)
                        }
                        .pickerStyle(.segmented)
                        .disabled(busy)
                    } header: {
                        Text("In this project only")
                    } footer: {
                        if data.trust?.trusted == false { Text("pi ignores this project's settings until it's trusted.") }
                    }
                }
            }
            if let d = resource.description { Section { Text(d) } }
            Section {
                if !resource.invocation.isEmpty { LabeledContent("Command", value: resource.invocation) }
                LabeledContent("Path") { Text(data.tilde(resource.path)).font(.footnote.monospaced()).textSelection(.enabled) }
                LabeledContent("Scope", value: resource.scope.label)
                LabeledContent("Found by", value: resource.originText)
                if let p = resource.package { LabeledContent("Package", value: p) }
                LabeledContent("Loads", value: resource.loadsText)
                if let t = resource.toggle, let e = t.entry, t.key != "packages" {
                    LabeledContent("Settings entry", value: "\(t.scope) \(t.key): \(e)")
                }
            }
        }
        .navigationTitle(resource.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func set(_ state: PiToggleState, projectOnly: Bool) async {
        busy = true
        defer { busy = false }
        do {
            try await hub.client.setResource(resource, state, cwd: cwd, projectOnly: projectOnly)
            await hub.changed()
            await reload()
            // A project override makes it the project's row: read it again.
            if let fresh = try? await hub.client.resources(cwd: cwd),
               let r = fresh.resources.first(where: { $0.kind == resource.kind && $0.path == resource.path }) {
                resource = r
            }
        } catch {
            hub.problem = error.reportable
        }
    }
}
