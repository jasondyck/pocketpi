import PocketPiKit
import SwiftUI

// Settings › MCP servers (plan F7, F8): the servers pi would connect to,
// globally and in the picked project, with their state, tools and errors;
// add, remove, enable, exposure, a per-project on/off, and sign-in, which
// runs `/mcp login` in a chat for the project and is finished here (open
// the page, paste the address the browser ended on). Logic in PocketPiKit's
// Mcp.swift; web twin web/manage-mcp.js.

extension SettingsPage {
    static let mcp = SettingsPage(id: "mcp", title: "MCP servers", subtitle: "Tools from Model Context Protocol servers",
                                  systemImage: "server.rack", order: 47) { SettingsMcpPage() }
}

private struct SettingsMcpPage: View {
    @Environment(SettingsHub.self) private var hub
    @State private var projects: [Project] = []
    @State private var project = ""
    @State private var files: (global: PiConfigDocument, project: PiConfigDocument?)?
    @State private var report: McpReport?
    @State private var error: String?
    @State private var log = PiJobLog()
    @State private var adding = false

    private var cwd: String? { project.isEmpty ? nil : project }
    private var servers: [McpServer] {
        guard let f = files else { return [] }
        return McpServers.merge(global: f.global.data, project: f.project?.data, report: report)
    }

    var body: some View {
        List {
            Section {
                Picker("Project", selection: $project) {
                    Text("No project").tag("")
                    ForEach(projects) { p in Text(p.name).tag(p.path) }
                }
                .accessibilityIdentifier("mcp-project")
                if let n = report?.note { Text(n).font(.footnote).foregroundStyle(.orange) }
            }
            if files != nil {
                Section {
                    if servers.isEmpty { Text("No MCP servers yet").foregroundStyle(.secondary) }
                    ForEach(servers) { s in
                        NavigationLink {
                            McpServerDetail(server: s, cwd: cwd, log: log) { await load() }
                        } label: { McpRow(server: s) }
                        .accessibilityIdentifier("mcp-\(s.name)")
                    }
                    Button("Add a server") { adding = true }
                } header: {
                    Text("Servers")
                } footer: {
                    if report == nil { Text("Connecting to each server to check it…") }
                    else if let e = report?.error { Text("pi mcp list: \(e)") }
                    else if let errs = report?.errors, !errs.isEmpty { Text(errs.joined(separator: "\n")) }
                    else { Text("Chats load MCP changes when they restart.") }
                }
            } else if let error {
                Section { Text(error).foregroundStyle(.red) }
            } else {
                Section { ProgressView() }
            }
            if log.status != nil {
                Section(log.headline) {
                    Text(log.output.isEmpty ? "Waiting for pi…" : log.output).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .sheet(isPresented: $adding) {
            McpAddSheet(cwd: cwd) { action, name in
                adding = false
                Task {
                    await log.run("Adding \(name)", action, client: hub.client)
                    await hub.changed()
                    await load()
                }
            }
        }
        .task(id: project) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if projects.isEmpty, let p = try? await hub.client.projects() { projects = p.projects }
        do {
            files = try await hub.client.mcpFiles(cwd: cwd)
            error = nil
        } catch {
            self.error = error.reportable
            return
        }
        report = nil
        let want = project
        let r: McpReport
        do { r = try await hub.client.mcpReport(cwd: cwd) } catch {
            r = McpReport(error: error.localizedDescription)
        }
        if want == project { report = r }
    }
}

private struct McpRow: View {
    let server: McpServer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(server.name).font(.body.monospaced())
            Text(server.transport).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                Badge(text: server.stateText.text, tone: server.stateText.tone)
                Badge(text: server.scope, tone: -1)
                if server.exposure != .codemode { Badge(text: server.exposure.rawValue, tone: -1) }
                if server.override != nil { Badge(text: "project override", tone: -1) }
            }
        }
    }
}

private struct Badge: View {
    let text: String
    /// 0 good, 1 warning, 2 bad, else neutral.
    let tone: Int

    var body: some View {
        Text(text).font(.caption2.monospaced())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(tone == 0 ? Color.green : tone == 1 ? Color.orange : tone == 2 ? Color.red : Color.secondary)
    }
}

