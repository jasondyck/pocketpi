import PhotosUI
import PocketPiKit
import SwiftUI
import UIKit

/// Makes the session once per screen (the client comes from the environment,
/// which an initializer can't read).
struct ChatView: View {
    @Environment(AppModel.self) private var model
    private let path: String?
    private let cwd: String
    /// Text to start a new chat's message box with ("Update the workflow …").
    private let draft: String?
    @State private var session: ChatSession?

    init(path: String, cwd: String) { self.path = path; self.cwd = cwd; self.draft = nil }
    init(newIn cwd: String, draft: String? = nil) { self.path = nil; self.cwd = cwd; self.draft = draft }

    var body: some View {
        Group {
            if let session { ChatScreen(session: session) } else { Color.clear }
        }
        .onAppear {
            guard session == nil, let client = model.client else { return }
            let s = path.map { ChatSession(client: client, path: $0, cwd: cwd) } ?? ChatSession(client: client, newIn: cwd)
            s.onTurnFinished = { [model] in Task { await model.refresh() } }
            if let draft { s.composer = draft }
            session = s
        }
    }
}

private struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var session: ChatSession
    @State private var atBottom = true
    /// Keep the end in view as the reply streams (off once scrolled away).
    @State private var following = true
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var openedRun: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if session.transcript.isEmpty, session.path == nil {
                        if session.cwd == model.chatDir {
                            ContentUnavailableView {
                                Label("Ask anything", systemImage: "bubble.left")
                            } description: {
                                Text("No tools here: pi only talks. Pick any model below, including local ones on the llama.cpp router.")
                            }
                            .padding(.top, 80)
                        } else {
                            EmptyChat(project: model.projectName(for: session.cwd), cwd: Format.tilde(session.cwd, home: model.home))
                        }
                    }
                    let rows = session.transcript.rows
                    ForEach(rows) { row in
                        switch row {
                        case .item(let item):
                            TranscriptItemView(item: item, transcript: session.transcript, home: model.home,
                                               onFork: { item in Task { await session.fork(at: item) } })
                        case .text(_, let message):
                            AssistantMessageView(message: message, live: false, transcript: session.transcript, home: model.home)
                        case .activity(_, let steps, let live):
                            ActivityRow(steps: steps, live: live, transcript: session.transcript, home: model.home)
                        }
                    }
                    // A live activity row says what pi is doing; otherwise this does.
                    if session.isStreaming, !Self.endsLive(rows) {
                        WorkingLine(activity: session.transcript.activity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            // The reason this app exists: the keyboard follows the finger down.
            .scrollDismissesKeyboard(.interactively)
            // Start at the end, but don't pin to it as the content grows: that
            // fought a finger scrolling up while a reply streamed in.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { g in
                // visibleRect leaves out the insets (the floating composer),
                // so short chats and the bottom both count as "at the end".
                g.visibleRect.maxY >= g.contentSize.height + g.contentInsets.bottom - 90
                    || g.contentSize.height <= g.visibleRect.height
            } action: { _, near in
                atBottom = near
                // Scrolled away by hand: stop following the reply.
                if !near, scrollPhase != .idle { following = false }
            }
            // Follow the reply like Messages: only while the person isn't
            // touching the list, and again once they've come back to the end.
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
                if phase == .idle, atBottom { following = true }
            }
            .onChange(of: session.transcript) { old, new in
                // Sending a message brings the end back, even after scrolling up.
                if new.items.count > old.items.count, case .user? = new.items.last?.kind { following = true }
                if following, scrollPhase == .idle { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        following = true
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.callout.weight(.semibold))
                            .padding(10)
                            .glass(in: Circle(), interactive: true)
                    }
                    .padding()
                    .accessibilityLabel("Jump to the end")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !session.activeRuns.isEmpty {
                    ActiveRuns(runs: session.activeRuns) { openedRun = $0 }
                }
                if let m = session.loadingLocal {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(Theme.signalText)
                        Text("Loading \(m) on the llama.cpp router…").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("loading-local")
                }
                ExtensionWidgets(ui: session.transcript.extensionUI, below: false)
                Composer(session: session)
                ExtensionWidgets(ui: session.transcript.extensionUI, below: true)
            }
            .animation(.default, value: session.activeRuns.map(\.id))
        }
        .navigationDestination(item: $openedRun) { RunView(runId: $0) }
        // Workflow runs pi started here: poll while any is going.
        .task(id: session.transcript.startedRuns) {
            while !Task.isCancelled, await session.refreshRuns() {
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            StatusBanner(status: session.status)
        }
        // The chat's name as the title: tapping it opens the system title
        // menu (rename in place, compact). The project underneath.
        .navigationTitle(Binding(get: { session.title }, set: { name in Task { await session.rename(name) } }))
        .navigationSubtitle(session.subtitle(fallback: model.projectName(for: session.cwd)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            RenameButton()
                .disabled(session.key == nil && session.path == nil)
            Button("Compact context", systemImage: "arrow.down.right.and.arrow.up.left") {
                Task { await session.compact() }
            }
            .disabled(session.isStreaming || session.path == nil)
            Button("Clone chat", systemImage: "plus.square.on.square") {
                Task { await session.clone() }
            }
            .disabled(session.isStreaming || session.path == nil)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ContextGauge(session: session) }
        }
        // The conversation keeps the screen, like Messages.
        .toolbarVisibility(.hidden, for: .tabBar)
        .task {
            await session.start()
            await session.prepare() // a new chat: pi now, so the model picker works
        }
        .onDisappear { session.leave() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.start() } }
        }
        .sheet(item: $session.pendingRequest) { req in
            ExtensionSheet(request: req) { answer in Task { await session.respond(to: req, answer) } }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { session.problem != nil },
            set: { if !$0 { session.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.problem ?? "")
        }
    }

    static func endsLive(_ rows: [TranscriptRow]) -> Bool {
        if case .activity(_, _, true)? = rows.last { return true }
        return false
    }
}

