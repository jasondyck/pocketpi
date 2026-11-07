import PocketPiKit
import SwiftUI

// Workflows: the list (content column), one workflow with its runs, one run
// with its stages, and the sheet that starts a run. Runs move on their own,
// so each screen polls while it's on screen.

/// "started by pi" → "Started by pi".
func sentence(_ s: String) -> String {
    s.prefix(1).uppercased() + String(s.dropFirst())
}

/// Pushes a run onto the detail stack.
struct RunRoute: Hashable {
    let id: String
}

// MARK: - list

/// Running runs first, then every workflow, most recently run first.
struct WorkflowsList: View {
    @Environment(AppModel.self) private var model
    @Binding var target: ChatTarget?

    private var sorted: [WorkflowInfo] {
        model.workflows.sorted { a, b in
            if a.enabled != b.enabled { return a.enabled }
            return (a.lastRun?.created ?? 0) > (b.lastRun?.created ?? 0)
        }
    }

    var body: some View {
        List(selection: $target) {
            if !model.activeRuns.isEmpty {
                Section("Running") {
                    ForEach(model.activeRuns) { run in
                        RunRow(run: run, showWorkflow: true)
                            .tag(ChatTarget.run(id: run.id))
                            .accessibilityIdentifier("active-run-row")
                    }
                }
            }
            Section {
                ForEach(sorted) { w in
                    WorkflowRow(workflow: w)
                        .tag(ChatTarget.workflow(id: w.id))
                        .accessibilityIdentifier("workflow-row")
                }
            } header: {
                if !model.activeRuns.isEmpty { Text("Workflows") }
            }
            if model.workflows.isEmpty, !model.loading {
                ContentUnavailableView("No workflows", systemImage: "flowchart",
                                       description: Text("Ask pi in a chat to make one."))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .navigationTitle("Workflows")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await model.refresh()
            }
        }
    }
}

