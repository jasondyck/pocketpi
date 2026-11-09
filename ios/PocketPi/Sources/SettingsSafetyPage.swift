import PocketPiKit
import SwiftUI

// Settings › Safety: @gotgenes/pi-permission-system, auto review
// (@mzwing/pi-permission-auto-review: a model answers the chat policy's asks),
// its rules for chats, each project's Off / Ask / Strict, and the policy
// workflow stages run under.
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

            if model.installed {
                Section {
                    if model.autoReviewInstalled {
                        Toggle(isOn: Binding(
                            get: { model.autoReviewOn },
                            set: { on in Task { if await model.setAutoReview(on) { await hub.changed() } } }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Auto review")
                                Text(AutoReview.status(installed: true, on: model.autoReviewOn))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(model.working != nil)
                        .accessibilityIdentifier("safety-auto-review")
                        AutoReviewSettings(model: model)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Auto review")
                            Text(AutoReview.status(installed: false, on: false)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button {
                            Task { if await model.installAutoReview() { await hub.changed() } }
                        } label: {
                            Label("Install auto review", systemImage: "arrow.down.circle")
                        }
                        .disabled(model.working != nil)
                        .accessibilityIdentifier("safety-auto-review-install")
                    }
                } header: {
                    Text("Auto review")
                } footer: {
                    if !model.autoReviewInstalled { AutoReviewFootnote() }
                }

                if model.autoReviewInstalled {
                    Section {
                        if model.reviews.isEmpty { Text("No reviews yet.").foregroundStyle(.secondary) }
                        ForEach(model.reviews) { ReviewRow(review: $0) }
                    } header: {
                        Text("Recent reviews")
                    } footer: {
                        AutoReviewFootnote()
                    }
                }
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

private struct AutoReviewFootnote: View {
    var body: some View {
        Text("Each review sends your recent messages and the agent's recent tool calls to the review model's provider. Changes apply to chats started or restarted after them. Turning it on also stops the agent from writing pi's settings, packages and permission policies.")
    }
}

/// Auto review's settings: each a patch to its config file, which pi reads
/// when it starts (so a write asks for a restart).
private struct AutoReviewSettings: View {
    @Environment(SettingsHub.self) private var hub
    let model: SafetyModel

    private var config: AutoReviewConfig { model.autoReview }
    private func save(_ patch: PiConfigPatch) { Task { if await model.patchAutoReview(patch) { await hub.changed() } } }

    var body: some View {
        Group {
            Picker(selection: Binding(get: { config.preset }, set: { save(AutoReviewConfig.presetPatch($0)) })) {
                ForEach(AutoReview.Preset.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                AutoReviewLabel(title: "Rules", detail: "Whose reviewer it copies: Codex's auto-review or Claude Code's auto mode.")
            }
            NavigationLink {
                AutoReviewModelList(model: model)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    AutoReviewLabel(title: "Model", detail: "Which model reviews. It needs a login for its provider.")
                    Text(config.modelKey ?? "Preset default (\(config.preset.defaultModel))")
                        .font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
            }
            Picker(selection: Binding(get: { config.reasoning ?? "" }, set: { save(AutoReviewConfig.reasoningPatch($0)) })) {
                Text("Default (\(config.preset.defaultReasoning))").tag("")
                ForEach(AutoReview.reasoningLevels, id: \.self) { Text($0).tag($0) }
            } label: {
                AutoReviewLabel(title: "Reasoning", detail: "How hard the review thinks (for Claude Code's rules, only its second, careful pass).")
            }
            Picker(selection: Binding(get: { config.followUpReviews ?? "" }, set: { save(AutoReviewConfig.followUpPatch($0)) })) {
                Text("Default (auto)").tag("")
                ForEach(AutoReview.followUps, id: \.self) { Text(AutoReview.followUpLabel($0)).tag($0) }
            } label: {
                AutoReviewLabel(title: "Follow-up reviews", detail: "Continue one review conversation across asks (cheaper with caching). Off sends every review in full.")
            }
            if config.claudeViaOpenCodeGo {
                Text(AutoReviewConfig.claudeViaOpenCodeGoWarning).font(.footnote).foregroundStyle(.orange)
            }
        }
        .disabled(model.working != nil)
    }
}

private struct AutoReviewLabel: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The review model: the preset's default or one of pi's models. The list
/// loads when this opens (it may start a pi, so not with the page).
private struct AutoReviewModelList: View {
    @Environment(SettingsHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    let model: SafetyModel
    @State private var models: [ModelInfo]?
    @State private var problem: String?

    private var current: String { model.autoReview.modelKey ?? "" }

    var body: some View {
        List {
            Section {
                row("", "Preset default (\(model.autoReview.preset.defaultModel))")
                if !current.isEmpty, models?.contains(where: { $0.key == current }) != true { row(current, current) }
            }
            Section("pi's models") {
                if let models {
                    ForEach(models, id: \.key) { m in row(m.key, m.key) }
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Model")
        .task {
            guard models == nil else { return }
            do {
                models = try await hub.client.availableModels()
            } catch {
                problem = "Couldn't list models: \(error.reportable ?? "")"
            }
        }
    }

    private func row(_ key: String, _ label: String) -> some View {
        Button {
            Task {
                if key != current {
                    let saved = await model.patchAutoReview(AutoReviewConfig.modelPatch(key))
                    if saved { await hub.changed() }
                }
                dismiss()
            }
        } label: {
            HStack {
                Text(label).font(.callout.monospaced()).foregroundStyle(.primary)
                Spacer()
                if key == current {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                }
            }
        }
    }
}

/// One of auto review's decisions: what it said, about what, and how fast.
private struct ReviewRow: View {
    let review: AutoReviewRecord

    private var color: Color {
        switch review.kind {
        case .allowed: return .green
        case .denied: return .red
        case .asked: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(review.outcomeLabel).font(.footnote.weight(.semibold)).foregroundStyle(color)
            if !review.subject.isEmpty { Text(review.subject).font(.callout.monospaced()) }
            if let reason = review.reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
            let detail = review.detail()
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
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
