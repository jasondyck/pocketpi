import PocketPiKit
import SwiftUI

// Turn outline (docs/dsh-features-plan.md §3.7): "Outline" in the chat's
// title menu opens a sheet with one line per prompt of the active branch and
// the reply it got (PocketPiKit's Outline.swift). Tapping a line closes the
// sheet and scrolls the chat to that message: the sheet posts
// `.scrollToTranscriptRow` (object: the session, userInfo "row": a
// TranscriptRow id) and ChatView's ScrollViewReader scrolls there.

extension Notification.Name {
    /// Scroll a chat's transcript to a row. Object: the ChatSession;
    /// userInfo["row"]: the row's id.
    static let scrollToTranscriptRow = Notification.Name("PocketPi.scrollToTranscriptRow")
}

/// The title menu's entry.
struct OutlineMenuButtons: View {
    let session: ChatSession
    @Binding var sheet: ChatFeatureSheet?

    var body: some View {
        Button("Outline", systemImage: "list.bullet") { sheet = .outline }
            .disabled(session.path == nil)
    }
}

struct OutlineSheet: View {
    let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [OutlineTurn]?
    @State private var error: String?
    /// Said when a tapped turn isn't on screen.
    @State private var notShown: String?
    @State private var finding: String?

    var body: some View {
        NavigationStack {
            Group {
                if let turns {
                    if turns.isEmpty {
                        ContentUnavailableView("No prompts yet", systemImage: "list.bullet")
                    } else {
                        List {
                            Section {
                                ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                                    Button { Task { await open(turn) } } label: { OutlineRow(number: i + 1, turn: turn, finding: finding == turn.id) }
                                        .buttonStyle(.plain)
                                        .disabled(finding != nil)
                                }
                            } footer: {
                                if let notShown { Text(notShown) }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                } else if let error {
                    ContentUnavailableView("Couldn't read the outline", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Outline")
            .navigationSubtitle(turns.map { "\($0.count) prompt\($0.count == 1 ? "" : "s")" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do { turns = try await session.loadOutline(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func open(_ turn: OutlineTurn) async {
        finding = turn.id
        defer { finding = nil }
        guard let row = await session.transcriptRow(forEntry: turn.id) else {
            notShown = "“\(turn.prompt)” isn't in the chat on screen: it was compacted away."
            return
        }
        dismiss()
        // Once the sheet is on its way down, so the scroll isn't lost under it.
        try? await Task.sleep(for: .milliseconds(300))
        NotificationCenter.default.post(name: .scrollToTranscriptRow, object: session, userInfo: ["row": row])
    }
}

private struct OutlineRow: View {
    let number: Int
    let turn: OutlineTurn
    let finding: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(turn.prompt)
                    .font(.subheadline)
                    .lineLimit(1)
                if !turn.response.isEmpty {
                    Text(turn.response)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if finding { ProgressView().controlSize(.small) }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Scrolls the chat to this message")
    }
}
