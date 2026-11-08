import PocketPiKit
import SwiftUI

// Parts of Settings › pi settings (SettingsPiPage.swift) kept out of that
// file: the Global/Project switch, the default-tools rows (F6) and the
// settings.json editor checked against pi's schema (E3). Logic is
// PocketPiKit's DefaultTools.swift and PiContext.swift; the web twin is
// web/manage-settings.js.

extension EnvironmentValues {
    /// The page edits a project's .pi/settings.json, not the global file.
    @Entry var settingsProjectScope = false
}

/// Global / Project, which project, and what that means.
struct ScopeSection: View {
    @Binding var scope: SettingsScope
    let projects: [Project]
    let path: String
    let trusted: Bool?

    var body: some View {
        Section {
            Picker("Scope", selection: Binding(
                get: { scope.isProject },
                set: { project in
                    if !project { scope = .global } else if let first = projects.first(where: \.exists) { scope = .project(first.path) }
                }
            )) {
                Text("Global").tag(false)
                Text("Project").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(projects.isEmpty && !scope.isProject)
            .accessibilityIdentifier("settings-scope")
            if let cwd = scope.cwd {
                Picker("Project", selection: Binding(get: { cwd }, set: { scope = .project($0) })) {
                    ForEach(projects.filter(\.exists)) { p in Text(p.name).tag(p.path) }
                    if !projects.contains(where: { $0.path == cwd }) { Text(cwd).tag(cwd) }
                }
            }
            Label {
                Text(explanation).font(.footnote)
            } icon: {
                Image(systemName: scope.isProject ? "folder" : "globe")
            }
            .foregroundStyle(.secondary)
        }
    }

    private var explanation: String {
        if scope.isProject {
            let trust = trusted == false ? " pi doesn't trust this project yet, so it ignores this file (Settings › Project trust)." : ""
            return "\(path) applies on top of the global settings for chats in this project; unset keys inherit them.\(trust) Open chats pick changes up after a restart."
        }
        return "These are pi's own settings in \(path). Terminal pi and workflow stages use them too; open chats pick changes up after a restart."
    }
}

/// `defaultTools`: a switch per tool for what new chats start with.
struct DefaultToolsRows: View {
    let data: JSONValue
    let globalData: JSONValue
    let project: Bool
    let write: (PiConfigPatch) -> Void

    private var list: [DefaultTools.Entry]? { DefaultTools.parse(data["defaultTools"]) }
    private var inherited: [String] {
        project ? DefaultTools.resolve(DefaultTools.parse(globalData["defaultTools"])) : DefaultTools.piDefault
    }

    var body: some View {
        let selection = DefaultTools.resolve(list, inherited: inherited)
        VStack(alignment: .leading, spacing: 2) {
            Text("Default tools")
            Text("What new chats start with. \(DefaultTools.explain(list, project: project)) A chat's own tools: its title menu › Tools.")
                .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("\(selection.count) on: \(selection.joined(separator: ", "))") {
            ForEach(DefaultTools.offered(list, inherited: inherited), id: \.self) { name in
                Toggle(isOn: Binding(
                    get: { selection.contains(name) },
                    set: { on in write(DefaultTools.patch(DefaultTools.toggling(list, name, on: on, inherited: inherited))) }
                )) {
                    Text(name).font(.callout.monospaced())
                }
                .accessibilityIdentifier("default-tool-\(name)")
            }
        }
        .font(.callout)
        if let list {
            HStack {
                Text(list.isEmpty ? "[] (none)" : list.map(\.raw).joined(separator: ", "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button(project ? "Inherit" : "Reset") { write(DefaultTools.patch(nil)) }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// "Edit as JSON": the whole file, checked against pi's schema.
struct RawSettingsSection: View {
    let scope: SettingsScope
    let saved: () async -> Void

    var body: some View {
        Section {
            NavigationLink {
                RawSettingsEditor(scope: scope, saved: saved)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit as JSON")
                    Text("The whole file, checked against pi's schema before it's saved. The old version is kept as a backup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("settings-raw")
        } header: {
            Text("settings.json")
        }
    }
}

private struct RawSettingsEditor: View {
    let scope: SettingsScope
    let saved: () async -> Void
    @Environment(SettingsHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State private var raw: PiRawSettings?
    @State private var text = ""
    @State private var problems: [String] = []
    @State private var fine = false
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 8)
                .onChange(of: text) { problems = []; fine = false }
                .accessibilityIdentifier("raw-editor")
            if !problems.isEmpty || fine {
                ScrollView {
                    Text(fine ? "Looks right to pi's schema." : problems.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(fine ? Color.secondary : Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 140)
                .background(.thinMaterial)
            }
        }
        .navigationTitle(scope.isProject ? "Project settings.json" : "settings.json")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) { Button("Check") { Task { await check() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(saving || raw == nil)
            }
        }
        .task {
            do {
                let r = try await hub.client.rawSettings(cwd: scope.cwd)
                raw = r
                text = r.editorText
            } catch {
                problems = [error.reportable ?? "Couldn't read settings.json"]
            }
        }
    }

    private func check() async {
        if let p = RawSettings.syntaxProblem(text) { problems = [p]; return }
        do {
            let found = try await hub.client.checkRawSettings(text, cwd: scope.cwd)
            problems = found.map(\.line)
            fine = found.isEmpty
        } catch {
            problems = [error.reportable ?? "Check failed"]
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await hub.client.saveRawSettings(text, cwd: scope.cwd)
            await saved()
            dismiss()
        } catch {
            problems = (error.reportable ?? "Not saved").split(separator: "\n").map(String.init)
        }
    }
}