private struct McpServerDetail: View {
    @Environment(SettingsHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    let server: McpServer
    let cwd: String?
    let log: PiJobLog
    let reload: () async -> Void
    @State private var busy = false
    @State private var confirmRemove = false
    @State private var signin: McpSignin?
    @State private var note: String?

    init(server: McpServer, cwd: String?, log: PiJobLog, reload: @escaping () async -> Void) {
        self.server = server
        self.cwd = cwd
        self.log = log
        self.reload = reload
    }

    var body: some View {
        List {
            Section {
                LabeledContent(server.isURL ? "URL" : "Command") { Text(server.transport).font(.footnote.monospaced()).textSelection(.enabled) }
                LabeledContent("State") { Badge(text: server.stateText.text, tone: server.stateText.tone) }
                if let d = server.description { LabeledContent("About", value: d) }
                if let e = server.error { Text(e).font(.footnote.monospaced()).foregroundStyle(.red) }
                if let note { Text(note).font(.footnote) }
            }
            if server.definedIn != nil {
                Section {
                    Toggle(server.definedIn == "global" && cwd != nil ? "Enabled everywhere" : "Enabled",
                           isOn: Binding(get: { server.enabledInFile }, set: { on in Task { await edit(.enabled(server, on, cwd: cwd)) } }))
                        .disabled(busy)
                    Picker("Exposure", selection: Binding(get: { server.shownExposure },
                                                         set: { x in Task { await edit(.exposure(server, x, cwd: cwd)) } })) {
                        ForEach(McpExposure.allCases) { x in Text(x.title).tag(x) }
                    }
                    .disabled(busy)
                } footer: {
                    Text(server.shownExposure.detail)
                }
            }
            if let cwd, server.definedIn == "global" {
                Section("In this project") {
                    Picker("In this project", selection: Binding(get: { server.projectState },
                                                                set: { s in Task { await edit(.inProject(server, s, cwd: cwd)) } })) {
                        Text("Like global").tag(PiToggleState.inherit)
                        Text("On").tag(PiToggleState.on)
                        Text("Off").tag(PiToggleState.off)
                    }
                    .pickerStyle(.segmented)
                    .disabled(busy)
                }
            }
            if !server.tools.isEmpty {
                Section("Tools (\(server.tools.count))") {
                    ForEach(server.tools, id: \.self) { t in
                        HStack {
                            Text(t).font(.footnote.monospaced())
                            Spacer()
                            if let x = server.toolExposure[t] { Text(x).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section {
                if server.isURL {
                    Button("Sign in") { Task { await chat(.login) } }.disabled(busy)
                    Button("Sign out") {
                        Task {
                            await log.run("Signing out of \(server.name)", .mcpLogout(name: server.name, local: server.definedIn == "project", cwd: cwd), client: hub.client)
                            note = log.output
                        }
                    }
                    .disabled(busy || log.busy)
                }
                if server.enabled, hub.status?.live.contains(where: { $0.kind == "chat" && $0.cwd == (cwd ?? "") }) == true {
                    Button("Reconnect in the open chat") { Task { await chat(.reconnect) } }.disabled(busy)
                }
                if server.definedIn != nil {
                    Button("Remove…", role: .destructive) { confirmRemove = true }.disabled(log.busy)
                }
            } footer: {
                if server.isURL { Text("Sign-in runs /mcp login in a chat for this project (the open one, or a new one).") }
            }
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { signin.map(SigninBox.init) }, set: { if $0 == nil { signin = nil } })) { box in
            McpSigninSheet(server: server.name, signin: box.signin) { msg in
                signin = nil
                note = msg
                Task { try? await Task.sleep(for: .seconds(2)); await reload() }
            }
        }
        .confirmationDialog("Remove \(server.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    let local = server.definedIn == "project"
                    let job = await log.run("Removing \(server.name)", .mcpRemove(name: server.name, local: local, cwd: local ? cwd : nil), client: hub.client)
                    await hub.changed()
                    await reload()
                    if job?.status == "ok" { dismiss() }
                }
            }
        } message: {
            Text("It's taken out of \(server.definedIn == "project" ? "this project's" : "the global") mcp.json.")
        }
    }

    private func edit(_ e: McpEdit) async {
        busy = true
        defer { busy = false }
        do {
            try await hub.client.editMcpServer(e)
            await hub.changed()
            await reload()
            dismiss()
        } catch {
            hub.problem = error.reportable
        }
    }

    private func chat(_ action: McpChatAction) async {
        busy = true
        defer { busy = false }
        do {
            let r = try await hub.client.mcpChat(action, server: server.name, cwd: cwd)
            if action == .login, r.url != nil || r.dialogID != nil {
                signin = r
            } else {
                note = (r.notices + [r.error].compactMap { $0 }).joined(separator: "\n")
            }
            await hub.refresh()
        } catch {
            hub.problem = error.reportable
        }
    }
}

private struct SigninBox: Identifiable {
    let signin: McpSignin
    var id: String { signin.key + (signin.dialogID ?? "") }
}

private struct McpSigninSheet: View {
    @Environment(SettingsHub.self) private var hub
    let server: String
    let signin: McpSignin
    let done: (String?) -> Void
    @State private var redirect = ""
    @State private var busy = false

    init(server: String, signin: McpSignin, done: @escaping (String?) -> Void) {
        self.server = server
        self.signin = signin
        self.done = done
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(signin.notices, id: \.self) { Text($0).font(.footnote) }
                if let u = signin.url.flatMap(URL.init(string:)) {
                    Section {
                        Link("Open the sign-in page", destination: u)
                    } header: {
                        Text("1. Approve pi")
                    }
                }
                if signin.dialogID != nil {
                    Section {
                        TextField(signin.placeholder ?? "http://127.0.0.1:…/callback?code=…", text: $redirect)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                            .accessibilityIdentifier("mcp-redirect")
                        Button("Finish sign-in") { Task { await finish(redirect) } }
                            .disabled(redirect.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    } header: {
                        Text("2. Paste the address")
                    } footer: {
                        Text("After you approve, the browser goes to an address on 127.0.0.1 that won't open on this phone. Copy that address and paste it here.")
                    }
                }
            }
            .navigationTitle("Sign in to \(server)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Task { await finish(nil) } } }
            }
        }
    }

    private func finish(_ value: String?) async {
        busy = true
        defer { busy = false }
        do {
            try await hub.client.finishSignin(signin, redirect: value?.trimmingCharacters(in: .whitespaces))
            done(value == nil ? nil : "Signing in to \(server)…")
        } catch {
            hub.problem = error.reportable
            done(nil)
        }
    }
}

private struct McpAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let cwd: String?
    let add: (PiAction, String) -> Void
    @State private var form = McpAddForm()
    @State private var problem: String?

    init(cwd: String?, add: @escaping (PiAction, String) -> Void) {
        self.cwd = cwd
        self.add = add
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (letters, digits, _ and -)", text: $form.name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Kind", selection: $form.useURL) {
                        Text("Command (stdio)").tag(false)
                        Text("URL (HTTP)").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if form.useURL {
                    Section {
                        TextField("https://example.com/mcp", text: $form.url)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Headers, Name=Value per line", text: $form.headers, axis: .vertical)
                            .lineLimit(2...5).font(.footnote.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } footer: {
                        Text("Without an Authorization header the server can sign in with OAuth.")
                    }
                } else {
                    Section {
                        TextField("Command, e.g. npx", text: $form.command)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Arguments, one per line", text: $form.args, axis: .vertical)
                            .lineLimit(2...6).font(.footnote.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Environment, KEY=VALUE per line", text: $form.env, axis: .vertical)
                            .lineLimit(1...5).font(.footnote.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } footer: {
                        Text("Values are saved in mcp.json as written; put secrets in environment variables (${NAME}).")
                    }
                }
                Section {
                    TextField("What it offers (optional)", text: $form.description)
                    Picker("Exposure", selection: $form.exposure) {
                        ForEach(McpExposure.allCases) { x in Text(x.title).tag(x) }
                    }
                    if cwd != nil { Toggle("Only in this project", isOn: $form.inProject) }
                }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            .navigationTitle("Add an MCP server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        switch form.action(cwd: cwd) {
                        case .success(let a): add(a, form.name.trimmingCharacters(in: .whitespaces))
                        case .failure(let e): problem = e.message
                        }
                    }
                }
            }
        }
    }
}
