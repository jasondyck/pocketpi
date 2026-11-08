import PocketPiKit
import SwiftUI

// Settings › Packages (plan F3, F4): pi packages installed globally and in
// the picked project with what each provides; install by source, update one
// or all, remove; the gallery (npm, keyword pi-package). Jobs are pi CLI
// runs; their output shows as it comes. Logic in PocketPiKit's
// Packages.swift; web twin web/manage-packages.js.

extension SettingsPage {
    static let packages = SettingsPage(id: "packages", title: "Packages", subtitle: "Install, update and remove pi packages",
                                       systemImage: "shippingbox", order: 45) { SettingsPackagesPage() }
}

private struct SettingsPackagesPage: View {
    @Environment(SettingsHub.self) private var hub
    @State private var projects: [Project] = []
    /// "" = no project: global packages only.
    @State private var project = ""
    @State private var data: PiResources?
    @State private var error: String?
    @State private var source = ""
    @State private var inProject = false
    @State private var log = PiJobLog()
    @State private var query = ""
    @State private var gallery: PiGallery?
    @State private var galleryError: String?
    @State private var installing: PiGalleryPackage?

    private var cwd: String? { project.isEmpty ? nil : project }

    var body: some View {
        List {
            Section {
                Picker("Project", selection: $project) {
                    Text("No project").tag("")
                    ForEach(projects) { p in Text(p.name).tag(p.path) }
                }
                .accessibilityIdentifier("packages-project")
                if let t = data?.trust, cwd != nil, !t.trusted {
                    Label("pi doesn't trust this project, so it neither installs nor loads its packages.", systemImage: "exclamationmark.shield")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            if let d = data {
                Section("Installed") {
                    if d.packages.isEmpty { Text("No packages yet").foregroundStyle(.secondary) }
                    ForEach(d.sortedPackages) { p in
                        NavigationLink {
                            PackageDetail(package: p, data: d, log: log, cwd: cwd) { await load() }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.shortName).font(.body.monospaced())
                                Text("\(p.isProject ? "project" : "global") · \(d.summary(of: p))\(p.installedPath == nil ? " · not installed" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("package-\(p.source)")
                    }
                    if !d.packages.isEmpty {
                        Button("Update all") { Task { await run("Updating packages", .update(extensions: true, cwd: cwd)) } }
                            .disabled(log.busy)
                    }
                    if let e = d.packagesError { Text("pi list: \(e)").font(.footnote).foregroundStyle(.orange) }
                }
            } else if let error {
                Section { Text(error).foregroundStyle(.red) }
            } else {
                Section { ProgressView() }
            }
            Section {
                TextField("npm:name, git:github.com/x/y, https://…, ./path", text: $source)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .accessibilityIdentifier("package-source")
                if cwd != nil { Toggle("In this project", isOn: $inProject) }
                Button("Install") { Task { await install(source, local: inProject && cwd != nil) } }
                    .disabled(source.trimmingCharacters(in: .whitespaces).isEmpty || log.busy)
            } header: {
                Text("Install")
            } footer: {
                Text("Packages run code as you. A path is relative to the settings file (~/.pi/agent, or the project's .pi).")
            }
            if log.status != nil {
                Section(log.headline) {
                    Text(log.output.isEmpty ? "Waiting for pi…" : log.output)
                        .font(.caption.monospaced())
                        .foregroundStyle(log.status == "failed" ? Color.red : Color.primary)
                        .textSelection(.enabled)
                }
            }
            Section {
                TextField("Search pi packages on npm", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await search() } }
                if let g = gallery {
                    ForEach(g.packages) { p in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                if let u = p.npm.flatMap(URL.init(string:)) { Link(p.name, destination: u).font(.body.monospaced()) }
                                else { Text(p.name).font(.body.monospaced()) }
                                if let d = p.description { Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                                Text(p.line).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if data?.isInstalled(npm: p.name) == true {
                                Text("Installed").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Install") { installing = p }
                                    .buttonStyle(.bordered)
                                    .disabled(log.busy)
                            }
                        }
                    }
                    if g.packages.isEmpty { Text("Nothing found").foregroundStyle(.secondary) }
                } else if let galleryError {
                    Text("Couldn't search npm: \(galleryError)").font(.footnote).foregroundStyle(.orange)
                } else {
                    ProgressView()
                }
            } header: {
                Text("Gallery")
            }
        }
        .confirmationDialog("Install \(installing?.name ?? "")?", isPresented: Binding(get: { installing != nil }, set: { if !$0 { installing = nil } }),
                            titleVisibility: .visible, presenting: installing) { p in
            if cwd != nil { Button("In this project") { Task { await install(p.source, local: true) } } }
            Button("Globally") { Task { await install(p.source, local: false) } }
        } message: { p in
            Text("\(p.description ?? p.source)\n\nPackages run code as you. Look at its source before installing.")
        }
        .task(id: project) { await load() }
        .task { await search() }
        .refreshable { await load() }
    }

    private func install(_ src: String, local: Bool) async {
        let s = src.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if await run("Installing \(PiPackageInfo.shortName(s))", .install(source: s, local: local, cwd: local ? cwd : nil))?.status == "ok" {
            source = ""
        }
    }

    @discardableResult
    private func run(_ title: String, _ action: PiAction) async -> PiJob? {
        let job = await log.run(title, action, client: hub.client)
        await hub.changed()
        await load()
        return job
    }

    private func search() async {
        do {
            gallery = try await hub.client.gallery(query: query.trimmingCharacters(in: .whitespaces))
            galleryError = nil
        } catch {
            galleryError = error.reportable
        }
    }

    private func load() async {
        if projects.isEmpty, let p = try? await hub.client.projects() { projects = p.projects }
        do {
            data = try await hub.client.resources(cwd: cwd)
            error = nil
        } catch {
            self.error = error.reportable
        }
    }
}

private struct PackageDetail: View {
    @Environment(SettingsHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    let package: PiPackageInfo
    let data: PiResources
    let log: PiJobLog
    let cwd: String?
    let reload: () async -> Void
    @State private var confirmRemove = false

    init(package: PiPackageInfo, data: PiResources, log: PiJobLog, cwd: String?, reload: @escaping () async -> Void) {
        self.package = package
        self.data = data
        self.log = log
        self.cwd = cwd
        self.reload = reload
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Source") { Text(package.source).font(.footnote.monospaced()).textSelection(.enabled) }
                LabeledContent("Scope", value: package.isProject ? "this project" : "global")
                LabeledContent("Installed at") {
                    Text(package.installedPath.map(data.tilde) ?? "not yet (pi installs it when it starts)").font(.footnote.monospaced())
                }
                if package.filtered { LabeledContent("Filter", value: "only some resources load") }
            }
            Section {
                let list = data.resources(of: package)
                if list.isEmpty { Text("pi found nothing to load in it").foregroundStyle(.secondary) }
                ForEach(list) { r in
                    HStack {
                        Text(r.kind == .prompt ? "/\(r.name)" : r.kind == .skill ? "/skill:\(r.name)" : r.name)
                            .font(.footnote.monospaced())
                            .strikethrough(!r.enabled)
                            .foregroundStyle(r.enabled ? .primary : .secondary)
                        Spacer()
                        Text(r.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Provides")
            } footer: {
                Text("Turn them on or off in Resources.")
            }
            Section {
                Button("Update") {
                    Task { await run("Updating \(package.shortName)", .update(source: package.source, cwd: cwd)) }
                }
                .disabled(log.busy)
                Button("Remove…", role: .destructive) { confirmRemove = true }
                    .disabled(log.busy)
            }
            if log.status != nil {
                Section(log.headline) {
                    Text(log.output.isEmpty ? "Waiting for pi…" : log.output).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle(package.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(package.shortName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    let job = await run("Removing \(package.shortName)",
                                        .remove(source: package.source, local: package.isProject, cwd: package.isProject ? cwd : nil))
                    if job?.status == "ok" { dismiss() }
                }
            }
        } message: {
            Text("It's taken out of \(package.isProject ? "this project's" : "the global") settings; its extensions, skills and prompts stop loading after a restart.")
        }
    }

    private func run(_ title: String, _ action: PiAction) async -> PiJob? {
        let job = await log.run(title, action, client: hub.client)
        await hub.changed()
        await reload()
        return job
    }
}
