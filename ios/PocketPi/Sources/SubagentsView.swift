import PocketPiKit
import SwiftUI

// Environment hooks: the chat screen provides its monitor and a way to open
// the Subagents sheet, so a `subagent` tool card can show its run in place.
extension EnvironmentValues {
    /// The chat's live subagent runs.
    @Entry var subagents: SubagentMonitor? = nil
    /// Opens the chat's Subagents sheet.
    @Entry var openSubagents: (() -> Void)? = nil
}

// Subagent progress (GET /api/subagents, src/subagents.rs; the web twin is
// web/agents.js). The chat keeps a SubagentMonitor so a live run shows above
// the composer; the title menu's "Subagents" opens this sheet, where each run
// lists its steps, current tool, recent output, tokens and cost. A step with
// a session file opens that child's chat, live, in the same sheet.

/// A `subagent` tool card's live progress, in place: the run's steps, current
/// tool and time, plus a way into the full sheet. The web twin is the
/// `.ag-card` block in web/agents.js.
struct SubagentToolProgress: View {
    let run: SubagentRun?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let run {
                HStack(spacing: 6) {
                    Text(run.title).font(.caption.weight(.semibold))
                    Text(run.stateLabel).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(run.elapsed()).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                ForEach(run.steps) { step in
                    HStack(alignment: .top, spacing: 6) {
                        SubagentStateIcon(state: step.status, active: step.active)
                        VStack(alignment: .leading, spacing: 1) {
                            Text([step.agent, step.label].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption.weight(.semibold))
                            if !step.line.isEmpty {
                                Text(step.line).font(.caption2.monospaced())
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if let t = step.elapsed() {
                            Text(t).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                }
            } else {
                Text("Waiting for the run's status file…").font(.caption).foregroundStyle(.secondary)
            }
            Button("All subagents", systemImage: "person.2", action: open)
                .font(.caption)
        }
        .padding(.bottom, 2)
    }
}

/// "2 agents running" above the composer while pi-subagents works.
struct ActiveSubagents: View {
    let runs: [SubagentRun]
    let open: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(runs) { run in
                Button(action: open) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(Theme.signalText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(run.title).font(.subheadline.weight(.semibold)).lineLimit(1)
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
                .accessibilityIdentifier("active-subagent")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func detail(_ run: SubagentRun) -> String {
        let step = run.currentStep
        let where_ = [step?.agent, step?.label].compactMap { $0 }.joined(separator: " · ")
        let parts = [where_, step?.line ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? run.stateLabel : parts.joined(separator: " — ")
    }
}

struct SubagentsSheet: View {
    @Bindable var monitor: SubagentMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Scope", selection: $monitor.all) {
                        Text("This chat").tag(false)
                        Text("All chats").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if monitor.runs.isEmpty {
                    Section {
                        if monitor.loading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            ContentUnavailableView {
                                Label("No subagent runs", systemImage: "person.2")
                            } description: {
                                Text("When pi runs a `subagent` tool call, its steps, current tool and output show up here while it works.")
                            }
                        }
                    }
                }
                if !monitor.active.isEmpty {
                    Section("Running · \(monitor.active.count)") {
                        ForEach(monitor.active) { run in
                            SubagentRunRows(run: run, home: model.home)
                        }
                    }
                }
                if !monitor.finished.isEmpty {
                    Section("Finished · \(monitor.finished.count)") {
                        ForEach(monitor.finished.prefix(20)) { run in
                            SubagentRunRows(run: run, home: model.home)
                        }
                    }
                }
                if monitor.problem != nil {
                    Section { Text(monitor.problem ?? "").foregroundStyle(Theme.danger).font(.footnote) }
                }
                Section {
                } footer: {
                    Text("Read from pi-subagents' own run files. Finished runs are kept for a day.")
                }
            }
            .navigationTitle("Subagents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await monitor.refresh() }
            .task {
                await monitor.refresh()
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One run: a header, its steps (each opening a child chat), and its log tail.
private struct SubagentRunRows: View {
    let run: SubagentRun
    let home: String?
    @State private var openLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SubagentStateIcon(state: run.state, active: run.active)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(run.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(run.elapsed()).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            if let cwd = run.cwd {
                Text(Format.tilde(cwd, home: home)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }

            ForEach(run.steps) { step in
                if let file = step.sessionFile, !file.isEmpty {
                    NavigationLink {
                        ChatView(path: file, cwd: run.cwd ?? "")
                    } label: {
                        SubagentStepLabel(step: step)
                    }
                    .accessibilityIdentifier("subagent-step")
                } else {
                    SubagentStepLabel(step: step)
                }
            }
            if run.steps.isEmpty {
                Text("Starting… no step recorded yet.").font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: $openLog) {
                SubagentLog(runId: run.id)
                    .padding(.top, 4)
            } label: {
                Text("Output tail").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A step's state, agent, current tool, last output and time. Tappable when
/// the caller wraps it in a NavigationLink.
private struct SubagentStepLabel: View {
    let step: SubagentStep

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SubagentStateIcon(state: step.status, active: step.active)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(step.agent ?? "agent").font(.footnote.weight(.semibold))
                    if let label = step.label, !label.isEmpty {
                        Text(label).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .overlay(Capsule().stroke(Theme.hairline))
                    }
                    Spacer(minLength: 0)
                    if let t = step.elapsed() { Text(t).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                }
                if !step.line.isEmpty {
                    Text(step.line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if let out = step.recentOutput.last, !out.isEmpty, out != step.line {
                    Text(out).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                }
                let meta = [step.model, step.tokens.map { Format.tokens($0) }].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct SubagentStateIcon: View {
    let state: String
    let active: Bool

    var body: some View {
        if active {
            ProgressView().controlSize(.mini).tint(Theme.signalText).frame(width: 16)
        } else {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityLabel(Subagents.stateLabel(state))
        }
    }

    private var symbol: String {
        switch Subagents.stateLabel(state) {
        case "done": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "needs you": "exclamationmark.circle.fill"
        case "stopped": "pause.circle.fill"
        default: "clock"
        }
    }

    private var tint: Color {
        switch Subagents.stateLabel(state) {
        case "done": Theme.signalText
        case "failed": Theme.danger
        case "needs you": .orange
        default: .secondary
        }
    }
}

/// The run's `output-<n>.log` tails, read only when opened.
private struct SubagentLog: View {
    let runId: String
    @Environment(AppModel.self) private var model
    @State private var detail: SubagentDetail?
    @State private var problem: String?
    @State private var showAll = false

    var body: some View {
        Group {
            if let detail {
                if detail.outputs.isEmpty {
                    Text("No output log yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(detail.outputs) { output in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(output.label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            let long = output.text.count > 6000 && !showAll
                            Text(long ? "…" + String(output.text.suffix(6000)) : (output.text.isEmpty ? "(empty)" : output.text))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if long { Button("Show all \(output.text.count) characters") { showAll = true }.font(.caption) }
                        }
                    }
                }
            } else if let problem {
                Text(problem).font(.caption).foregroundStyle(Theme.danger)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            guard let client = model.client else { return }
            do {
                detail = try await client.subagent(id: runId)
            } catch {
                problem = error.reportable
            }
        }
    }
}
