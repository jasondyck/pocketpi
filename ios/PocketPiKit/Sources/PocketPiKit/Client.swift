import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Error {
    /// A request cut short on purpose (the screen went away, a newer refresh
    /// replaced it): not something to show anyone.
    public var isCancellation: Bool {
        if self is CancellationError { return true }
        if let u = self as? URLError, u.code == .cancelled { return true }
        return (self as NSError).domain == NSURLErrorDomain && (self as NSError).code == NSURLErrorCancelled
    }

    /// What to tell the person, or nil for a cancellation.
    public var reportable: String? { isCancellation ? nil : localizedDescription }
}

public enum PocketPiError: Error, Equatable, LocalizedError {
    case badAddress(String)
    case http(status: Int, message: String)
    /// pi answered the command with `success: false`.
    case command(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .badAddress(let s): return s
        case .http(let status, let message):
            if status == 403 { return "pocketpi refused the request (403). Is this device on the tailnet and its login allowed?" }
            return message.isEmpty ? "HTTP \(status)" : message
        case .command(let s), .unexpected(let s): return s
        }
    }

    /// The live pi process is gone (reaped, exited, server restarted): reopen
    /// the session file and try again.
    public var isSessionGone: Bool {
        if case .http(let s, _) = self { return s == 404 || s == 410 }
        return false
    }
}

/// Where pocketpi is. It listens on loopback and is reached through
/// `tailscale serve`, so in practice this is https://<machine>.<tailnet>.ts.net[:port].
public struct ServerAddress: Sendable, Equatable, Codable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Accepts what people type: a bare host gets https://, a trailing slash
    /// or path is dropped.
    public init(parsing raw: String) throws {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw PocketPiError.badAddress("Enter the address pocketpi is served at.") }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = c.host, !host.isEmpty
        else { throw PocketPiError.badAddress("That doesn't look like a web address.") }
        c.scheme = scheme
        c.path = ""
        c.query = nil
        c.fragment = nil
        guard let url = c.url else { throw PocketPiError.badAddress("That doesn't look like a web address.") }
        self.url = url
    }

    public var display: String {
        url.absoluteString.replacingOccurrences(of: "https://", with: "")
    }
}

/// pocketpi's HTTP API (the routes in src/main.rs). Auth is the tailnet's:
/// Tailscale Serve adds the caller's login, pocketpi checks it, so the app
/// sends nothing but the `X-Pocketpi: 1` header every POST must carry.
public final class PocketPiClient: Sendable {
    public let server: ServerAddress
    let session: URLSession

    public init(server: ServerAddress, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    func request(_ path: String, body: JSONValue? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: server.url) else {
            throw PocketPiError.unexpected("bad path \(path)")
        }
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("1", forHTTPHeaderField: "X-Pocketpi")
            r.httpBody = try body.encoded()
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PocketPiError.http(status: status, message: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    public func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(request(path)))
    }

