import PocketPiKit
import SwiftUI

// Goal mode: the strip above the composer, the title-menu entry and its sheet.
// Placeholders until its wave fills them in (docs/dsh-features-plan.md §3.1).

/// Above the composer while the chat has a goal.
struct GoalStrip: View {
    let session: ChatSession
    var body: some View { EmptyView() }
}

/// Title-menu entries.
struct GoalMenuButtons: View {
    let session: ChatSession
    @Binding var sheet: ChatFeatureSheet?
    var body: some View { EmptyView() }
}

struct GoalSheet: View {
    let session: ChatSession
    var body: some View { EmptyView() }
}
