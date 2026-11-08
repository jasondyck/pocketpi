import Foundation
import Observation

/// An image to send with a prompt, already downscaled and base64-encoded.
public struct ImageAttachment: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var base64: String
    public var mimeType: String
    public init(base64: String, mimeType: String) {
        self.base64 = base64
        self.mimeType = mimeType
    }
}

/// One open chat: its connection to pocketpi, its transcript, and the
/// commands the screen sends. The same flow as web/app.js (reopen, connect,
/// loadSnapshot, send, stop), minus the DOM.
@MainActor
@Observable
public final class ChatSession {
    public enum Status: Equatable, Sendable {
        case idle
        case opening
        case connected
        case reconnecting
        case failed(String)
    }

    public let client: PocketPiClient
    public private(set) var transcript = Transcript()
    public private(set) var state: ChatState?
    public private(set) var stats: SessionStats?
    public private(set) var thinkingLevels: [String] = []
    /// Set at the first send; until then leaving a new chat stops its pi.
    private var sentAny = false
    /// What the model picker offers (loaded once per chat).
    public private(set) var models: [ModelInfo] = []

    /// pi's enabled-model patterns (from its settings, via the server).
    public private(set) var enabledPatterns: [String] = []
    /// The llama.cpp router's models (nil until fetched, or without a router).
    public private(set) var llama: LlamaRouter?
    /// A router model being loaded for this chat ("Loading … on arlo").
    public private(set) var loadingLocal: String?

    /// Runs pi started in this chat that are still going, for the
    /// "work in progress" line above the composer.
    public private(set) var activeRuns: [RunInfo] = []
    @ObservationIgnored private var endedRuns: Set<String> = []

    /// pi's slash commands, fetched the first time `/` is typed (nil until then).
    public private(set) var commands: [SlashCommand]?
    @ObservationIgnored private var loadingCommands = false

    /// The models picked in pi, in pi's order: the top of the model sheet.
    public var favorites: [ModelInfo] {
        var out: [ModelInfo] = []
        for p in enabledPatterns {
            for m in models where !out.contains(m) && (ModelInfo.matches(p, m.key) || ModelInfo.matches(p, m.id)) {
                out.append(m)
            }
        }
        return out
    }

    /// The chat's model as a `ModelInfo`, for the picker's checkmark.
    public var currentModel: ModelInfo? { state?.model.flatMap(ModelInfo.init) }
    /// The session file; nil for a new chat until its first prompt is saved.
    public private(set) var path: String?
    public private(set) var cwd: String
    /// The live pi process's key, while there is one.
    public private(set) var key: String?
    public private(set) var status: Status = .idle
    /// pi's config changed after this chat's pi started ("Restart to apply").
    /// From the server's hello; cleared by the reconnect after a restart.
    public private(set) var needsRestart = false
    /// The config epoch this chat's pi started at, and the server's then
    /// (from the hello), so `SettingsHub` can tell which is newer.
    public private(set) var piEpoch: UInt64?
    public private(set) var helloConfigEpoch: UInt64?
    /// Bumped when the message box should take the keyboard (after a fork
    /// puts the message back in it). The composer view watches this.
    public private(set) var composerFocusRequests = 0
    /// A dialog an extension asked for, until it is answered.
    public var pendingRequest: ExtensionRequest?
    /// The message box. Here rather than in the view because pi can set it
    /// (set_editor_text) and stop() puts queued messages back into it.
    public var composer = ""
    /// An error to show as an alert (send failed, a command failed, pi said so).
    public var problem: String?
    /// Called after each turn, so lists elsewhere can refresh.
    @ObservationIgnored public var onTurnFinished: (@MainActor () -> Void)?

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var firstEventWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var opening: Task<Void, Error>?
    @ObservationIgnored private var snapshotSeq = 0
    /// The newest snapshot that landed (or failed).
    @ObservationIgnored private var appliedSeq = 0
    @ObservationIgnored private var left = false

