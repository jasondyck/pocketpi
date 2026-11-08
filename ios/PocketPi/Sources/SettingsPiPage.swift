import PocketPiKit
import SwiftUI

// Settings › pi settings: pi's global settings.json (models, favourites,
// thinking per model, queue, compaction, retry, images, display, default
// tools, codemode), global or a project's (SettingsPiScope.swift, which also
// has the default-tools rows and the JSON editor). The keys,
// defaults, parsing and patches are PocketPiKit's PiSettings.swift; this view
// only draws them. Every write is a patch, so keys it doesn't show are kept.
// The web twin is web/manage-settings.js.

extension SettingsPage {
    static let settings = SettingsPage(id: "settings", title: "pi settings",
                                       subtitle: "Models, favourites, queue, compaction, retry",
                                       systemImage: "slider.horizontal.3", order: 10) { SettingsPiPage() }
}

private struct SettingsPiPage: View {
    @Environment(SettingsHub.self) private var hub
    @Environment(AppModel.self) private var app
    @State private var doc: PiConfigDocument?
    @State private var models: [ModelInfo]?
    @State private var problem: String?
    /// Global, or a project's .pi/settings.json (SettingsPiScope.swift).
    @State private var scope: SettingsScope = .global
    @State private var globalData: JSONValue = .object([:])
    @State private var trusted: Bool?

    private var data: JSONValue { doc?.data ?? .object([:]) }
    private var favourites: [ModelPattern] { EnabledModels.parse(data["enabledModels"]) }

