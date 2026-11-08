import PocketPiKit
import SwiftUI

// Settings › Safety: @gotgenes/pi-permission-system, its rules for chats, each
// project's Off / Ask / Strict, and the policy workflow stages run under.
// State and logic are PocketPiKit's SafetyModel; the web twin is
// web/manage-safety.js.

extension SettingsPage {
    static let safety = SettingsPage(id: "safety", title: "Safety", subtitle: "What pi may run without asking",
                                     systemImage: "checkmark.shield", order: 50) { SettingsSafetyPage() }
}

private struct SettingsSafetyPage: View {
    @Environment(SettingsHub.self) private var hub
    @State private var model: SafetyModel?

    var body: some View {
        Group {
            if let model, model.loaded {
                SafetyList(model: model)
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil { model = SafetyModel(client: hub.client) }
            await model?.load()
        }
        .refreshable { await model?.load() }
        .alert("Something went wrong", isPresented: Binding(
            get: { model?.problem != nil },
            set: { if !$0 { model?.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model?.problem ?? "")
        }
    }
}

private struct SafetyList: View {
    @Environment(SettingsHub.self) private var hub
    let model: SafetyModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text("@gotgenes/pi-permission-system")
                    Text(model.statusLine).font(.footnote).foregroundStyle(.secondary)
                }
                if !model.installed {
                    Button {
                        Task { if await model.install() { await hub.changed() } }
                    } label: {
                        Label("Install with recommended policy", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.working != nil)
                    .accessibilityIdentifier("safety-install")
                } else if !model.chats.exists {
                    Button("Use the recommended policy") { Task { await model.useRecommended(.chats) } }
                        .disabled(model.working != nil)
                }
                if let w = model.working { HStack { ProgressView(); Text(w).foregroundStyle(.secondary) } }
            } header: {
                Text("Permission system")
            } footer: {
                Text("This is pi's own policy file, so it applies to pi in the terminal too, not only to chats here. When pi asks and nobody has the chat open, your phone gets a notification. Changes apply from pi's next tool call.")
            }

            if model.installed || model.chats.exists {
                Section {
                    ForEach(model.chats.surfaces, id: \.self) { s in
                        NavigationLink {
                            RulesEditor(model: model, file: .chats, surface: s)
                        } label: {
                            RuleSummaryRow(surface: s, summary: model.chats.summary(for: s))
                        }
                    }
                } header: {
                    Text("Chats")
                } footer: {
                    Text("Later rules win. * matches anything, slashes included; ~ is your home folder.")
                }
            }

            Section {
                if model.projects.isEmpty { Text("No projects yet.").foregroundStyle(.secondary) }
                ForEach(model.projects) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.name)
                        Picker("Mode", selection: Binding(
                            get: { p.mode },
                            set: { m in Task { await model.setMode(m, for: p.path) } }
                        )) {
                            ForEach(modes(p.mode), id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(p.mode.explanation).font(.footnote).foregroundStyle(.secondary)
                        if !p.trusted {
                            Text("Not trusted: pi ignores this project's policy, so the global one applies.")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Projects")
            } footer: {
                Text("A project's policy lives in its .pi/extensions/pi-permission-system/config.json and only counts once pi trusts the project. It changes the global policy for that project; Off keeps the hard denies.")
            }

            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.stages.exists ? "Own policy" : "Same policy as chats")
                    Text(model.stages.exists
                         ? "Stages can't answer questions, so this policy never asks."
                         : "Stages can't answer questions: whatever would ask is denied. A stage policy allows normal build, test and commit work and denies the dangerous things.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.stages.exists {
                    ForEach(model.stages.surfaces, id: \.self) { s in
                        NavigationLink {
                            RulesEditor(model: model, file: .stages, surface: s)
                        } label: {
                            RuleSummaryRow(surface: s, summary: model.stages.summary(for: s))
                        }
                    }
                } else {
                    Button("Use the recommended stage policy") { Task { await model.useRecommended(.stages) } }
                        .disabled(model.working != nil)
                }
            } header: {
                Text("Workflow stages")
            }
        }
    }
}

/// The segments: Off / Ask / Strict, plus Custom while the project is custom.
private func modes(_ current: Safety.ProjectMode) -> [Safety.ProjectMode] {
    let base: [Safety.ProjectMode] = [.off, .standard, .strict]
    return current == .custom ? base + [.custom] : base
}

private struct RuleSummaryRow: View {
    let surface: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SafetyModel.label(surface))
            Text(summary).font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
    }
}

/// One rule list: change an action, delete, reorder, add.
private struct RulesEditor: View {
    let model: SafetyModel
    let file: PolicyFile
    let surface: String
    @State private var pattern = ""
    @State private var action = PolicyAction.ask

    private var rules: [PolicyRule] { (file == .chats ? model.chats : model.stages).rules(for: surface) }

    private func save(_ next: [PolicyRule]) { Task { await model.setRules(file, surface, next) } }

    var body: some View {
        List {
            Section {
                ForEach(rules) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.pattern).font(.callout.monospaced())
                            if let reason = r.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Menu {
                            ForEach(PolicyAction.allCases, id: \.self) { a in
                                Button(a.label) { save(rules.map { $0.pattern == r.pattern ? PolicyRule(pattern: r.pattern, action: a, reason: r.reason) : $0 }) }
                            }
                        } label: {
                            Text(r.action.label).font(.callout.monospaced())
                                .foregroundStyle(r.action == .deny ? Color.red : r.action == .ask ? Color.orange : Color.primary)
                        }
                    }
                }
                .onDelete { idx in save(rules.enumerated().filter { !idx.contains($0.offset) }.map(\.element)) }
                .onMove { from, to in var r = rules; r.move(fromOffsets: from, toOffset: to); save(r) }
            } footer: {
                Text("Later rules win.")
            }
            Section("Add a rule") {
                TextField(surface == "bash" ? "git push *" : "~/secrets/*", text: $pattern)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Action", selection: $action) {
                    ForEach(PolicyAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Button("Add") {
                    let p = pattern.trimmingCharacters(in: .whitespaces)
                    guard !p.isEmpty else { return }
                    save(rules.filter { $0.pattern != p } + [PolicyRule(pattern: p, action: action)])
                    pattern = ""
                }
                .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle(SafetyModel.label(surface))
        .toolbar { EditButton() }
    }
}