    /// An existing chat.
    public init(client: PocketPiClient, path: String, cwd: String) {
        self.client = client
        self.path = path
        self.cwd = cwd
    }

    /// A new chat in a folder; pi is started on the first send.
    public init(client: PocketPiClient, newIn cwd: String) {
        self.client = client
        self.cwd = cwd
    }

    public var isStreaming: Bool { transcript.isStreaming }

    public var title: String {
        if let n = state?.sessionName, !n.isEmpty { return n }
        return transcript.firstPrompt ?? (path == nil ? "New chat" : "Chat")
    }

    // MARK: - connection

    /// Open the session and follow its events. Safe to call again (on
    /// returning to the foreground): it reconnects only if the stream is down.
    public func start() async {
        left = false
        if streamTask != nil, status == .connected {
            await loadSnapshot()
            return
        }
        guard path != nil || key != nil else { return } // a new chat waits for its first send
        do { try await reopen() } catch { status = .failed(error.localizedDescription) }
    }

    /// Stop following events (the screen went away). pi keeps running on the
    /// server; pocketpi reaps it when idle.
    public func leave() {
        left = true
        streamTask?.cancel()
        streamTask = nil
        resumeWaiter()
        // A new chat that was opened but never sent to: its pi has no session
        // file and nothing to keep, so stop it rather than wait for the reaper.
        if path == nil, !sentAny, let key {
            self.key = nil
            Task { [client] in try? await client.close(key: key) }
        }
    }

    /// A new chat: start its pi now (not at the first send), so the model
    /// picker and thinking levels work before anything is typed.
    public func prepare() async {
        guard key == nil, path == nil else { return }
        do { try await ensureStarted() } catch { status = .failed(error.localizedDescription) }
    }

    private func ensureStarted() async throws {
        if key == nil, path != nil { try await reopen() }
        if key == nil {
            let r = try await client.newChat(cwd: cwd)
            key = r.key
            cwd = r.cwd
            transcript = Transcript()
            await connect()
        }
    }

    func reopen() async throws {
        if let opening { return try await opening.value }
        let t = Task { @MainActor in
            defer { self.opening = nil }
            if self.status != .reconnecting { self.status = .opening }
            if let path = self.path {
                let r = try await self.client.open(path: path)
                self.key = r.key
                self.cwd = r.cwd
            } else if self.key == nil {
                throw PocketPiError.unexpected("This chat was never saved.")
            }
            await self.connect()
        }
        opening = t
        try await t.value
    }

