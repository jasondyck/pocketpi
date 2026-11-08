import PocketPiKit
import SwiftUI

// Settings › About: which pi and which pocketpi build, and the config epoch.
// The smallest page that follows the contract in SettingsTab.swift (the web
// twin is web/manage-about.js).

extension SettingsPage {
    static let about = SettingsPage(id: "about", title: "About", subtitle: "pi version, pocketpi build, config epoch",
                                    systemImage: "info.circle", order: 1000) { SettingsAboutPage() }
}

private struct SettingsAboutPage: View {
    @Environment(SettingsHub.self) private var hub
    @State private var piVersion: String?
    @State private var build: UInt64?

    private var chats: [LivePi] { (hub.status?.live ?? []).filter { $0.kind != "stage" } }

    var body: some View {
        List {
            LabeledContent("pi", value: piVersion ?? "…")
            LabeledContent("pocketpi build", value: build.map(String.init) ?? "…")
            if let build {
                LabeledContent("Started", value: Date(timeIntervalSince1970: Double(build) / 1000)
                    .formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("Config epoch", value: hub.status.map { String($0.configEpoch) } ?? "–")
            LabeledContent("Running chats", value: chats.isEmpty ? "0"
                : "\(chats.count)" + (hub.staleChats.isEmpty ? "" : " · \(hub.staleChats.count) with old settings"))
            LabeledContent("Control extension", value: hub.status?.control == true ? "On" : "Off")
        }
        .monospacedDigit()
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        async let v = try? hub.client.piVersion()
        async let b = try? hub.client.version()
        await hub.refresh()
        let version = await v
        piVersion = (version?.isEmpty == false) ? version : "unknown"
        build = await b?.build
    }
}
