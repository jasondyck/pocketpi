import PocketPiKit
import SwiftUI

/// A drawer from the left edge over `content`, like the web app's project
/// rail and the Claude app's menu. Opens with the toolbar button or a swipe
/// from the left edge (only while `edgeSwipe` is true, so it doesn't fight
/// the back swipe inside a chat); closes with a swipe left or a tap outside.
struct SideMenu<Drawer: View, Content: View>: View {
    @Binding var isOpen: Bool
    var edgeSwipe: Bool
    @ViewBuilder var menu: Drawer
    @ViewBuilder var content: Content

    @State private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = min(320, geo.size.width * 0.84)
            // How far open, 0...1, following the finger while dragging.
            let shown = max(0, min(width, (isOpen ? width : 0) + drag))
            let progress = shown / width

            ZStack(alignment: .leading) {
                content
                    .allowsHitTesting(!isOpen)
                    .accessibilityHidden(isOpen)

                Color.black.opacity(0.35 * progress)
                    .ignoresSafeArea()
                    .allowsHitTesting(isOpen)
                    .onTapGesture { set(false) }
                    .accessibilityHidden(true)

                if edgeSwipe && !isOpen {
                    Color.clear
                        .frame(width: 18)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(width: width))
                        .ignoresSafeArea()
                }

                menu
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                    .offset(x: shown - width)
                    .shadow(color: .black.opacity(0.18 * progress), radius: 16, x: 4)
                    .gesture(dragGesture(width: width), isEnabled: isOpen)
                    .accessibilityHidden(!isOpen)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.05), value: isOpen)
        .sensoryFeedback(.impact(weight: .light), trigger: isOpen)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                let dx = v.translation.width
                drag = isOpen ? min(0, dx) : max(0, dx)
            }
            .onEnded { v in
                let dx = v.predictedEndTranslation.width
                let open = isOpen ? dx > -width / 3 : dx > width / 3
                drag = 0
                set(open)
            }
    }

    private func set(_ open: Bool) {
        isOpen = open
    }
}

/// The menu: all chats, pinned projects, then the rest by last activity.
struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var selected: String?
    let close: () -> Void
    @State private var renaming: Project?
    @State private var newName = ""

    private var shown: [Project] { model.projects.filter(\.exists) }
    private var pinned: [Project] { shown.filter(\.pinned) }
    private var recent: [Project] { shown.filter { !$0.pinned }.sorted { $0.modified > $1.modified } }

    var body: some View {
        List {
            Section {
                row(title: "All chats", path: nil, count: model.sessions.count, live: model.sessions.contains(where: \.streaming)) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.subheadline)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.secondary)
                }
            }
            if !pinned.isEmpty {
                Section("Pinned") { ForEach(pinned) { projectRow($0) } }
            }
            if !recent.isEmpty {
                Section(pinned.isEmpty ? "Projects" : "Recent") { ForEach(recent) { projectRow($0) } }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("pocketpi").font(.title2.weight(.bold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                }
                .glass(in: Circle(), interactive: true)
                .accessibilityLabel("Close menu")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { serverFooter }
        .refreshable { await model.refresh() }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let p = renaming { act { try await $0.saveProject(path: p.path, name: newName) } }
            }
        } message: {
            Text("Leave it empty for the folder's name.")
        }
    }

    private func projectRow(_ p: Project) -> some View {
        row(title: p.name, path: p.path, count: p.chats, live: p.streaming) {
            ProjectBadge(path: p.path, name: p.name)
        }
        .contextMenu {
            if !p.pinned {
                Button("Pin", systemImage: "pin") { act { try await $0.saveProject(path: p.path) } }
            }
            Button("Rename", systemImage: "pencil") {
                newName = p.name
                renaming = p
            }
            Button(p.pinned ? "Unpin and hide" : "Hide", systemImage: "eye.slash", role: .destructive) {
                if selected == p.path { selected = nil }
                act { try await $0.hideProject(path: p.path) }
            }
        }
    }

    private func row<Icon: View>(title: String, path: String?, count: Int, live: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        let on = selected == path
        return Button {
            selected = path
            close()
        } label: {
            HStack(spacing: 12) {
                icon()
                Text(title)
                    .font(.body.weight(on ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if live {
                    Circle().fill(Theme.signal).frame(width: 7, height: 7)
                        .accessibilityLabel("working")
                }
                if count > 0 {
                    Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        // Plain, so the names read as text rather than accent-coloured links.
        .buttonStyle(.plain)
        .listRowBackground(on ? Theme.signalText.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("project-" + (path.map(Format.baseName) ?? "all"))
    }

    private var serverFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            Text(model.client?.server.display ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Menu {
                Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    close()
                    model.disconnect()
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 36, height: 36)
            }
            .glass(in: Circle(), interactive: true)
            .accessibilityLabel("Server")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func act(_ f: @escaping (PocketPiClient) async throws -> Void) {
        guard let client = model.client else { return }
        Task {
            try? await f(client)
            await model.refresh()
        }
    }
}