/// How full the chat's context is, as a small ring in the toolbar (lime
/// until it's getting full). Opens the chat's numbers and Compact.
private struct ContextGauge: View {
    @Bindable var session: ChatSession

    private var fraction: Double { min(1, max(0, (session.stats?.contextPercent ?? 0) / 100)) }

    var body: some View {
        Menu {
            if let stats = session.stats {
                let percent = stats.contextPercent.map { String(Int($0.rounded())) + "%" } ?? "–"
                Section("This chat") {
                    Text(verbatim: "Context " + percent + " of " + Format.tokens(stats.contextWindow))
                    Text(verbatim: Format.tokens(stats.totalTokens) + " tokens · " + Format.cost(stats.cost))
                }
            }
            Button("Compact context", systemImage: "arrow.down.right.and.arrow.up.left") {
                Task { await session.compact() }
            }
            .disabled(session.isStreaming || session.path == nil)
        } label: {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(fraction > 0.8 ? Color.orange : Theme.signalText,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            .padding(4)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Context")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent used")
        .accessibilityIdentifier("context-gauge")
    }
}

private struct EmptyChat: View {
    let project: String
    let cwd: String
    var body: some View {
        ContentUnavailableView {
            Label("What should pi do?", systemImage: "terminal")
        } description: {
            Text("\(project) · \(cwd)").font(.footnote.monospaced())
        }
        .padding(.top, 80)
    }
}

/// Workflow runs pi started in this chat that are still going: pi's turn
/// is over, but work goes on. A tap opens the run.
private struct ActiveRuns: View {
    let runs: [RunInfo]
    let open: (String) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(runs) { run in
                Button { open(run.id) } label: {
                    HStack(spacing: 10) {
                        if run.status == "waiting" {
                            RunStatusIcon(status: "waiting")
                        } else {
                            ProgressView().controlSize(.small).tint(Theme.signalText)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(run.workflowName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(detail(run)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glass(in: Capsule(), interactive: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("active-run")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func detail(_ run: RunInfo) -> String {
        if run.status == "waiting" { return "Waiting for you" + (run.currentStage.map { " · \($0.name)" } ?? "") }
        if let s = run.currentStage {
            // pi's latest step says more than the step count.
            if let a = s.activity { return "\(s.name) · \(a)" }
            let n = (run.stages.firstIndex { $0.id == s.id } ?? 0) + 1
            return "\(s.name) · step \(n) of \(run.stages.count)"
        }
        return run.status == "pending" ? "Queued" : "Running"
    }
}

private struct WorkingLine: View {
    let activity: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.signalText)
            Text(activity).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityIdentifier("working")
    }
}

private struct StatusBanner: View {
    let status: ChatSession.Status
    var body: some View {
        switch status {
        case .opening, .reconnecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status == .opening ? "Opening…" : "Reconnecting…")
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glass(in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        case .failed(let msg):
            Text(msg)
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.danger)
        case .idle, .connected:
            EmptyView()
        }
    }
}

/// Extensions' status chips (setStatus) and blocks of lines (setWidget),
/// above or below the composer.
private struct ExtensionWidgets: View {
    let ui: ExtensionUIState
    let below: Bool

    var body: some View {
        let widgets = below ? ui.belowEditor : ui.aboveEditor
        if !widgets.isEmpty || (!below && !ui.statuses.isEmpty) {
            VStack(alignment: .leading, spacing: 5) {
                if !below, !ui.statuses.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(ui.statuses) { s in
                                Text(s.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                            }
                        }
                    }
                    .accessibilityIdentifier("extension-status")
                }
                ForEach(widgets) { w in
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: w.lines.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("extension-widget")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, below ? 4 : 0)
        }
    }
}

/// confirm / select / input / editor dialogs from pi extensions.
private struct ExtensionSheet: View {
    let request: ExtensionRequest
    let answer: (ChatSession.Answer) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var answered = false

    var body: some View {
        NavigationStack {
            Form {
                if let m = request.message { Section { Text(m) } }
                if request.deadline != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(request.countdown(at: ctx.date) ?? "")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("dialog-countdown")
                }
                switch request.method {
                case .confirm:
                    Section {
                        Button("Confirm") { finish(.confirmed(true)) }
                        Button("Cancel", role: .cancel) { finish(.confirmed(false)) }
                    }
                case .select:
                    Section {
                        ForEach(request.options, id: \.self) { o in Button(o) { finish(.value(o)) } }
                    }
                case .input:
                    Section { TextField(request.placeholder ?? "", text: $text) }
                    Section { Button("Submit") { finish(.value(text)) } }
                case .editor:
                    Section { TextEditor(text: $text).frame(minHeight: 200).font(.body.monospaced()) }
                    Section { Button("Submit") { finish(.value(text)) } }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(.cancelled) } }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { text = request.prefill ?? "" }
        // Swiped away: pi is still waiting for an answer. Timed out: pi has
        // answered it itself.
        .onDisappear { if !answered, !request.isExpired() { answer(.cancelled) } }
    }

    private func finish(_ a: ChatSession.Answer) {
        answered = true
        answer(a)
        dismiss()
    }
}

// MARK: - composer

/// The model and thinking level, like the Claude app's pill in the message
/// box. Opens the model sheet.
private struct ModelButton: View {
    @Bindable var session: ChatSession
    @State private var showing = false

    private var thinking: String? {
        guard session.currentModel?.reasoning == true, let l = session.state?.thinkingLevel, l != "off" else { return nil }
        return l.capitalized
    }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Text(session.currentModel?.label ?? session.state?.modelLabel ?? "Model")
                    .foregroundStyle(.primary)
                if let thinking {
                    Text(thinking).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.isStreaming)
        .accessibilityLabel("Model: " + (session.currentModel?.label ?? "none") + (thinking.map { ", thinking " + $0 } ?? ""))
        .accessibilityIdentifier("model-button")
        .sheet(isPresented: $showing) {
            ModelSheet(session: session)
                // Tall enough for a few models, Effort and More models.
                .presentationDetents([.fraction(0.75), .large])
        }
    }
}

/// Select model: the models picked in pi first (its enabled models), then
/// Effort and More models, each a page of its own. A standard sheet with a
/// grouped list, like the Claude app's model sheet.
private struct ModelSheet: View {
    @Bindable var session: ChatSession
    @Environment(\.dismiss) private var dismiss

    private var reasoning: Bool { session.currentModel?.reasoning == true && session.thinkingLevels.count > 1 }

    var body: some View {
        NavigationStack {
            List {
                let favorites = session.favorites
                if favorites.isEmpty {
                    // Nothing picked in pi: every model, by provider, right here.
                    AllModels(session: session) { dismiss() }
                } else {
                    Section {
                        ForEach(favorites, id: \.key) { m in
                            ModelRow(model: m, current: m.key == session.currentModel?.key) { pick(m) }
                        }
                    }
                }
                if reasoning {
                    Section {
                        NavigationLink {
                            EffortList(session: session)
                        } label: {
                            LabeledContent("Effort", value: (session.state?.thinkingLevel ?? "").capitalized)
                        }
                    }
                }
                if !favorites.isEmpty {
                    Section {
                        NavigationLink("More models") {
                            List { AllModels(session: session) { dismiss() } }
                                .navigationTitle("More models")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }
                if let router = session.llama, router.available {
                    LocalModels(session: session, router: router) { dismiss() }
                }
            }
            .navigationTitle("Select model")
            .navigationBarTitleDisplayMode(.inline)
            .task { await session.refreshLlama() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { CloseButton { dismiss() } }
            }
        }
    }

    private func pick(_ m: ModelInfo) {
        Task { await session.setModel(m) }
        dismiss()
    }
}

/// Every model pi has a key for, one section per provider.
private struct AllModels: View {
    @Bindable var session: ChatSession
    let done: () -> Void

    var body: some View {
        let providers = session.models.reduce(into: [String]()) { if !$0.contains($1.provider) { $0.append($1.provider) } }
        if providers.isEmpty {
            Text("No models. Is an API key set up in pi?").foregroundStyle(.secondary)
        }
        ForEach(providers, id: \.self) { p in
            Section(ModelInfo.providerLabel(p)) {
                ForEach(session.models.filter { $0.provider == p }, id: \.key) { m in
                    ModelRow(model: m, current: m.key == session.currentModel?.key, showProvider: false) {
                        Task { await session.setModel(m) }
                        done()
                    }
                }
            }
        }
    }
}

/// The llama.cpp router's models with their state. A loaded one is picked
/// like any model; an unloaded one is loaded first (unloading the others,
/// they share the GPU), which the chat shows while it happens.
private struct LocalModels: View {
    @Bindable var session: ChatSession
    let router: LlamaRouter
    let done: () -> Void

    var body: some View {
        Section {
            if let e = router.error {
                Label(e, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(router.models) { m in
                Button {
                    Task { await session.useLocal(m) }
                    done()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.id).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                            Text(state(m)).font(.subheadline).foregroundStyle(m.isLoaded ? Theme.signalText : .secondary)
                        }
                        Spacer()
                        if m.key == session.currentModel?.key {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(session.loadingLocal != nil || m.status == "loading")
                .accessibilityIdentifier("local-" + m.id)
            }
        } header: {
            Text("Local · llama.cpp")
        } footer: {
            Text("Loading a model unloads the router's others; they share the GPU.")
        }
    }

    private func state(_ m: LlamaModel) -> String {
        switch m.status {
        case "loaded": "Loaded"
        case "sleeping": "Loaded · asleep"
        case "loading": "Loading…"
        default: m.failed ? "Failed to load last time" : "Not loaded · tap to load"
        }
    }
}

private struct ModelRow: View {
    let model: ModelInfo
    let current: Bool
    var showProvider = true
    let pick: () -> Void

    /// What the Claude app says in words, from what pi knows: the provider,
    /// the context size, and whether it reasons or takes images.
    private var detail: String {
        var parts: [String] = []
        if showProvider { parts.append(model.providerLabel) }
        if let c = model.contextWindow { parts.append(Format.tokens(c) + " context") }
        if model.reasoning { parts.append("reasoning") }
        if model.vision { parts.append("images") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: pick) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.label).foregroundStyle(.primary)
                    if !detail.isEmpty {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if current {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

private struct EffortList: View {
    @Bindable var session: ChatSession

    var body: some View {
        List {
            ForEach(session.thinkingLevels, id: \.self) { l in
                Button {
                    Task { await session.setThinkingLevel(l) }
                } label: {
                    HStack {
                        Text(l.capitalized).foregroundStyle(.primary)
                        Spacer()
                        if session.state?.thinkingLevel == l {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(session.state?.thinkingLevel == l ? .isSelected : [])
            }
        }
        .navigationTitle("Effort")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The system Close button (the glass ✕).
private struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(role: .close, action: action)
            .accessibilityIdentifier("close-sheet")
    }
}

private struct Composer: View {
    @Bindable var session: ChatSession
    @State private var images: [ImageAttachment] = []
    @State private var picks: [PhotosPickerItem] = []
    @State private var sending = false
    @FocusState private var focused: Bool

    private var hasText: Bool { !session.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(session.transcript.steering + session.transcript.followUp, id: \.self) { q in
                Text(q).font(.footnote).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            if !session.slashMatches.isEmpty {
                SlashList(commands: session.slashMatches) { c in
                    session.pick(c)
                    focused = true
                }
            }
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(images) { a in
                            AttachmentThumb(attachment: a) { images.removeAll { $0.id == a.id } }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField(session.isStreaming ? "Steer pi…" : "Message pi", text: $session.composer, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    .accessibilityIdentifier("composer")
                HStack(spacing: 8) {
                    PhotosPicker(selection: $picks, maxSelectionCount: 4, matching: .images) {
                        Image(systemName: "plus").font(.title3).frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Attach images")
                    ModelButton(session: session)
                    Spacer(minLength: 0)
                    sendButton
                }
            }
            // One floating glass bar over the transcript, like Messages.
            .padding(6)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // A chat started with a draft ("Update the workflow …"): the keyboard
        // comes up so it's one step to finish the sentence.
        .task {
            guard session.path == nil, session.transcript.isEmpty, !session.composer.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(500))
            focused = true
        }
        .onChange(of: session.composer) { _, _ in
            Task { await session.composerChanged() }
        }
        .onChange(of: picks) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let a = ImageShrinker.attachment(from: data) { images.append(a) }
                }
                picks = []
            }
        }
    }

    /// Send and Stop are one control: the same lime circle (a plain fill,
    /// not glass on the glass bar), its symbol swapping as pi starts and
    /// stops. Grey while there's nothing to send.
    private var sendButton: some View {
        let stop = session.isStreaming && !hasText && images.isEmpty
        let ready = stop || hasText || !images.isEmpty
        return Button {
            if stop { Task { await session.stop() } } else { send() }
        } label: {
            Image(systemName: stop ? "stop.fill" : "arrow.up")
                .font(.callout.weight(.bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(ready ? Theme.signalInk : Color.secondary)
                .frame(width: 32, height: 32)
                .background(ready ? Theme.signal : Color(uiColor: .tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!ready || (sending && !stop))
        .animation(.default, value: stop)
        .accessibilityLabel(stop ? "Stop" : "Send")
    }

    private func send() {
        let text = session.composer
        let imgs = images
        session.composer = ""
        images = []
        sending = true
        Task {
            defer { sending = false }
            do { try await session.send(text, images: imgs) } catch {
                if session.composer.isEmpty { session.composer = text }
                images = imgs
                session.problem = "Not sent: " + error.localizedDescription
            }
        }
    }
}

/// pi's slash commands matching a lone `/word` in the composer; a tap puts
/// `/name ` in the composer, ready for arguments.
private struct SlashList: View {
    let commands: [SlashCommand]
    let pick: (SlashCommand) -> Void
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        // As tall as its rows, up to 240pt (then it scrolls). Measured, since
        // a flexible frame would take all the space above the keyboard.
        ScrollView {
            rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(rowsHeight, 1), 240))
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commands) { c in
                Button { pick(c) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon(c))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("/" + c.name)
                                .font(.subheadline.monospaced().weight(.semibold))
                                .foregroundStyle(.primary)
                            if let d = c.description {
                                Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("slash-" + c.name)
            }
        }
        .padding(4)
    }

    private func icon(_ c: SlashCommand) -> String {
        switch c.source {
        case "skill": "sparkles"
        case "prompt": "text.quote"
        default: "puzzlepiece.extension"
        }
    }
}

private struct AttachmentThumb: View {
    let attachment: ImageAttachment
    let remove: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let data = Data(base64Encoded: attachment.base64), let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
    }
}

/// Downscale on the phone before upload, like shrink() in app.js: pi gets a
/// readable picture, not a 12-megapixel one.
enum ImageShrinker {
    static func attachment(from data: Data, maxSide: CGFloat = 1568) -> ImageAttachment? {
        guard let img = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = out.jpegData(compressionQuality: 0.85) else { return nil }
        return ImageAttachment(base64: jpeg.base64EncodedString(), mimeType: "image/jpeg")
    }
}
