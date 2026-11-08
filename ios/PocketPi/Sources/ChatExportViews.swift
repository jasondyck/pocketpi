import PocketPiKit
import QuickLook
import SwiftUI

// The chat title menu's extras: Compact with a focus (pi's
// compact{customInstructions}), Export as HTML and Download JSONL. The files
// open in Quick Look, whose share button sends them on. Logic in PocketPiKit
// (Exports.swift); ChatView only adds `ChatExtraButtons` to its title menu
// and `.chatExtras(...)` to its body.

/// The title menu's rows.
struct ChatExtraButtons: View {
    let session: ChatSession
    @Binding var compacting: Bool
    @Binding var preview: URL?

    var body: some View {
        Button("Compact context…", systemImage: "arrow.down.right.and.arrow.up.left") { compacting = true }
            .disabled(session.isStreaming || session.path == nil)
        Button("Export as HTML", systemImage: "doc.richtext") {
            Task { preview = await session.exportHTML() }
        }
        .disabled(session.key == nil && session.path == nil)
        Button("Download JSONL", systemImage: "square.and.arrow.down") {
            Task { preview = await session.exportJSONL() }
        }
        .disabled(session.path == nil)
    }
}

extension View {
    func chatExtras(session: ChatSession, compacting: Binding<Bool>, preview: Binding<URL?>) -> some View {
        sheet(isPresented: compacting) {
            CompactSheet(session: session)
                .presentationDetents([.medium])
        }
        .quickLookPreview(preview)
    }
}

/// "Focus the summary on…", then Compact.
private struct CompactSheet: View {
    let session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var focus = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Focus the summary on… (optional)", text: $focus, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($focused)
                        .accessibilityIdentifier("compact-focus")
                } footer: {
                    Text("pi summarizes older messages to free up context. Say what the summary should keep, or leave it empty.")
                }
            }
            .navigationTitle("Compact context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Compact") {
                        let text = focus
                        dismiss()
                        Task { await session.compact(instructions: text) }
                    }
                    .accessibilityIdentifier("compact-go")
                }
            }
            .onAppear { focused = true }
        }
    }
}