private struct WorkflowRow: View {
    @Environment(AppModel.self) private var model
    let workflow: WorkflowInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProjectBadge(path: workflow.project, name: model.projectName(for: workflow.project))
            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name).lineLimit(2)
                HStack(spacing: 6) {
                    if let last = workflow.lastRun {
                        RunStatusIcon(status: last.status)
                        Text(last.createdDate, format: .relative(presentation: .named))
                    } else {
                        Text("Never run")
                    }
                    if !workflow.enabled { Text("· Off") }
                    if !workflow.errors.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .accessibilityLabel("has problems")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A run in a list: status, what it was about, when, how long, cost.
struct RunRow: View {
    let run: RunInfo
    let showWorkflow: Bool

    private var title: String {
        if showWorkflow { return run.workflowName }
        return run.inputSummary.isEmpty ? sentence(run.startedBy) : run.inputSummary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RunStatusIcon(status: run.status).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(2)
                if showWorkflow, !run.inputSummary.isEmpty {
                    Text(run.inputSummary).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(run.createdDate, format: .relative(presentation: .named))
                    Text("·")
                    Text(Format.duration(run.duration()))
                    if run.cost > 0 {
                        Text("·")
                        Text(Format.cost(run.cost))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let e = run.error, run.status == "failed" {
                    Text(e).font(.caption).foregroundStyle(Theme.danger).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A run or stage status as a symbol. Colour carries meaning (HIG): green
/// done, red failed, orange waiting for you, the signal for running.
struct RunStatusIcon: View {
    let status: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: Self.symbol(status))
            .foregroundStyle(Self.color(status))
            .symbolEffect(.pulse, isActive: status == "running" && !reduceMotion)
            .accessibilityLabel(Self.word(status))
    }

    static func symbol(_ s: String) -> String {
        switch s {
        case "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        case "running": "circle.dotted"
        case "waiting": "hand.raised.circle.fill"
        case "skipped": "minus.circle"
        case "cancelled": "stop.circle"
        default: "circle"
        }
    }

    static func color(_ s: String) -> Color {
        switch s {
        case "succeeded": .green
        case "failed": Theme.danger
        case "running": Theme.signalText
        case "waiting": .orange
        default: .secondary
        }
    }

    static func word(_ s: String) -> String {
        switch s {
        case "succeeded": "Succeeded"
        case "failed": "Failed"
        case "running": "Running"
        case "waiting": "Waiting for you"
        case "skipped": "Skipped"
        case "cancelled": "Cancelled"
        case "pending": "Not started"
        default: s.capitalized
        }
    }
}

// MARK: - one workflow

struct WorkflowView: View {
    @Environment(AppModel.self) private var model
    let workflowId: String
    @State private var runs: [RunInfo] = []
    @State private var loaded = false
    @State private var starting = false
    @State private var opened: String?

    private var workflow: WorkflowInfo? { model.workflows.first { $0.id == workflowId } }

    var body: some View {
        Group {
            if let w = workflow {
                List {
                    Section {
                        if !w.description.isEmpty {
                            Text(w.description).font(.callout)
                        }
                        LabeledContent("Project", value: model.projectName(for: w.project))
                        LabeledContent("Starts on", value: w.triggers.isEmpty ? "Only when you run it" : w.triggers.joined(separator: ", "))
                        if !w.triggers.isEmpty {
                            Toggle("On", isOn: Binding(get: { w.enabled }, set: { on in setEnabled(on) }))
                                .accessibilityIdentifier("workflow-enabled")
                        }
                    } footer: {
                        if !w.triggers.isEmpty {
                            Text("Off stops it starting by itself. You can still run it.")
                        }
                    }
                    if !w.errors.isEmpty {
                        Section("Problems") {
                            ForEach(w.errors, id: \.self) { e in
                                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                    }
                    Section("Runs") {
                        ForEach(runs) { run in
                            NavigationLink(value: RunRoute(id: run.id)) {
                                RunRow(run: run, showWorkflow: false)
                            }
                            .accessibilityIdentifier("run-row")
                        }
                        if runs.isEmpty, loaded {
                            Text("No runs yet").foregroundStyle(.secondary)
                        }
                    }
                }
                .refreshable { await load() }
                .navigationTitle(w.name)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Run", systemImage: "play.fill") { starting = true }
                            .disabled(!w.manual)
                            .accessibilityIdentifier("run-workflow")
                    }
                }
                .sheet(isPresented: $starting) {
                    StartRunSheet(workflow: w) { id in opened = id }
                }
            } else {
                ContentUnavailableView("Workflow not found", systemImage: "flowchart",
                                       description: Text("It may have been deleted."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: RunRoute.self) { RunView(runId: $0.id) }
        .navigationDestination(item: $opened) { RunView(runId: $0) }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(runs.contains(where: \.isActive) ? 3 : 10))
            }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        if let r = try? await client.runs(workflow: workflowId) { runs = r }
        loaded = true
    }

    private func setEnabled(_ on: Bool) {
        guard let client = model.client else { return }
        Task {
            do { try await client.setEnabled(workflow: workflowId, on) } catch {
                if let m = error.reportable { model.problem = (on ? "Couldn't turn it on: " : "Couldn't turn it off: ") + m }
            }
            await model.refresh()
        }
    }
}

// MARK: - start a run

/// The workflow's inputs as a form. A run the server has already done (same
/// PR commit, issue) asks before starting it again.
struct StartRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let workflow: WorkflowInfo
    let started: (String) -> Void
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var problem: String?
    @State private var duplicate: (id: String, message: String)?

    /// A PR's commit is filled in by the server (the PR's current head).
    private var shown: [WorkflowInfo.Input] {
        let hasPR = workflow.inputs.contains { $0.name == "pr" }
        return workflow.inputs.filter { !(hasPR && $0.name == "commit") }
    }

    private var missing: Bool {
        shown.contains { $0.required && (values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if shown.isEmpty {
                    Section { Text("Starts \(workflow.name) now.") }
                }
                ForEach(shown) { input in
                    Section {
                        field(input)
                    } header: {
                        Text(input.required ? input.name : input.name + " (optional)")
                    } footer: {
                        if !input.description.isEmpty { Text(input.description) }
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(Theme.danger) }
                }
            }
            .navigationTitle(workflow.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { go(force: false) }
                        .disabled(busy || missing)
                        .accessibilityIdentifier("start-run")
                }
            }
            .alert("Already ran", isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } })) {
                Button("Run again anyway") { go(force: true) }
                Button("Open that run") {
                    if let d = duplicate { finish(d.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(duplicate?.message ?? "")
            }
        }
        .presentationDetents(shown.count > 1 ? [.large] : [.medium, .large])
        .onAppear {
            for i in workflow.inputs where values[i.name] == nil { values[i.name] = i.defaultValue }
        }
    }

    @ViewBuilder private func field(_ input: WorkflowInfo.Input) -> some View {
        let binding = Binding(get: { values[input.name] ?? "" }, set: { values[input.name] = $0 })
        if ["pr", "issue"].contains(input.name) {
            TextField(input.name == "pr" ? "PR number" : "Issue number", text: binding)
                .keyboardType(.numberPad)
        } else {
            TextField(input.description.isEmpty ? input.name : input.description, text: binding, axis: .vertical)
                .lineLimit(1...8)
                .textInputAutocapitalization(.sentences)
        }
    }

    private func go(force: Bool) {
        guard let client = model.client else { return }
        busy = true
        problem = nil
        let inputs = values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        Task {
            defer { busy = false }
            do {
                switch try await client.start(workflow: workflow.id, inputs: inputs, force: force) {
                case .started(let id): finish(id)
                case .duplicate(let id, let message): duplicate = (id, message)
                }
            } catch {
                problem = error.reportable
            }
        }
    }

    private func finish(_ id: String) {
        dismiss()
        started(id)
        Task { await model.refresh() }
    }
}

// MARK: - one run

struct RunView: View {
    @Environment(AppModel.self) private var model
    let runId: String
    @State private var run: RunInfo?
    @State private var loadError: String?
    @State private var busy = false
    @State private var confirmCancel = false
    @State private var rerun: String?

    var body: some View {
        Group {
            if let run {
                content(run)
            } else if let loadError {
                ContentUnavailableView("Couldn't load the run", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(run?.workflowName ?? "Run")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $rerun) { RunView(runId: $0) }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(run?.isActive == false ? 15 : 2))
            }
        }
    }

    private func content(_ run: RunInfo) -> some View {
        List {
            Section {
                HStack(spacing: 8) {
                    RunStatusIcon(status: run.status)
                    Text(RunStatusIcon.word(run.status)).font(.headline)
                }
                if !run.inputSummary.isEmpty {
                    LabeledContent("For", value: run.inputSummary)
                }
                LabeledContent("Started") {
                    Text(run.createdDate, format: .relative(presentation: .named))
                }
                LabeledContent(run.isActive ? "Running for" : "Took", value: Format.duration(run.duration()))
                LabeledContent("Cost", value: Format.cost(run.cost))
                LabeledContent("How", value: sentence(run.startedBy))
                if let b = run.branch { LabeledContent("Branch", value: b) }
            }
            if let e = run.error, run.status == "failed" {
                Section("Why it failed") {
                    Text(e).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if let stage = run.waitingApproval {
                Section("Waiting for you") {
                    MarkdownView(text: stage.prompt ?? stage.name)
                    HStack {
                        Button("Reject", role: .destructive) { answer(run, false) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Approve") { answer(run, true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(busy)
                }
            }
            Section("Stages") {
                ForEach(run.stages) { StageRow(stage: $0) }
            }
        }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if run.isActive {
                    Button("Cancel run", systemImage: "stop.fill", role: .destructive) { confirmCancel = true }
                        .disabled(busy)
                        .accessibilityIdentifier("cancel-run")
                } else {
                    Button("Run again", systemImage: "arrow.clockwise") { again(run) }
                        .disabled(busy)
                        .accessibilityIdentifier("run-again")
                }
            }
        }
        .confirmationDialog("Cancel this run?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel run", role: .destructive) { cancel() }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("The stage it's on stops now. Work it already pushed stays.")
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            run = try await client.run(id: runId)
            loadError = nil
        } catch {
            if let m = error.reportable, run == nil { loadError = m }
        }
    }

    private func cancel() {
        guard let client = model.client else { return }
        busy = true
        Task {
            do { try await client.cancel(run: runId) } catch {
                if let m = error.reportable { model.problem = "Couldn't cancel: " + m }
            }
            await load()
            await model.refresh()
            busy = false
        }
    }

    /// Same inputs, forced past the duplicate check (that's the point). A PR
    /// run picks up the PR's current head.
    private func again(_ run: RunInfo) {
        guard let client = model.client else { return }
        busy = true
        Task {
            do {
                if case .started(let id) = try await client.start(workflow: run.workflowId, inputs: run.rerunInputs, force: true) {
                    rerun = id
                }
            } catch {
                if let m = error.reportable { model.problem = "Couldn't start it again: " + m }
            }
            await model.refresh()
            busy = false
        }
    }

    private func answer(_ run: RunInfo, _ approve: Bool) {
        busy = true
        Task {
            _ = await model.answer(run, approve: approve)
            await load()
            busy = false
        }
    }
}

/// A stage: status, name, the last line it printed; opens to all of it.
private struct StageRow: View {
    let stage: RunInfo.Stage
    @State private var open = false

    private var kind: String {
        switch stage.kind {
        case "agent": "pi"
        case "shell": "shell"
        case "review": "review"
        case "approval": "approval"
        default: stage.kind
        }
    }

    private var detail: String {
        if !stage.output.isEmpty { return String(stage.output.suffix(6000)) }
        if stage.kind == "shell", let p = stage.prompt { return "$ " + p }
        return ""
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            if detail.isEmpty {
                Text("No output").foregroundStyle(.secondary)
            } else {
                Text(detail)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RunStatusIcon(status: stage.status)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(stage.name)
                        if stage.attempts > 1 {
                            Text("×\(stage.attempts)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(stage.summary.isEmpty ? kind : kind + " · " + stage.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityIdentifier("stage-row")
    }
}
