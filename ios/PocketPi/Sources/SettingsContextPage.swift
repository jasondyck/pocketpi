import PocketPiKit
import SwiftUI

// Settings › Context (docs/pi-parity-plan.md E6): pi's context files
// (AGENTS.md, AGENTS.override.md; CLAUDE.md read only) and system prompt
// files (SYSTEM.md, APPEND_SYSTEM.md), global and for a project, with what pi
// loads. Data and calls are PocketPiKit's PiContext.swift; the server is
// src/pi_context.rs; the web twin is web/manage-context.js.

extension SettingsPage {
    static let context = SettingsPage(id: "context", title: "Context", subtitle: "AGENTS.md, SYSTEM.md: what pi reads",
                                      systemImage: "doc.text", order: 35) { SettingsContextPage() }
}

private struct SettingsContextPage: View {
    @Environment(SettingsHub.self) private var hub
    @Environment(AppModel.self) private var app
    @State private var cwd = ""
    @State private var overview: PiContextOverview?
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                Picker("Project", selection: $cwd) {
                    Text("None: global files only").tag("")
                    ForEach(app.projects.filter(\.exists)) { p in Text(p.name).tag(p.path) }
                }
                .accessibilityIdentifier("context-project")
            } footer: {
                Text(note)
            }
            if let o = overview {
                Section(cwd.isEmpty ? "What pi loads everywhere" : "What pi loads here") {
                    ForEach(Array(o.context.enumerated()), id: \.offset) { i, c in
                        LabeledContent {
                            Text(c.scope == "parent" ? "folder above" : c.scope).font(.caption)
                        } label: {
                            Text("\(i + 1). \(Format.tilde(c.path, home: app.home))").font(.caption.monospaced())
                        }
                    }
                    if o.context.isEmpty { Text("No context files.").foregroundStyle(.secondary) }
                    LabeledContent("System prompt", value: o.system.map { Format.tilde($0.path, home: app.home) } ?? "pi's own")
                    if let a = o.append {
                        LabeledContent("Appended", value: Format.tilde(a.path, home: app.home))
                    }
                }
                ForEach(["global", "project"], id: \.self) { scope in
                    let files = o.files(scope: scope)
                    if !files.isEmpty {
                        Section(scope == "global" ? "Global · \(Format.tilde(o.agentDir, home: app.home))"
                                : "Project · \(Format.tilde(o.cwd ?? "", home: app.home))") {
                            ForEach(files) { f in
                                NavigationLink {
                                    ContextFileEditor(file: f, cwd: cwd, maxBytes: o.maxBytes) { await load() }
                                } label: {
                                    fileRow(f, o)
                                }
                            }
                        }
                    }
                }
            } else if problem == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: cwd) { await load() }
        .refreshable { await load() }
        .alert("Context", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var note: String {
        var s = "pi puts these files in every chat's system prompt when the chat starts; open chats need a restart to see a change. Context files load from the agent folder, the project and every folder above it, without project trust. A project's own .pi/SYSTEM.md and .pi/APPEND_SYSTEM.md win over the global ones (not combined), once pi trusts the project."
        if overview?.trusted == false { s += " This project isn't trusted (Settings › Project trust)." }
        return s
    }

    private func fileRow(_ f: PiContextFile, _ o: PiContextOverview) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.callout.monospaced())
                Text([f.role, f.editable ? nil : "read only"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(f.loaded ? "Loaded" : f.exists ? "Not used" : "None")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(f.loaded ? Color.green : .secondary)
        }
        .accessibilityIdentifier("context-\(f.scope)-\(f.name)")
    }

    private func load() async {
        do {
            overview = try await hub.client.contextOverview(cwd: cwd.isEmpty ? nil : cwd)
        } catch {
            problem = error.reportable
        }
    }
}

private struct ContextFileEditor: View {
    let file: PiContextFile
    let cwd: String
    let maxBytes: Int
    let saved: () async -> Void
    @Environment(SettingsHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var problem: String?
    @State private var confirmDelete = false

    private var projectCwd: String? { file.scope == "project" ? cwd : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $text)
                .font(.footnote.monospaced())
                .disabled(!file.editable)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("context-editor")
            Text(footnote).font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if file.editable {
                ToolbarItem(placement: .confirmationAction) {
                    Button(file.exists ? "Save" : "Create") { Task { await save() } }.disabled(!loaded)
                }
                if file.exists {
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Delete", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
        .confirmationDialog("Delete \(file.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The current text is kept as a .pocketpi.bak backup.")
        }
        .task {
            do {
                text = try await hub.client.contextFile(scope: file.scope, name: file.name, cwd: projectCwd).content
                loaded = true
            } catch {
                problem = error.reportable
            }
        }
        .alert(file.name, isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var footnote: String {
        var notes = [file.path]
        if !file.editable { notes.append("pocketpi shows \(file.name) but doesn't edit it; an AGENTS.md in the same folder is read instead.") }
        if file.kind == "system" { notes.append("SYSTEM.md replaces pi's whole system prompt, tool instructions included. APPEND_SYSTEM.md is usually what you want.") }
        if file.scope == "project", file.kind != "context" { notes.append("Only read once pi trusts the project.") }
        return notes.joined(separator: "\n")
    }

    private func save() async {
        guard text.utf8.count <= maxBytes else { problem = "At most \(maxBytes / 1024) KB"; return }
        do {
            try await hub.client.saveContextFile(scope: file.scope, name: file.name, cwd: projectCwd, content: text)
            await hub.changed()
            await saved()
            dismiss()
        } catch {
            problem = error.reportable
        }
    }

    private func delete() async {
        do {
            try await hub.client.deleteContextFile(scope: file.scope, name: file.name, cwd: projectCwd)
            await hub.changed()
            await saved()
            dismiss()
        } catch {
            problem = error.reportable
        }
    }
}