    /// Subscribe to the key's events; returns once the first event (hello, and
    /// with it the snapshot) has been handled, so a prompt sent next can't be
    /// wiped by that snapshot.
    private func connect() async {
        guard let key else { return }
        streamTask?.cancel()
        resumeWaiter()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            firstEventWaiter = c
            streamTask = Task { @MainActor [weak self, client] in
                var failure: Error?
                do {
                    for try await ev in client.events(key: key) {
                        guard let self, !Task.isCancelled else { return }
                        await self.handle(ev)
                        self.resumeWaiter()
                    }
                } catch {
                    failure = error
                }
                guard let self, !Task.isCancelled else { return }
                self.resumeWaiter()
                self.streamEnded(key: key, error: failure)
            }
        }
    }

    private func resumeWaiter() {
        firstEventWaiter?.resume()
        firstEventWaiter = nil
    }

    private func streamEnded(key ended: String, error: Error?) {
        streamTask = nil
        guard !left else { return }
        if key == nil { return } // pi exited; the next send reopens
        guard ended == key else { return }
        if let e = error as? PocketPiError, e.isSessionGone { key = nil }
        status = .reconnecting
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, !self.left, self.streamTask == nil else { return }
            do { try await self.reopen() } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - events

    func handle(_ ev: JSONValue) async {
        if ev["type"]?.string == "pocketpi_hello" {
            status = .connected
            needsRestart = ev["stale"]?.bool ?? false
            piEpoch = ev["epoch"]?.int.map { UInt64(max(0, $0)) }
            helloConfigEpoch = ev["config_epoch"]?.int.map { UInt64(max(0, $0)) }
        }
        for effect in transcript.apply(ev) {
            switch effect {
            case .reloadSnapshot:
                await loadSnapshot()
            case .turnFinished:
                Task { await self.afterTurn() }
            case .exited(let stderr):
                key = nil
                if !stderr.isEmpty {
                    status = .failed("pi stopped.\n" + stderr.suffix(8).joined(separator: "\n"))
                }
            case .restarting:
                // The key lives on; the stream ends and streamEnded reconnects.
                status = .reconnecting
            case .sessionFileChanged:
                // The history changed with the file; the snapshot follows the
                // file (or not, while pi hasn't written it yet).
                await loadSnapshot()
            case .extensionRequest(let r):
                show(r)
            case .setComposer(let t):
                composer = t
            case .problem(let t):
                problem = t
            case .thinkingLevelChanged(let l):
                state?.thinkingLevel = l
            case .sessionNameChanged(let n):
                state?.sessionName = n
            case .statsStale:
                Task { await self.refreshStats() }
            }
        }
    }

    public func loadSnapshot() async {
        snapshotSeq += 1
        let seq = snapshotSeq
        do {
            async let messages = command(["type": "get_messages"])
            async let st = command(["type": "get_state"])
            let (m, s) = try await (messages, st)
            guard seq == snapshotSeq else { return }
            let state = ChatState(s)
            self.state = state
            followSessionFile(state)
            transcript.load(messages: m["messages"]?.array ?? [], isStreaming: state.isStreaming)
            appliedSeq = seq
            if case .failed = status {} else { status = .connected }
        } catch {
            if seq == snapshotSeq { appliedSeq = seq }
            status = .failed(error.localizedDescription)
            return
        }
        await refreshStats()
        if thinkingLevels.isEmpty { await loadThinkingLevels() }
        if models.isEmpty {
            models = ((try? await command(["type": "get_available_models"]))?["models"]?.array ?? [])
                .compactMap(ModelInfo.init)
                .sorted { ($0.provider, $0.label) < ($1.provider, $1.label) }
            enabledPatterns = (try? await client.enabledModels()) ?? []
        }
    }

    /// Keep `path` on the file pi writes to. A new chat gets one once its
    /// first message is saved; after a fork or clone pi moved to another
    /// file. A fork from the first message leaves pi on a file it hasn't
    /// written yet (pi saves nothing until there's a message), so the chat
    /// is a new one until its next send.
    private func followSessionFile(_ state: ChatState) {
        guard let f = state.sessionFile, f != path else { return }
        if state.messageCount > 0 { path = f } else if path != nil { path = nil }
    }

    /// Reload after pi moved to another file, and wait until the screen
    /// shows it: the server's pocketpi_session event starts a snapshot too,
    /// which can overtake (and so drop) this one.
    private func reloadAfterSwitch() async {
        await loadSnapshot()
        let end = Date().addingTimeInterval(5)
        while appliedSeq < snapshotSeq, Date() < end {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func loadThinkingLevels() async {
        thinkingLevels = ((try? await command(["type": "get_available_thinking_levels"]))?["levels"]?.array ?? [])
            .compactMap(\.string)
    }

    /// Restart this chat's pi so it picks up changed settings. The server
    /// keeps the key, so this session reconnects on its own.
    public func restart() async {
        guard let key else { return }
        do { try await client.restart(key: key) } catch { problem = error.reportable }
    }

    /// Switch this chat's model. pi keeps the choice in the session; the
    /// thinking levels and the context numbers change with it.
    public func setModel(_ m: ModelInfo) async {
        do {
            try await command(["type": "set_model", "provider": .string(m.provider), "modelId": .string(m.id)])
            commands = nil
            if let s = try? await command(["type": "get_state"]) { state = ChatState(s) }
            await loadThinkingLevels()
            await refreshStats()
        } catch { problem = error.reportable }
    }

    /// Fetch the runs pi started here that haven't ended. True while any
    /// is still going (the screen keeps polling until then).
    @discardableResult
    public func refreshRuns() async -> Bool {
        var active: [RunInfo] = []
        for id in transcript.startedRuns where !endedRuns.contains(id) {
            guard let r = try? await client.run(id: id) else {
                // Keep showing what we had if the server didn't answer.
                if let old = activeRuns.first(where: { $0.id == id }) { active.append(old) }
                continue
            }
            if r.isActive { active.append(r) } else { endedRuns.insert(id) }
        }
        if active != activeRuns { activeRuns = active }
        return !active.isEmpty
    }

    /// What to offer under the composer while it holds a lone `/word`.
    public var slashMatches: [SlashCommand] { SlashCommand.matches(commands ?? [], for: composer) }

    /// Fetch pi's slash commands once the composer starts with `/` (a new
    /// chat's pi is started for it, as for the model picker).
    public func composerChanged() async {
        guard commands == nil, !loadingCommands, composer.hasPrefix("/"),
              !composer.contains(where: \.isWhitespace) else { return }
        loadingCommands = true
        defer { loadingCommands = false }
        do {
            try await ensureStarted()
            commands = try await command(["type": "get_commands"])["commands"]?.array?.compactMap(SlashCommand.init) ?? []
        } catch {
            commands = nil // try again on the next keystroke
        }
    }

    /// Put a picked command in the composer, ready for its arguments.
    public func pick(_ c: SlashCommand) { composer = "/\(c.name) " }

    public func refreshLlama() async {
        llama = try? await client.llama()
    }

    /// Switch to a model on the llama.cpp router. An unloaded one is loaded
    /// first (the server unloads the router's others); pi only lists router
    /// models that were loaded when it started, so this chat's pi restarts
    /// to see it. Then it's picked like any other model.
    public func useLocal(_ m: LlamaModel) async {
        loadingLocal = m.id
        defer { loadingLocal = nil }
        do {
            if !m.isLoaded {
                try await client.loadLlama(model: m.id)
                await refreshLlama()
            }
            var found = models.first { $0.key == m.key }
            if found == nil {
                try await restartPi()
                // pi asks the router as it starts; give it a moment.
                for _ in 0..<20 {
                    let list = ((try? await command(["type": "get_available_models"]))?["models"]?.array ?? []).compactMap(ModelInfo.init)
                    if let hit = list.first(where: { $0.key == m.key }) {
                        models = list.sorted { ($0.provider, $0.label) < ($1.provider, $1.label) }
                        found = hit
                        break
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            guard let found else {
                problem = "pi doesn't list \(m.id) yet. Try again in a moment."
                return
            }
            await setModel(found)
        } catch {
            if let e = error.reportable { problem = "Couldn't load \(m.id): " + e }
        }
    }

    /// Start this chat's pi again (it keeps the conversation): pi reads
    /// what's available as it starts.
    func restartPi() async throws {
        streamTask?.cancel()
        streamTask = nil
        if let key {
            self.key = nil
            try? await client.close(key: key)
        }
        if path != nil {
            try await reopen()
        } else {
            try await ensureStarted()
        }
        if let s = try? await command(["type": "get_state"]) { state = ChatState(s) }
    }

    public func refreshStats() async {
        if let s = try? await command(["type": "get_session_stats"]) { stats = SessionStats(s) }
    }

    private func afterTurn() async {
        await refreshStats()
        if path == nil, let s = try? await command(["type": "get_state"]) {
            let st = ChatState(s)
            state = st
            if let f = st.sessionFile { path = f }
        }
        onTurnFinished?()
    }

    // MARK: - commands

    /// A pi RPC command, reopening the session once if its process is gone.
    @discardableResult
    public func command(_ c: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        if key == nil, path != nil { try await reopen() }
        guard let key else { throw PocketPiError.unexpected("no session") }
        do {
            return try await client.command(key: key, c, timeout: timeout)
        } catch let e as PocketPiError where e.isSessionGone && path != nil {
            self.key = nil
            try await reopen()
            guard let k = self.key else { throw e }
            return try await client.command(key: k, c, timeout: timeout)
        }
    }

    /// What sending the composer's text would do (`!cmd` runs a command).
    public var composerIntent: ComposerIntent { ComposerIntent(composer) }

    /// The line under the composer: what a `!`/`!!` command will do, or
    /// why it can't run yet.
    public var composerHint: String? {
        if transcript.bashRunning { return "A shell command is running" }
        return composerIntent.hint(streaming: isStreaming)
    }

    /// Whether the composer's text can go now: a shell command waits for
    /// pi to finish, and only one runs at a time.
    public var canSendComposer: Bool {
        if transcript.bashRunning { return false }
        return !(composerIntent.isBash && isStreaming)
    }

    /// Send what's in the composer (or `text`). While pi works, the message
    /// steers it (the default) or waits for the whole turn to end
    /// (`.followUp`). `!cmd` and `!!cmd` run a shell command instead.
    public func send(_ text: String, images: [ImageAttachment] = [], delivery: Delivery = .steer) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        if images.isEmpty, case .bash(let command, let excluded) = ComposerIntent(text) {
            try await runBash(command, excludeFromContext: excluded)
            return
        }
        sentAny = true
        try await ensureStarted()
        let queue = transcript.isStreaming && delivery == .followUp
        var c: [String: JSONValue] = ["type": queue ? "follow_up" : "prompt", "message": .string(text)]
        if !images.isEmpty {
            c["images"] = .array(images.map {
                ["type": "image", "data": .string($0.base64), "mimeType": .string($0.mimeType)]
            })
        }
        if transcript.isStreaming, !queue { c["streamingBehavior"] = "steer" }
        let r = try await command(.object(c))
        // Slash commands pi handled itself don't stream; show what they did.
        if r["disposition"]?.string == "handled" {
            await loadSnapshot()
        }
    }

    /// Run a shell command through pi (`bash`), streaming its output into a
    /// card. pi adds the result to the session; unless `excludeFromContext`,
    /// the model sees it with the next prompt. Only while pi is idle.
    public func runBash(_ command: String, excludeFromContext: Bool = false) async throws {
        if isStreaming { throw PocketPiError.unexpected("Shell commands run once pi has finished.") }
        if transcript.bashRunning { throw PocketPiError.unexpected("A shell command is already running.") }
        sentAny = true
        try await ensureStarted()
        transcript.beginBash(command: command, excludeFromContext: excludeFromContext)
        do {
            let r = try await self.command(
                ["type": "bash", "command": .string(command), "excludeFromContext": .bool(excludeFromContext)],
                timeout: 905)
            transcript.finishBash(r)
        } catch {
            transcript.failBash(error.reportable ?? "Cancelled")
        }
        onTurnFinished?()
    }

    /// Stop the running shell command; its card ends "cancelled".
    public func abortBash() async {
        do { try await command(["type": "abort_bash"]) } catch { problem = error.reportable }
    }

    /// Stop pi's automatic retry after a model error (abort_retry).
    public func stopRetrying() async {
        do { try await command(["type": "abort_retry"]) } catch { problem = error.reportable }
    }

    /// Stop pi. Messages still queued come back into the composer.
    public func stop() async {
        do {
            let q = try await command(["type": "clear_queue"])
            let back = ((q["steering"]?.array ?? []) + (q["followUp"]?.array ?? [])).compactMap(\.string)
            if !back.isEmpty, composer.trimmingCharacters(in: .whitespaces).isEmpty {
                composer = back.joined(separator: "\n")
            }
            try await command(["type": "abort"])
        } catch {
            problem = error.reportable
        }
    }

    public enum Answer: Sendable {
        case confirmed(Bool)
        case value(String)
        case cancelled
    }

    /// Show an extension's dialog. One with a timeout goes away by itself
    /// when it runs out, unanswered: pi answers it then.
    func show(_ r: ExtensionRequest) {
        pendingRequest = r
        guard let left = r.remaining() else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(left))
            self?.expire(r)
        }
    }

    /// The dialog's time ran out: drop it without answering.
    public func expire(_ request: ExtensionRequest) {
        if pendingRequest?.id == request.id { pendingRequest = nil }
    }

    /// The extension's title (setTitle) when it set one, else `fallback`
    /// (the project's name).
    public func subtitle(fallback: String) -> String {
        transcript.extensionUI.title ?? fallback
    }

    public func respond(to request: ExtensionRequest, _ answer: Answer) async {
        if pendingRequest?.id == request.id { pendingRequest = nil }
        var c: [String: JSONValue] = ["type": "extension_ui_response", "id": .string(request.id)]
        switch answer {
        case .confirmed(let b): c["confirmed"] = .bool(b)
        case .value(let v): c["value"] = .string(v)
        case .cancelled: c["cancelled"] = true
        }
        do { try await command(.object(c)) } catch { problem = error.reportable }
    }

    public func setThinkingLevel(_ level: String) async {
        do {
            try await command(["type": "set_thinking_level", "level": .string(level)])
            state?.thinkingLevel = level
        } catch { problem = error.reportable }
    }

    public func rename(_ name: String) async {
        do {
            try await command(["type": "set_session_name", "name": .string(name)])
            state?.sessionName = name
        } catch { problem = error.reportable }
    }

    public func compact() async {
        do { try await command(["type": "compact"]) } catch { problem = error.reportable }
    }

    // MARK: - fork and clone

    /// Start over from an earlier message of yours: pi carries on in a new
    /// session file holding the history before it (the original chat stays as
    /// it was), and the message comes back into the composer to edit and
    /// send again. False if nothing happened (pi working, no match, an
    /// extension said no); `problem` says why.
    @discardableResult
    public func fork(at item: Transcript.Item) async -> Bool {
        guard !isStreaming else { problem = "Wait for pi to finish first."; return false }
        guard let n = transcript.userMessages.firstIndex(where: { $0.id == item.id }) else { return false }
        do {
            let shown = transcript.userMessages.map { ForkMap.text(of: $0.message) }
            let points = (try await command(["type": "get_fork_messages"])["messages"]?.array ?? []).compactMap(ForkPoint.init)
            guard let entryId = ForkMap.entryIds(for: shown, in: points)[n] else {
                problem = "pi can't fork from this message."
                return false
            }
            let r = try await command(["type": "fork", "entryId": .string(entryId)])
            if r["cancelled"]?.bool == true {
                problem = "An extension cancelled the fork."
                return false
            }
            await reloadAfterSwitch()
            composer = r["text"]?.string ?? shown[n]
            composerFocusRequests += 1
            onTurnFinished?()
            return true
        } catch {
            problem = error.reportable
            return false
        }
    }

    /// Copy this chat into a new one (pi's `clone`) and carry on there; the
    /// original stays as it was.
    @discardableResult
    public func clone() async -> Bool {
        guard !isStreaming else { problem = "Wait for pi to finish first."; return false }
        do {
            let r = try await command(["type": "clone"])
            if r["cancelled"]?.bool == true {
                problem = "An extension cancelled the copy."
                return false
            }
            await reloadAfterSwitch()
            onTurnFinished?()
            return true
        } catch {
            problem = error.reportable
            return false
        }
    }
}
