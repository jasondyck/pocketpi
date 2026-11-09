import PocketPiKit
import SwiftUI

// Plan mode, todos and permission presets: composer chips, the todo dock and title-menu entries.
// Placeholders until its wave fills them in (docs/dsh-features-plan.md §3.2–3.3).

/// Chips in the composer row (plan mode, the permission preset).
struct ModeChips: View {
    let session: ChatSession
    var body: some View { EmptyView() }
}

/// The todo list above the composer.
struct TodoDock: View {
    let session: ChatSession
    var body: some View { EmptyView() }
}

/// Title-menu entries.
struct ModesMenuButtons: View {
    let session: ChatSession
    var body: some View { EmptyView() }
}
