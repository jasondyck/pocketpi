import PocketPiKit
import SwiftUI

// The Settings tab: a list of pages plus "Restart to apply"
// (docs/pi-parity-plan.md §7).
//
// Contract for a page author:
//   1. A new file, Settings<Name>Page.swift, with the page's view and one entry:
//
//        extension SettingsPage {
//            static let providers = SettingsPage(id: "providers", title: "Providers",
//                subtitle: "API keys and sign-ins", systemImage: "key", order: 30) { ProvidersPage() }
//        }
//
//   2. ONE line in `SettingsPages.all` below: `.providers,`
//
// The page view reads `@Environment(SettingsHub.self) private var hub`, makes
// its calls with `hub.client` (PocketPiKit's Admin.swift has config/patch,
// jobs, the CLI helpers), and calls `await hub.changed()` after anything that
// edits pi's config so the banner shows. Logic goes in PocketPiKit (testable
// on Linux); views stay thin. Use the same `id` and `order` as the web page
// (web/manage-<id>.js), so both clients list pages alike.

/// One row in the Settings list and the screen it opens.
@MainActor
struct SettingsPage: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let systemImage: String
    /// Position in the list, ascending; the same numbers as the web hub.
    let order: Int
    let destination: @MainActor () -> AnyView

    init<V: View>(id: String, title: String, subtitle: String? = nil, systemImage: String, order: Int,
                  @ViewBuilder destination: @escaping @MainActor () -> V) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.order = order
        self.destination = { AnyView(destination()) }
    }
}

@MainActor
enum SettingsPages {
    /// Every page, one line each. The list sorts them by `order`, so add new
    /// lines at the end.
    static let all: [SettingsPage] = [
        .about,
        .providers,
        .settings,
        .trust,
        .resources,
        .safety,
        .packages,
        .mcp,
    ]

    static var sorted: [SettingsPage] {
        all.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }
}

struct SettingsTab: View {
    @Environment(AppModel.self) private var model
    let hub: SettingsHub

    var body: some View {
        NavigationStack {
            List {
                if let text = hub.bannerText {
                    Section {
                        RestartBanner(text: text, busy: hub.reloading) { Task { await apply() } }
                    }
                }
                Section {
                    ForEach(SettingsPages.sorted) { page in
                        NavigationLink {
                            page.destination()
                                .navigationTitle(page.title)
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.title)
                                    if let s = page.subtitle {
                                        Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            } icon: {
                                Image(systemName: page.systemImage)
                            }
                        }
                        .accessibilityIdentifier("settings-page-\(page.id)")
                    }
                }
                Section {
                    LabeledContent("Server", value: model.client?.server.display ?? "")
                }
            }
            .navigationTitle("Settings")
            .refreshable { await hub.refresh() }
            .task { await hub.refresh() }
        }
        .environment(hub)
        .alert("Something went wrong", isPresented: Binding(
            get: { hub.problem != nil },
            set: { if !$0 { hub.problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(hub.problem ?? "")
        }
    }

    private func apply() async {
        if let r = await hub.reload() {
            // Something still busy or failed: say so; a clean restart needs no alert.
            if !r.busy.isEmpty || !r.failed.isEmpty { hub.problem = SettingsHub.summary(of: r) }
        }
    }
}

/// "Restart to apply": a line saying why and the button. In the Settings
/// list and at the top of a chat.
struct RestartBanner: View {
    let text: String
    var busy = false
    var buttonTitle = "Restart to apply"
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) {
                if busy { ProgressView().controlSize(.small) } else { Text(buttonTitle) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(busy)
            .accessibilityIdentifier("restart-to-apply")
        }
    }
}
