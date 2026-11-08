import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Getting a chat out: pi's HTML export (`POST /api/s/{key}/export`, then
// `GET /api/exports/{name}`) and the session's JSONL
// (`GET /api/sessions/file?path=`). Both come down to a local file the app
// hands to a share sheet or Quick Look. Compact with instructions lives here
// too (pi's `compact{customInstructions}`).

/// An export pi wrote on the server.
public struct ExportedPage: Sendable, Equatable {
    /// The file's name in the server's exports folder.
    public var name: String
    /// Its path on the server, `/api/exports/<name>`.
    public var url: String

    init?(_ v: JSONValue) {
        guard let name = v["name"]?.string, let url = v["url"]?.string else { return nil }
        self.name = name
        self.url = url
    }
}

/// What pi's compaction did.
public struct CompactionResult: Sendable, Equatable {
    public var summary: String
    public var tokensBefore: Int?
    public var tokensAfter: Int?

    public init(_ v: JSONValue) {
        summary = v["summary"]?.string ?? ""
        tokensBefore = v["tokensBefore"]?.int
        tokensAfter = v["estimatedTokensAfter"]?.int
    }
}

public enum ExportName {
    /// A file name people can read, from the chat's title: letters, digits,
    /// `-` and `_`, words joined by `-`, at most 60 characters; `fallback`
    /// when nothing is left. Same rule as the server's download names.
    public static func file(title: String?, fallback: String = "pi-session", ext: String) -> String {
        let cleaned = String((title ?? "").map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : " " })
        let stem = String(cleaned.split(whereSeparator: \.isWhitespace).joined(separator: "-").prefix(60))
        return (stem.isEmpty ? fallback : stem) + "." + ext
    }

    /// The custom instructions to send with a compaction: trimmed, nil when empty.
    public static func instructions(_ text: String?) -> String? {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension PocketPiClient {
    /// Ask the chat's pi for an HTML export; the server picks where it goes.
    public func exportHTML(key: String) async throws -> ExportedPage {
        var r = try request("/api/s/\(key)/export", body: [:])
        r.timeoutInterval = 120
        let v = try JSONDecoder().decode(JSONValue.self, from: try await send(r))
        guard let page = ExportedPage(v) else { throw PocketPiError.unexpected("no export in the answer") }
        return page
    }

    /// The server path the session file `path` downloads from.
    public static func sessionFilePath(_ path: String) -> String {
        var c = URLComponents()
        c.path = "/api/sessions/file"
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        // "+" would read as a space in a query.
        return (c.string ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    /// Fetch a server path into a temporary file named `fileName`, for a
    /// share sheet or Quick Look. Replaces an earlier file of that name.
    public func download(_ path: String, as fileName: String) async throws -> URL {
        var r = try request(path)
        r.timeoutInterval = 120
        let data = try await send(r)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pocketpi-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: file)
        try data.write(to: file)
        return file
    }

    /// The usage dashboard's numbers (`GET /api/usage`) for the last `days`
    /// days, cut into days in `timeZone`.
    public func usage(days: Int, timeZone: TimeZone = .current, now: Date = Date()) async throws -> UsageReport {
        let tz = timeZone.secondsFromGMT(for: now) / 60
        return UsageReport(try await get("/api/usage?days=\(days)&tz=\(tz)", as: JSONValue.self))
    }
}

extension ChatSession {
    /// Runs `body` with the chat's live key, reopening its pi once if it's gone.
    private func withKey<T>(_ body: (String) async throws -> T) async throws -> T {
        if key == nil, path != nil { try await reopen() }
        guard let k = key else { throw PocketPiError.unexpected("This chat has nothing to export yet.") }
        do {
            return try await body(k)
        } catch let e as PocketPiError where e.isSessionGone && path != nil {
            try await reopen()
            guard let k = key else { throw e }
            return try await body(k)
        }
    }

    /// The chat as pi's HTML page, in a local file named after the chat;
    /// nil (and `problem` says why) if it failed.
    public func exportHTML() async -> URL? {
        do {
            let page = try await withKey { try await client.exportHTML(key: $0) }
            return try await client.download(page.url, as: ExportName.file(title: title, ext: "html"))
        } catch {
            problem = error.reportable.map { "Couldn't export: " + $0 }
            return nil
        }
    }

    /// The chat's session file (pi's JSONL), in a local file.
    public func exportJSONL() async -> URL? {
        guard let path else {
            problem = "This chat isn't saved yet."
            return nil
        }
        do {
            return try await client.download(PocketPiClient.sessionFilePath(path), as: ExportName.file(title: title, ext: "jsonl"))
        } catch {
            problem = error.reportable.map { "Couldn't download: " + $0 }
            return nil
        }
    }

    /// Summarize older messages to free up context, optionally saying what
    /// the summary should focus on. Nil (and `problem` says why) on failure.
    @discardableResult
    public func compact(instructions: String?) async -> CompactionResult? {
        var cmd: [String: JSONValue] = ["type": "compact"]
        if let i = ExportName.instructions(instructions) { cmd["customInstructions"] = .string(i) }
        do {
            let r = CompactionResult(try await command(.object(cmd), timeout: 600))
            await refreshStats()
            return r
        } catch {
            problem = error.reportable
            return nil
        }
    }
}