    var body: some View {
        List {
            if let doc {
                ScopeSection(scope: $scope, projects: app.projects, path: doc.path, trusted: trusted)
                modelsSection
                favouritesSection
                thinkingSection
                ForEach([PiSettingGroup.queue, .compaction, .retry, .images, .display, .tools], id: \.self) { group in
                    Section {
                        if group == .tools {
                            DefaultToolsRows(data: data, globalData: globalData, project: scope.isProject) { p in
                                Task { await write(p) }
                            }
                        }
                        ForEach(PiSettings.specs(in: group)) { spec in control(spec) }
                        if group == .compaction {
                            ForEach(PiSettings.compactionOverrides(data)) { o in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(o.model).font(.callout.monospaced())
                                    Text("Override: \(o.summary) (edit settings.json to change)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        GlobalHeader(title: group.title)
                    }
                }
                RawSettingsSection(scope: scope) { await load(); await hub.changed() }
            } else if problem == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.settingsProjectScope, scope.isProject)
        .task(id: scope) { await load() }
        .refreshable { await load() }
        .alert("Couldn't save", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: sections

    private var modelsSection: some View {
        Section {
            NavigationLink {
                ModelPickList(title: "Default model", models: models, current: PiSettings.defaultModel(data),
                              letPiChoose: true, loadModels: loadModels) { choice in
                    if case .model(let m) = choice { Task { await write(PiSettings.defaultModelPatch(m)) } }
                    if case .automatic = choice { Task { await write(PiSettings.defaultModelPatch(nil)) } }
                }
            } label: {
                LabeledContent("Default model", value: PiSettings.defaultModel(data) ?? "pi chooses")
            }
            .accessibilityIdentifier("settings-default-model")
            ForEach(PiSettings.specs(in: .models)) { spec in control(spec) }
        } header: {
            GlobalHeader(title: PiSettingGroup.models.title)
        }
    }

    private var favouritesSection: some View {
        Section {
            ForEach(Array(favourites.enumerated()), id: \.element.id) { i, p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.pattern).font(.callout.monospaced())
                        if let models, p.isGlob {
                            let n = EnabledModels.resolve([p], in: models).count
                            Text(n == 1 ? "1 model" : "\(n) models").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Menu {
                        Picker("Thinking", selection: Binding(
                            get: { p.thinking ?? "" },
                            set: { v in
                                var l = favourites
                                l[i].thinking = v.isEmpty ? nil : v
                                Task { await write(EnabledModels.patch(l)) }
                            }
                        )) {
                            Text("Default").tag("")
                            ForEach(PiThinking.levels, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        Text(p.thinking ?? "thinking").font(.caption.monospaced())
                    }
                }
            }
            .onMove { from, to in
                var l = favourites
                l.move(fromOffsets: from, toOffset: to)
                Task { await write(EnabledModels.patch(l)) }
            }
            .onDelete { idx in
                var l = favourites
                l.remove(atOffsets: idx)
                Task { await write(EnabledModels.patch(l)) }
            }
            NavigationLink {
                ModelPickList(title: "Add a favourite", models: models, current: nil, letPiChoose: false, allowPattern: true,
                              exclude: favourites.map(\.pattern), loadModels: loadModels) { choice in
                    let entry: ModelPattern
                    switch choice {
                    case .model(let m): entry = ModelPattern(pattern: m.key)
                    case .pattern(let s): entry = ModelPattern(s)
                    case .automatic: return
                    }
                    Task { await write(EnabledModels.patch(EnabledModels.adding(entry, to: favourites))) }
                }
            } label: {
                Label("Add model", systemImage: "plus")
            }
        } header: {
            GlobalHeader(title: "Favourite models")
        } footer: {
            Text(favourites.isEmpty ? "None: pi cycles through every available model."
                 : "Top of the model picker, and what pi cycles through. Drag to reorder, swipe to remove.")
        }
    }

    private var thinkingSection: some View {
        Section {
            ForEach(PiSettings.modelThinking(data)) { entry in
                Picker(selection: Binding(
                    get: { entry.level },
                    set: { v in Task { await write(PiSettings.modelThinkingPatch(entry.model, v)) } }
                )) {
                    ForEach(PiThinking.levels, id: \.self) { Text($0).tag($0) }
                } label: {
                    Text(entry.model).font(.callout.monospaced())
                }
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        Task { await write(PiSettings.modelThinkingPatch(entry.model, nil)) }
                    }
                }
            }
            NavigationLink {
                ModelPickList(title: "Thinking for a model", models: models, current: nil, letPiChoose: false,
                              exclude: PiSettings.modelThinking(data).map(\.model), loadModels: loadModels) { choice in
                    if case .model(let m) = choice {
                        Task { await write(PiSettings.modelThinkingPatch(m.key, m.reasoning ? "high" : "off")) }
                    }
                }
            } label: {
                Label("Add model", systemImage: "plus")
            }
        } header: {
            GlobalHeader(title: "Thinking per model")
        } footer: {
            Text("A model's startup thinking level, instead of the default.")
        }
    }

    @ViewBuilder
    private func control(_ spec: PiSettingSpec) -> some View {
        switch spec.kind {
        case .toggle:
            Toggle(isOn: Binding(
                get: { PiSettings.bool(data, spec) },
                set: { v in Task { await write(PiSettings.patch(spec, .bool(v))) } }
            )) {
                SettingLabel(spec: spec)
            }
            .accessibilityIdentifier("setting-\(spec.key)")
        case .choice(let values, let labels, let def):
            Picker(selection: Binding(
                get: { PiSettings.selection(data, spec) },
                set: { v in Task { await write(PiSettings.patch(spec, selection: v)) } }
            )) {
                Text(scope.isProject ? "Inherit" : "Default (\(labels[values.firstIndex(of: def) ?? 0]))").tag("")
                ForEach(Array(zip(values, labels)), id: \.0) { v, l in Text(l).tag(v) }
            } label: {
                SettingLabel(spec: spec)
            }
            .accessibilityIdentifier("setting-\(spec.key)")
        case .number(let def, _, _):
            NumberSettingRow(spec: spec, placeholder: String(def), text: PiSettings.numberText(data, spec)) { text in
                switch PiSettings.parseNumber(text, spec) {
                case .success(let n): Task { await write(PiSettings.patch(spec, n.map { JSONValue.number(Double($0)) })) }
                case .failure(let e): problem = "\(spec.title): \(e.localizedDescription)"
                }
            }
        }
    }

    // MARK: data

    private func load() async {
        do {
            doc = try await hub.client.config(.settings, cwd: scope.cwd)
            if scope.isProject {
                globalData = try await hub.client.config(.settings).data
                trusted = (try? await hub.client.contextOverview(cwd: scope.cwd))?.trusted
            } else {
                globalData = data
                trusted = nil
            }
        } catch {
            problem = error.reportable
        }
        // Only from a running chat, as on the web: no pi is started just to
        // count what the favourites match.
        if models == nil, hub.status?.live.contains(where: { $0.kind != "stage" }) == true {
            await loadModels()
        }
    }

    private func loadModels() async {
        guard models == nil else { return }
        do {
            models = try await hub.client.availableModels()
        } catch {
            problem = "Couldn't list models: \(error.reportable ?? "")"
        }
    }

    private func write(_ patch: PiConfigPatch) async {
        do {
            doc = try await hub.client.patchConfig(.settings, patch, cwd: scope.cwd)
            if !scope.isProject { globalData = data }
            await hub.changed()
        } catch {
            problem = error.reportable
        }
    }
}

/// A section header with the "Global" (or "Project") tag.
private struct GlobalHeader: View {
    let title: String
    @Environment(\.settingsProjectScope) private var project
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(project ? "PROJECT" : "GLOBAL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(project ? Color.green : Color.orange)
                .padding(.horizontal, 5)
                .overlay(Capsule().stroke((project ? Color.green : .orange).opacity(0.5)))
        }
    }
}

private struct SettingLabel: View {
    let spec: PiSettingSpec
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.title)
            Text(spec.detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A number setting: saved when the field is submitted or loses focus; empty
/// means pi's default.
private struct NumberSettingRow: View {
    let spec: PiSettingSpec
    let placeholder: String
    let text: String
    let save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            SettingLabel(spec: spec)
            Spacer()
            TextField(placeholder, text: $draft)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(maxWidth: 100)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityIdentifier("setting-\(spec.key)")
        }
        .onAppear { draft = text }
        .onChange(of: text) { _, new in draft = new }
        .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func commit() {
        if draft != text { save(draft) }
    }
}

/// What a model list hands back.
private enum ModelChoice {
    case automatic
    case model(ModelInfo)
    case pattern(String)
}

/// The models pi can use, searchable, grouped by provider; optionally "Let pi
/// choose" and a field for a typed pattern (globs, `:thinking`).
private struct ModelPickList: View {
    let title: String
    let models: [ModelInfo]?
    let current: String?
    var letPiChoose = false
    var allowPattern = false
    var exclude: [String] = []
    let loadModels: () async -> Void
    let pick: (ModelChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var pattern = ""

    private var shown: [ModelInfo] {
        (models ?? []).filter { m in
            !exclude.contains(m.key) && (search.isEmpty || "\(m.key) \(m.name ?? "")".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            if allowPattern {
                Section {
                    TextField("anthropic/claude-*:high", text: $pattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onSubmit(addPattern)
                    Button("Add pattern", action: addPattern)
                        .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Pattern")
                } footer: {
                    Text("Exact provider/id, a bare id, or * for any run of characters; add :level for its thinking.")
                }
            }
            if letPiChoose {
                Button {
                    choose(.automatic)
                } label: {
                    HStack {
                        Text("Let pi choose")
                        Spacer()
                        if current == nil { Image(systemName: "checkmark") }
                    }
                }
            }
            if models == nil {
                ProgressView().frame(maxWidth: .infinity)
            } else if shown.isEmpty {
                Text("No models. Set up a provider in pi first.").foregroundStyle(.secondary)
            }
            ForEach(Dictionary(grouping: shown, by: \.provider).sorted { $0.key < $1.key }, id: \.key) { provider, list in
                Section(ModelInfo.providerLabel(provider)) {
                    ForEach(list) { m in
                        Button {
                            choose(.model(m))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.id).font(.callout.monospaced())
                                    if let n = m.name { Text(n).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if current == m.key { Image(systemName: "checkmark") }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search)
        .task { await loadModels() }
    }

    private func addPattern() {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        choose(.pattern(p))
    }

    private func choose(_ c: ModelChoice) {
        pick(c)
        dismiss()
    }
}
