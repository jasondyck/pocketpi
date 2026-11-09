import PocketPiKit
import SwiftUI

// Where the per-chat features (docs/dsh-features-plan.md) plug into the chat
// screen. ChatView places each feature's views; each feature owns its file:
//   GoalViews.swift     goal mode: GoalStrip, GoalMenuButtons, GoalSheet
//   ModesViews.swift    plan mode, todos, presets: ModeChips, TodoDock,
//                       ModesMenuButtons
//   OutlineViews.swift  turn outline: OutlineMenuButtons, OutlineSheet
//   FilesViews.swift    files panel: FilesMenuButtons, FilesScreen
// A feature's state comes from `session.extensionUI.feature("pp-…")`
// and its commands go through `session.control(_:args:)`.

/// A sheet a feature opens from the chat's title menu.
enum ChatFeatureSheet: String, Identifiable {
    case goal, outline, files
    var id: String { rawValue }
}

/// The content of a feature sheet.
struct ChatFeatureSheetView: View {
    let kind: ChatFeatureSheet
    let session: ChatSession

    var body: some View {
        switch kind {
        case .goal: GoalSheet(session: session)
        case .outline: OutlineSheet(session: session)
        case .files: FilesScreen(session: session)
        }
    }
}
