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
    /// The session file; nil for a new chat until its first prompt is saved.
    public private(set) var path: String?
    public private(set) var cwd: String
    /// The live pi process's key, while there is one.
    public private(set) var key: String?
    public private(set) var status: Status = .idle
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
        if ev["type"]?.string == "pocketpi_hello" { status = .connected }
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
            case .extensionRequest(let r):
                pendingRequest = r
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
            if path == nil, state.messageCount > 0, let f = state.sessionFile { path = f }
            transcript.load(messages: m["messages"]?.array ?? [], isStreaming: state.isStreaming)
            if case .failed = status {} else { status = .connected }
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        await refreshStats()
        if thinkingLevels.isEmpty {
            thinkingLevels = ((try? await command(["type": "get_available_thinking_levels"]))?["levels"]?.array ?? [])
                .compactMap(\.string)
        }
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
    public func command(_ c: JSONValue) async throws -> JSONValue {
        if key == nil, path != nil { try await reopen() }
        guard let key else { throw PocketPiError.unexpected("no session") }
        do {
            return try await client.command(key: key, c)
        } catch let e as PocketPiError where e.isSessionGone && path != nil {
            self.key = nil
            try await reopen()
            guard let k = self.key else { throw e }
            return try await client.command(key: k, c)
        }
    }

    /// Send what's in the composer (or `text`). While pi works, the message
    /// steers it instead of waiting for the turn to end.
    public func send(_ text: String, images: [ImageAttachment] = []) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        if key == nil, path != nil { try await reopen() }
        if key == nil {
            let r = try await client.newChat(cwd: cwd)
            key = r.key
            cwd = r.cwd
            transcript = Transcript()
            await connect()
        }
        var c: [String: JSONValue] = ["type": "prompt", "message": .string(text)]
        if !images.isEmpty {
            c["images"] = .array(images.map {
                ["type": "image", "data": .string($0.base64), "mimeType": .string($0.mimeType)]
            })
        }
        if transcript.isStreaming { c["streamingBehavior"] = "steer" }
        let r = try await command(.object(c))
        // Slash commands pi handled itself don't stream; show what they did.
        if r["disposition"]?.string == "handled" {
            await loadSnapshot()
        }
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
            problem = error.localizedDescription
        }
    }

    public enum Answer: Sendable {
        case confirmed(Bool)
        case value(String)
        case cancelled
    }

    public func respond(to request: ExtensionRequest, _ answer: Answer) async {
        if pendingRequest?.id == request.id { pendingRequest = nil }
        var c: [String: JSONValue] = ["type": "extension_ui_response", "id": .string(request.id)]
        switch answer {
        case .confirmed(let b): c["confirmed"] = .bool(b)
        case .value(let v): c["value"] = .string(v)
        case .cancelled: c["cancelled"] = true
        }
        do { try await command(.object(c)) } catch { problem = error.localizedDescription }
    }

    public func setThinkingLevel(_ level: String) async {
        do {
            try await command(["type": "set_thinking_level", "level": .string(level)])
            state?.thinkingLevel = level
        } catch { problem = error.localizedDescription }
    }

    public func rename(_ name: String) async {
        do {
            try await command(["type": "set_session_name", "name": .string(name)])
            state?.sessionName = name
        } catch { problem = error.localizedDescription }
    }

    public func compact() async {
        do { try await command(["type": "compact"]) } catch { problem = error.localizedDescription }
    }
}
