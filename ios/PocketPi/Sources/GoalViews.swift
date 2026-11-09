import PocketPiKit
import SwiftUI

// Goal mode (docs/dsh-features-plan.md §3.1): the strip above the composer,
// the title-menu entry and its sheet. The state is `session.goal` (the
// "pp-goal" status extensions/pocketpi-goal.ts publishes); actions go
// through `session.runGoal(_:)` (PocketPiKit's Goal.swift). The web twin is
// web/goal.js.

/// Above the composer while the chat has a goal: the objective, phase,
/// rounds and spend, with Pause/Resume and Clear. Tapping it opens the sheet.
struct GoalStrip: View {
    let session: ChatSession
    @State private var editing = false
    @State private var confirmClear = false
    @State private var problem: String?

    var body: some View {
        if let goal = session.goal {
            HStack(spacing: 10) {
                Button { editing = true } label: {
                    HStack(spacing: 10) {
                        GoalDot(goal: goal)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(goal.objective).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(detail(goal)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Shows the goal")
                if let action = goal.toggleAction {
                    Button {
                        run(action)
                    } label: {
                        Image(systemName: action == .pause ? "pause.fill" : "play.fill")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(action == .pause ? "Pause goal" : "Resume goal")
                    .accessibilityIdentifier("goal-toggle")
                }
                Button {
                    confirmClear = true
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear goal")
                .accessibilityIdentifier("goal-clear")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("goal-strip")
            .sheet(isPresented: $editing) { GoalSheet(session: session) }
            .confirmationDialog("Clear this chat's goal?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear goal", role: .destructive) { run(.clear) }
            }
            .alert("Goal", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
        }
    }

    private func detail(_ g: Goal) -> String {
        [g.blockedDetail.map { "\(g.phaseLabel): \($0)" } ?? g.phaseLabel, g.roundsText, g.costText].joined(separator: " · ")
    }

    private func run(_ action: GoalAction) {
        Task {
            do { try await session.runGoal(action) } catch { problem = error.localizedDescription }
        }
    }
}

/// The goal's phase as a dot: lime while running, amber waiting, red
/// blocked, green complete, grey paused.
private struct GoalDot: View {
    let goal: Goal

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay {
                if goal.isRunning {
                    Circle().stroke(Theme.signal.opacity(0.4), lineWidth: 3).frame(width: 15, height: 15)
                }
            }
            .frame(width: 15, height: 15)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch goal.phase {
        case .active: goal.armed ? Theme.signal : .orange
        case .paused: .secondary
        case .blocked: Theme.danger
        case .complete: .green
        }
    }
}

/// Title-menu entries.
struct GoalMenuButtons: View {
    let session: ChatSession
    @Binding var sheet: ChatFeatureSheet?

    var body: some View {
        Button(session.goal == nil ? "Start a goal…" : "Goal…", systemImage: "flag") { sheet = .goal }
            .disabled(session.key == nil && session.path == nil)
            .accessibilityIdentifier("goal-menu")
    }
}

/// Start a goal (objective, caps, "save as default"), or look at and change
/// the chat's goal (edit, pause or resume, clear).
struct GoalSheet: View {
    let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var objective = ""
    @State private var maxRounds = GoalDefaults.builtIn.maxRounds
    @State private var maxCost = GoalDefaults.builtIn.maxCost
    @State private var saveAsDefault = false
    @State private var loaded = false
    @State private var busy = false
    @State private var confirmClear = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        let goal = session.goal
        NavigationStack {
            Form {
                if let goal {
                    Section {
                        LabeledContent("Status") {
                            HStack(spacing: 6) {
                                GoalDot(goal: goal)
                                Text(goal.phaseLabel)
                            }
                        }
                        if let why = goal.blockedDetail {
                            LabeledContent("Blocked by", value: why)
                        }
                        LabeledContent("Rounds", value: "\(goal.rounds) of \(goal.maxRounds)")
                        LabeledContent("Spent", value: goal.costText)
                    } footer: {
                        if goal.phase == .active && !goal.armed {
                            Text("pi doesn't pick a goal back up on its own after a restart or a stop. Resume it to carry on.")
                        }
                    }
                }
                Section {
                    TextField("What should be true when pi is done?", text: $objective, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                        .accessibilityIdentifier("goal-objective")
                } header: {
                    Text("Objective")
                } footer: {
                    if goal == nil {
                        Text("pi works on it in rounds until it marks it complete, it's blocked, or a cap is reached.")
                    }
                }
                Section {
                    Stepper(value: $maxRounds, in: 1...1000) {
                        LabeledContent("Max rounds", value: "\(maxRounds)")
                    }
                    .accessibilityIdentifier("goal-max-rounds")
                    LabeledContent("Max cost") {
                        TextField("Dollars", value: $maxCost, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("goal-max-cost")
                    }
                    if goal == nil {
                        Toggle("Save as default", isOn: $saveAsDefault)
                            .accessibilityIdentifier("goal-save-default")
                    }
                } header: {
                    Text("Caps")
                } footer: {
                    Text("The goal stops as blocked when it reaches either cap.")
                }
                if let goal {
                    Section {
                        if let action = goal.toggleAction {
                            Button(action == .pause ? "Pause" : "Resume", systemImage: action == .pause ? "pause" : "play") {
                                perform(action, close: true)
                            }
                        }
                        Button("Clear goal", systemImage: "xmark.circle", role: .destructive) { confirmClear = true }
                    }
                }
            }
            .disabled(busy)
            .navigationTitle(goal == nil ? "Start a goal" : "Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(goal == nil ? "Start" : "Save") { save(goal) }
                        .disabled(trimmed.isEmpty || maxRounds < 1 || !(maxCost > 0) || busy)
                        .accessibilityIdentifier("goal-save")
                }
            }
            .confirmationDialog("Clear this chat's goal?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear goal", role: .destructive) { perform(.clear, close: true) }
            }
            .alert("Goal", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .task {
                guard !loaded else { return }
                loaded = true
                if let goal {
                    objective = goal.objective
                    maxRounds = goal.maxRounds
                    maxCost = goal.maxCost
                } else {
                    let d = await session.goalDefaults()
                    maxRounds = d.maxRounds
                    maxCost = d.maxCost
                    focused = true
                }
            }
        }
        .accessibilityIdentifier("goal-sheet")
    }

    private var trimmed: String { objective.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save(_ goal: Goal?) {
        let caps = GoalDefaults(maxRounds: maxRounds, maxCost: maxCost)
        let text = trimmed
        busy = true
        Task {
            defer { busy = false }
            do {
                if let goal {
                    let capsChanged = caps.maxRounds != goal.maxRounds || caps.maxCost != goal.maxCost
                    try await session.runGoal(.edit(goal: goal, objective: text == goal.objective ? nil : text,
                                                    caps: capsChanged ? caps : nil))
                } else {
                    if saveAsDefault { try await session.saveGoalDefaults(caps) }
                    try await session.runGoal(.create(objective: text, caps: caps))
                }
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func perform(_ action: GoalAction, close: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await session.runGoal(action)
                if close { dismiss() }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
