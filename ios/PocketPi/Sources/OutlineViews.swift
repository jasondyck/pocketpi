import PocketPiKit
import SwiftUI

// Turn outline: the title-menu entry and its sheet.
// Placeholders until its wave fills them in (docs/dsh-features-plan.md §3.7).

struct OutlineMenuButtons: View {
    let session: ChatSession
    @Binding var sheet: ChatFeatureSheet?
    var body: some View { EmptyView() }
}

struct OutlineSheet: View {
    let session: ChatSession
    var body: some View { EmptyView() }
}
