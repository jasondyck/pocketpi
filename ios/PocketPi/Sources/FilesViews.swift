import PocketPiKit
import SwiftUI

// Files panel: the title-menu entry and the Files screen.
// Placeholders until its wave fills them in (docs/dsh-features-plan.md §3.5).

struct FilesMenuButtons: View {
    let session: ChatSession
    @Binding var sheet: ChatFeatureSheet?
    var body: some View { EmptyView() }
}

struct FilesScreen: View {
    let session: ChatSession
    var body: some View { EmptyView() }
}
