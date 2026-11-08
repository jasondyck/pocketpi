import PocketPiKit
import SwiftUI
import UIKit

// Settings › Providers: which model providers pi can use (`pi auth check` for
// each) and API keys for the ones that take one. Keys go in through a
// SecureField and never come back; OAuth sign-ins stay in a terminal. Logic
// in PocketPiKit's Providers.swift; web twin web/manage-providers.js.

extension SettingsPage {
    static let providers = SettingsPage(id: "providers", title: "Providers", subtitle: "Sign-ins and API keys",
                                        systemImage: "key", order: 20) { SettingsProvidersPage() }
}

private struct SettingsProvidersPage: View {
    @Environment(SettingsHub.self) private var hub
    @State private var report: PiProvidersReport?
    @State private var problem: String?
    @State private var showMore = false

    var body: some View {
        List {
            if let report {
                if report.defaultLabel != nil || report.fallbackModel != nil {
                    Section {
                        if let d = report.defaultLabel {
                            LabeledContent("Default model") { Text(d).font(.footnote.monospaced()) }
                        }
                        if let f = report.fallbackModel {
                            LabeledContent("Fallback") {
                                Text(f).font(.footnote.monospaced())
                                    .foregroundStyle(report.fallbackBroken ? Color.orange : Color.secondary)
                            }
                        }
                    } footer: {
                        if report.fallbackBroken, let id = report.fallbackProvider {
                            Text("When \(report.fallbackFrom.joined(separator: ", ")) hit a usage limit, chats switch to the fallback, but \(report.provider(id)?.name ?? id) isn't ready.")
                        }
                    }
                }
                Section("Set up") {
                    if report.setUp.isEmpty {
                        Text("No provider is set up yet. pi can't reach a model until one is.").foregroundStyle(.secondary)
                    }
                    rows(report.setUp)
                }
                if !report.popular.isEmpty {
                    Section("Popular") { rows(report.popular) }
                }
                if !report.more.isEmpty {
                    Section {
                        if showMore {
                            rows(report.more)
                        } else {
                            Button("Show \(report.more.count) more") { showMore = true }
                        }
                    } header: {
                        Text("More providers")
                    } footer: {
                        Text("Checked with pi auth check. Keys you save here go into pi's auth.json and are never shown again. Open chats pick changes up after a restart.")
                    }
                }
            } else if let problem {
                ContentUnavailableView("Couldn't check providers", systemImage: "exclamationmark.triangle", description: Text(problem))
            } else {
                HStack { Spacer(); ProgressView("Checking providers…"); Spacer() }
            }
        }
        .task { await load(refresh: false) }
        .refreshable { await load(refresh: true) }
    }

    private func rows(_ list: [PiProvider]) -> some View {
        ForEach(list) { p in
            NavigationLink {
                ProviderDetail(provider: p) { changed in report?.replace(changed) }
                    .navigationTitle(p.name)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                        Text(p.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    ProviderStatusBadge(provider: p)
                }
            }
            .accessibilityIdentifier("provider-\(p.id)")
        }
    }

    private func load(refresh: Bool) async {
        do {
            report = try await hub.client.providers(refresh: refresh)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct ProviderStatusBadge: View {
    let provider: PiProvider

    private var color: Color {
        switch provider.status {
        case .ready: .green
        case .invalid: .red
        case .unknown: .orange
        case .notConfigured: .secondary
        }
    }

    var body: some View {
        Text(provider.statusLabel)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

private struct ProviderDetail: View {
    @Environment(SettingsHub.self) private var hub
    @State private var provider: PiProvider
    let onChange: (PiProvider) -> Void
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemove = false
    @State private var copied = false

    init(provider: PiProvider, onChange: @escaping (PiProvider) -> Void) {
        _provider = State(initialValue: provider)
        self.onChange = onChange
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { ProviderStatusBadge(provider: provider) }
                Text(provider.detail).foregroundStyle(.secondary)
                if provider.status != .ready, let why = provider.reasonText {
                    Text(why).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text(provider.id).font(.footnote.monospaced())
            }

            if provider.apiKey {
                Section {
                    SecureField(provider.hasStoredKey ? "New key" : "Paste the key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .onSubmit { Task { await save() } }
                        .accessibilityIdentifier("provider-key")
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text(provider.hasStoredKey ? "Replace" : "Save") }
                    }
                    .disabled(saving || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text(provider.hasStoredKey ? "Replace the API key" : "Add an API key")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if provider.isSignedIn { Text("Saving a key replaces your \(provider.name) sign-in.").foregroundStyle(.orange) }
                        if let v = provider.env.first { Text("Or set \(v) in pocketpi's environment. A saved key wins over it.") }
                    }
                }
                if provider.hasStoredKey {
                    Section {
                        Button("Remove key", role: .destructive) { confirmRemove = true }
                            .disabled(saving)
                    }
                }
            }

            if provider.needsTerminal {
                Section {
                    Text(provider.isSignedIn ? "To sign in again, start pi on the computer pocketpi runs on and run:"
                         : provider.oauth ? "Sign-ins need pi's terminal UI. Start pi on the computer pocketpi runs on and run:"
                         : "This provider is set up from pi's terminal UI. Start pi on the computer pocketpi runs on and run:")
                        .font(.footnote)
                    HStack {
                        Text(provider.login).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button(copied ? "Copied" : "Copy") {
                            UIPasteboard.general.string = provider.login
                            copied = true
                        }
                        .buttonStyle(.borderless)
                    }
                    if provider.isSignedIn {
                        Text("To sign out: /logout \(provider.id)").font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(provider.oauth ? "Sign in" : "Set up")
                }
            }
        }
        .confirmationDialog("Remove the \(provider.name) key from pi?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        }
    }

    private func save() async {
        if let p = ProviderKey.problem(key) { error = p; return }
        saving = true
        defer { saving = false }
        do {
            let p = try await hub.client.setProviderKey(provider.id, key: key)
            key = ""
            error = p.status == .invalid ? "Saved, but pi says the key doesn't work." : nil
            apply(p)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        saving = true
        defer { saving = false }
        do {
            apply(try await hub.client.removeProviderKey(provider.id))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ p: PiProvider) {
        provider = p
        onChange(p)
        Task { await hub.changed() }
    }
}