    public func post<T: Decodable>(_ path: String, _ body: JSONValue, as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(request(path, body: body)))
    }

    // MARK: - routes

    public func version() async throws -> BuildInfo { try await get("/api/version") }
    public func projects() async throws -> ProjectsResponse { try await get("/api/projects") }
    public func sessions() async throws -> [SessionInfo] { try await get("/api/sessions", as: SessionsResponse.self).sessions }

    /// The models chosen in pi (its settings' `enabledModels`): "provider/id"
    /// or patterns with `*`, in pi's order.
    public func enabledModels() async throws -> [String] {
        try await get("/api/models/enabled", as: JSONValue.self)["enabled"]?.array?.compactMap(\.string) ?? []
    }

    /// Recent workflow runs, newest first (the server keeps the last 50).
    public func runs() async throws -> [RunInfo] {
        try await get("/api/runs", as: JSONValue.self)["runs"]?.array?.compactMap(RunInfo.init) ?? []
    }

    /// One workflow's recent runs, newest first.
    public func runs(workflow: String) async throws -> [RunInfo] {
        let q = workflow.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? workflow
        return try await get("/api/runs?workflow=\(q)", as: JSONValue.self)["runs"]?.array?.compactMap(RunInfo.init) ?? []
    }

    /// One run, with its stages' output.
    public func run(id: String) async throws -> RunInfo {
        guard let r = try await get("/api/runs/\(id)", as: JSONValue.self)["run"].flatMap(RunInfo.init) else {
            throw PocketPiError.unexpected("no run in the answer")
        }
        return r
    }

    /// Every workflow definition, with its last run.
    public func workflows() async throws -> [WorkflowInfo] {
        try await get("/api/workflows", as: JSONValue.self)["workflows"]?.array?.compactMap(WorkflowInfo.init) ?? []
    }

    /// Start a workflow. Without `force`, the server refuses a run that
    /// repeats one that's active or succeeded (same PR commit, issue or
    /// commit) and says which: `.duplicate`.
    public func start(workflow: String, inputs: [String: String], force: Bool = false) async throws -> StartResult {
        let body: JSONValue = [
            "inputs": .object(inputs.mapValues(JSONValue.string)), "trigger": "manual", "force": .bool(force),
        ]
        do {
            let r: JSONValue = try await post("/api/workflows/\(workflow)/run", body)
            guard let id = r["run_id"]?.string else { throw PocketPiError.unexpected("no run id in the answer") }
            return .started(runId: id)
        } catch PocketPiError.http(409, let message) {
            if let v = try? JSONValue.parse(message), v["duplicate"]?.bool == true, let id = v["run_id"]?.string {
                return .duplicate(runId: id, message: v["message"]?.string ?? "This already ran.")
            }
            throw PocketPiError.http(status: 409, message: message)
        }
    }

    /// One workflow with its suggested improvement and earlier versions.
    public func workflow(id: String) async throws -> WorkflowDetail {
        guard let d = WorkflowDetail(try await get("/api/workflows/\(id)", as: JSONValue.self)) else {
            throw PocketPiError.unexpected("no workflow in the answer")
        }
        return d
    }

    /// Self-improvement: "off", "suggest" or "auto".
    public func setImprove(workflow: String, mode: String) async throws {
        _ = try await post("/api/workflows/\(workflow)/improve", ["mode": .string(mode)], as: JSONValue.self)
    }

    /// Ask the reviewer to look at the last finished run now. It answers later
    /// (a notification, and the workflow's proposal or history changes).
    public func improveNow(workflow: String) async throws {
        _ = try await post("/api/workflows/\(workflow)/reflect", [:], as: JSONValue.self)
    }

    public func applyProposal(workflow: String) async throws {
        _ = try await post("/api/workflows/\(workflow)/proposal/apply", [:], as: JSONValue.self)
    }

    public func dismissProposal(workflow: String) async throws {
        _ = try await post("/api/workflows/\(workflow)/proposal/dismiss", [:], as: JSONValue.self)
    }

    /// Go back to the version saved before `version`'s change (the current one
    /// is kept in history).
    public func revert(workflow: String, version: String) async throws {
        _ = try await post("/api/workflows/\(workflow)/revert", ["version": .string(version)], as: JSONValue.self)
    }

    /// Delete the definition. Its runs and their branches are kept.
    public func deleteWorkflow(_ id: String) async throws {
        _ = try await post("/api/workflows/\(id)/delete", [:], as: JSONValue.self)
    }

    /// Stop a running run (its stage's pi or shell is killed).
    public func cancel(run: String) async throws {
        _ = try await post("/api/runs/\(run)/cancel", [:], as: JSONValue.self)
    }

    /// Turn a workflow's sensors (schedule, PR polling, pi starting it) on or off.
    public func setEnabled(workflow: String, _ on: Bool) async throws {
        _ = try await post("/api/workflows/\(workflow)/enable", ["enabled": .bool(on)], as: JSONValue.self)
    }

    /// Answer a run's approval stage. Approving lets the run go on (for a PR
    /// review: post the comment); rejecting stops it there.
    public func answer(run: String, stage: String, approve: Bool, note: String = "") async throws {
        _ = try await post("/api/runs/\(run)/approve",
                           ["stage": .string(stage), "approve": .bool(approve), "note": .string(note)],
                           as: JSONValue.self)
    }

    /// The archived chats (left out of `sessions()`).
    public func archivedSessions() async throws -> [SessionInfo] {
        try await get("/api/sessions?archived=1", as: SessionsResponse.self).sessions
    }

    /// Archive a chat, or bring it back. The session file stays on disk.
    public func archiveSession(path: String, archived: Bool = true) async throws {
        _ = try await post("/api/sessions/archive", ["path": .string(path), "archived": .bool(archived)], as: JSONValue.self)
    }

    /// Pin a project folder, optionally under a new name (empty = folder name).
    public func saveProject(path: String, name: String? = nil) async throws {
        var body: [String: JSONValue] = ["path": .string(path)]
        if let name { body["name"] = .string(name) }
        _ = try await post("/api/projects/save", .object(body), as: JSONValue.self)
    }

    /// Unpin and hide a project; its chats stay on disk.
    public func hideProject(path: String) async throws {
        _ = try await post("/api/projects/hide", ["path": .string(path)], as: JSONValue.self)
    }

    /// Start pi in a folder (absolute, or ~/...). The chat has no session file
    /// until its first prompt.
    public func newChat(cwd: String) async throws -> OpenResponse { try await post("/api/new", ["cwd": .string(cwd)]) }

    /// Open (or join the already-running pi for) a session file.
    public func open(path: String) async throws -> OpenResponse { try await post("/api/open", ["path": .string(path)]) }

    public func close(key: String) async throws {
        _ = try await post("/api/s/\(key)/close", [:], as: JSONValue.self)
    }

    // MARK: - notifications

    /// Which APNs service the device token is for: debug builds get sandbox
    /// tokens, TestFlight and App Store builds production ones.
    public enum PushEnvironment: String, Sendable { case sandbox, production }

    /// Register this phone for the server's notifications (approvals, finished
    /// runs, long replies). Throws 503 when the server has no APNs key.
    public func registerPush(token: String, environment: PushEnvironment, label: String) async throws {
        _ = try await post("/api/apns/register", [
            "token": .string(token), "environment": .string(environment.rawValue), "label": .string(label),
        ], as: JSONValue.self)
    }

    public func unregisterPush(token: String) async throws {
        _ = try await post("/api/apns/unregister", ["token": .string(token)], as: JSONValue.self)
    }

    /// Send a pi RPC command and return its `data`. Throws `.command` when pi
    /// says it failed and `.http` (404/410: `isSessionGone`) when the process
    /// is gone.
    public func command(key: String, _ cmd: JSONValue) async throws -> JSONValue {
        let r: JSONValue = try await post("/api/s/\(key)/cmd", cmd)
        if r["success"]?.bool == false {
            throw PocketPiError.command(r["error"]?.string ?? "\(cmd["type"]?.string ?? "command") failed")
        }
        return r["data"] ?? .null
    }

    /// Rename a chat from the list. Opens (or joins) its pi to set the name,
    /// and closes it again only if it wasn't already running, so a chat that's
    /// open somewhere else keeps going.
    public func renameSession(_ s: SessionInfo, to name: String) async throws {
        let key = try await open(path: s.path).key
        _ = try await command(key: key, ["type": "set_session_name", "name": .string(name)])
        if !s.live { try? await close(key: key) }
    }

    /// The chat's events. The first is always `pocketpi_hello`.
    public func events(key: String) -> AsyncThrowingStream<JSONValue, Error> {
        do {
            var r = try request("/api/s/\(key)/events")
            r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            r.timeoutInterval = 60
            return SSEStream.open(r)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
