import PocketPiKit
import SwiftUI

// Plan mode, todos and permission presets (docs/dsh-features-plan.md §3.2–3.3):
// composer chips, the todo dock, title-menu entries, the permissions sheet and
// the exit_plan_mode / todo_write card bodies. State comes from
// extensions/pocketpi-modes.ts through "pp-mode" / "pp-todo" (PocketPiKit Modes.swift).

/// Chips in the composer row: "Plan" while plan mode is on (tap: off) and the
/// preset (tap: the permissions sheet), hidden for plain Auto.
struct ModeChips: View {
    let session: ChatSession
    @State private var showPermissions = false

    var body: some View {
        let mode = session.chatMode
        HStack(spacing: 6) {
            if mode.plan {
                Button { Task { await session.setPlan(false) } } label: {
                    chip("Plan", symbol: "list.bullet.clipboard", tint: Theme.signalText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Plan mode on. Turn off")
                .accessibilityIdentifier("plan-chip")
            }
            if mode.showsPresetChip {
                Button { showPermissions = true } label: {
                    chip(mode.preset.label, symbol: mode.preset.symbol, tint: .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Permissions: \(mode.preset.label)")
                .accessibilityIdentifier("preset-chip")
            }
        }
        .sheet(isPresented: $showPermissions) {
            PermissionsSheet(session: session)
                .presentationDetents([.medium, .large])
        }
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

/// The todo list above the composer: "3/7 · current item", tap to expand.
struct TodoDock: View {
    let session: ChatSession
    @State private var open = false

    var body: some View {
        let todos = session.todos
        if !todos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    HStack(spacing: 10) {
                        Text("\(todos.done)/\(todos.total)")
                            .font(.footnote.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.signalText)
                        Text(todos.current?.content ?? "All done")
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Todos: \(todos.done) of \(todos.total) done" + (todos.current.map { ", now \($0.content)" } ?? ""))
                .accessibilityHint(open ? "Collapses the list" : "Shows the list")
                .accessibilityIdentifier("todo-dock-header")
                if open {
                    ScrollView {
                        TodoChecklist(items: todos.items)
                    }
                    .frame(maxHeight: 240)
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("todo-dock-list")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .accessibilityIdentifier("todo-dock")
        }
    }
}

/// A todo list as a checklist.
struct TodoChecklist: View {
    let items: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { t in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(t.status))
                        .foregroundStyle(t.status == .pending ? Color.secondary : Theme.signalText)
                        .font(.footnote)
                    Text(t.content)
                        .font(.subheadline.weight(t.status == .inProgress ? .semibold : .regular))
                        .strikethrough(t.status == .completed)
                        .foregroundStyle(t.status == .completed ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(label(t.status))
            }
        }
    }

    private func symbol(_ s: TodoItem.Status) -> String {
        switch s {
        case .pending: "square"
        case .inProgress: "square.dashed.inset.filled"
        case .completed: "checkmark.square"
        }
    }

    private func label(_ s: TodoItem.Status) -> String {
        switch s {
        case .pending: "to do"
        case .inProgress: "in progress"
        case .completed: "done"
        }
    }
}

/// Title-menu entries: the plan mode toggle and the permissions picker.
struct ModesMenuButtons: View {
    let session: ChatSession

    var body: some View {
        let mode = session.chatMode
        Toggle(isOn: Binding(get: { mode.plan }, set: { on in Task { await session.setPlan(on) } })) {
            Label("Plan mode", systemImage: "list.bullet.clipboard")
        }
        .disabled(session.key == nil)
        .accessibilityIdentifier("menu-plan-mode")
        Menu {
            Picker("This chat", selection: Binding(get: { mode.preset }, set: { p in Task { await session.setPreset(p) } })) {
                ForEach(PermissionPreset.allCases) { p in
                    Label(p.label, systemImage: p.symbol).tag(p)
                }
            }
            Menu("Default for new chats") {
                ForEach(PermissionPreset.allCases) { p in
                    Button(p.label) { Task { try? await session.client.setDefaultPreset(p) } }
                }
            }
        } label: {
            Label("Permissions: \(mode.preset.label)", systemImage: mode.preset.symbol)
        }
        .disabled(session.key == nil)
        .accessibilityIdentifier("menu-permissions")
    }
}

/// The preset for this chat, what it has allowed, and the default for new chats.
struct PermissionsSheet: View {
    let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var defaultPreset: PermissionPreset?
    @State private var problem: String?

    var body: some View {
        let mode = session.chatMode
        NavigationStack {
            List {
                Section {
                    ForEach(PermissionPreset.allCases) { p in
                        Button {
                            Task { await session.setPreset(p); dismiss() }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: p.symbol).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.label).foregroundStyle(.primary)
                                    Text(p.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if p == mode.preset {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.signalText)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(p == mode.preset ? .isSelected : [])
                        .accessibilityIdentifier("preset-\(p.rawValue)")
                    }
                } header: {
                    Text("This chat")
                } footer: {
                    Text("pocketpi's safety rules (Settings › Safety) apply under every preset: a preset can add questions and blocks, never remove them.")
                }
                let allowed = mode.allowedTools + mode.allowedCommands.map { "\($0) …" }
                if !allowed.isEmpty {
                    Section("Allowed for this chat") {
                        ForEach(allowed, id: \.self) { Text($0).font(.footnote.monospaced()) }
                        Button("Forget these", role: .destructive) { Task { await session.clearAllowances() } }
                            .accessibilityIdentifier("clear-allowances")
                    }
                }
                Section("Default for new chats") {
                    if let defaultPreset {
                        Picker("Default", selection: Binding(get: { defaultPreset }, set: { p in
                            self.defaultPreset = p
                            Task {
                                do { try await session.client.setDefaultPreset(p) } catch { problem = error.reportable }
                            }
                        })) {
                            ForEach(PermissionPreset.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("default-preset")
                    } else {
                        ProgressView()
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(Theme.danger) }
                }
            }
            .navigationTitle("Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            do { defaultPreset = try await session.client.defaultPreset() } catch {
                defaultPreset = .auto
                problem = error.reportable
            }
        }
    }
}

/// The open body of an exit_plan_mode or todo_write card (MessageViews ToolCard).
struct ModesToolBody: View {
    let name: String
    let arguments: JSONValue
    let result: ToolResult?

    static func handles(_ name: String) -> Bool { name == "exit_plan_mode" || name == "todo_write" }

    var body: some View {
        if name == "exit_plan_mode" {
            let p = PlanProposal(arguments: arguments, result: result)
            VStack(alignment: .leading, spacing: 6) {
                if let o = p.outcome {
                    Label(outcomeText(o), systemImage: o == .approved ? "checkmark.seal" : "pencil.and.list.clipboard")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(o == .approved ? Theme.signalText : Color.secondary)
                } else {
                    Label("Waiting for approval", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                }
                MarkdownView(text: p.plan.isEmpty ? "_(no plan)_" : p.plan)
            }
            .accessibilityIdentifier("plan-card")
        } else {
            let fromResult = result.flatMap { $0.isError ? nil : $0.details }.map(TodoList.init)
            let list = fromResult.flatMap { $0.isEmpty ? nil : $0 } ?? TodoList(arguments)
            TodoChecklist(items: list.items)
                .accessibilityIdentifier("todo-card")
        }
    }

    private func outcomeText(_ o: PlanProposal.Outcome) -> String {
        switch o {
        case .approved: "Approved"
        case .keepPlanning: "Kept planning"
        case .dismissed: "Not answered"
        case .error: "Not accepted"
        }
    }
}
