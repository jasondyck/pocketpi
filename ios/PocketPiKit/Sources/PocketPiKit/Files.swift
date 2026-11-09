import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The files panel (docs/dsh-features-plan.md §3.5): a chat's folder from the
// server's `/api/files/list|read|raw|search`, the files each turn changed
// from `/api/files/changes`, and `@` mentions for the composer. Same feature
// as web/files.js.

/// One entry of a folder listing.
public struct FileEntry: Sendable, Equatable, Identifiable, Decodable {
    public enum Kind: String, Sendable, Equatable {
        case dir, file, link, other
    }

    public var name: String
    public var kind: Kind
    public var size: Int64
    /// Last change, in milliseconds since 1970.
    public var mtime: Int64
    /// What a link points at when that is inside the folder (nil when it
    /// leaves the folder or dangles; links are listed, never followed out).
    public var target: Kind?

    public var id: String { name }
    /// A folder, or a link to one inside the root.
    public var isDirectory: Bool { kind == .dir || target == .dir }
    /// Something a preview can show: the server never reads a file through
    /// a final symlink.
    public var canPreview: Bool { kind == .file }

    public init(name: String, kind: Kind, size: Int64 = 0, mtime: Int64 = 0, target: Kind? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.target = target
    }

    enum CodingKeys: String, CodingKey { case name, kind, size, mtime, target }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = Kind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .other
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        mtime = try c.decodeIfPresent(Int64.self, forKey: .mtime) ?? 0
        target = try c.decodeIfPresent(String.self, forKey: .target).flatMap(Kind.init(rawValue:))
    }
}

/// A folder: folders first, then a natural sort, dotfiles included; at most
/// 2000 entries (`truncated` says more were left out).
public struct FileListing: Sendable, Equatable, Decodable {
    /// The folder, relative to the root ("" for the root).
    public var dir: String
    public var entries: [FileEntry]
    public var truncated: Bool

    public init(dir: String, entries: [FileEntry], truncated: Bool = false) {
        self.dir = dir
        self.entries = entries
        self.truncated = truncated
    }
}

/// A page of a text file.
public struct FilePage: Sendable, Equatable, Decodable {
    /// The first line's number (1-based).
    public var from: Int
    public var lines: [String]
    /// The next page's first line; nil at the end of the file.
    public var next: Int?
    public var size: Int64
    public var mtime: Int64
    /// Changes when the file does (its mtime and size).
    public var version: String

    public init(from: Int, lines: [String], next: Int? = nil, size: Int64 = 0, mtime: Int64 = 0, version: String = "") {
        self.from = from
        self.lines = lines
        self.next = next
        self.size = size
        self.mtime = mtime
        self.version = version
    }
}

/// Why a file has no text preview (the server's 422 and 413).
public enum FileReadProblem: Error, Equatable, Sendable {
    /// NUL bytes or invalid UTF-8.
    case notText
    /// Over the server's cap (64 MiB, or a line over 2 MiB).
    case tooLarge

    /// The problem an error from `readFile` stands for, if it is one.
    public init?(_ error: Error) {
        guard case PocketPiError.http(let status, let message)? = error as? PocketPiError else { return nil }
        switch (status, message.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case (422, _), (_, "not-text"): self = .notText
        case (413, _), (_, "too-large"): self = .tooLarge
        default: return nil
        }
    }
}

/// How a file is previewed.
public enum FilePreviewKind: Sendable, Equatable {
    /// Images and PDFs: the raw bytes, in Quick Look.
    case quickLook
    case markdown
    /// Text and code, with line numbers; a file that turns out not to be
    /// text is offered as a download instead.
    case text

    public static func of(_ name: String) -> FilePreviewKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico", "svg", "heic", "pdf"].contains(ext) { return .quickLook }
        if ["md", "markdown", "mdx"].contains(ext) { return .markdown }
        return .text
    }
}

/// A search answer for an `@` mention.
public struct FileCandidate: Sendable, Equatable, Identifiable, Decodable {
    /// Relative to the root.
    public var path: String
    /// "file" or "dir".
    public var kind: String

    public var id: String { kind + ":" + path }
    public var isDirectory: Bool { kind == "dir" }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// The folder it is in, with a trailing slash ("" at the root).
    public var folder: String { String(path.dropLast(name.count)) }

    public init(path: String, kind: String = "file") {
        self.path = path
        self.kind = kind
    }
}

/// A file a turn changed.
public struct ChangedFile: Sendable, Equatable, Identifiable, Decodable {
    /// Relative to the chat's folder (`../` for files above it).
    public var path: String
    /// Lines added and removed; nil for a binary file, and outside git.
    public var added: Int?
    public var removed: Int?
    /// A rename's old path.
    public var from: String?

    public var id: String { path }

    public init(path: String, added: Int? = nil, removed: Int? = nil, from: String? = nil) {
        self.path = path
        self.added = added
        self.removed = removed
        self.from = from
    }
}

/// One turn (prompt to settled) and the files it changed.
public struct TurnChanges: Sendable, Equatable, Identifiable, Decodable {
    public var turn: Int
    /// Milliseconds since 1970.
    public var start: Double?
    public var end: Double?
    public var files: [ChangedFile]
    /// Why the snapshot failed, when it did.
    public var error: String?

    public var id: Int { turn }

    public init(turn: Int, start: Double? = nil, end: Double? = nil, files: [ChangedFile], error: String? = nil) {
        self.turn = turn
        self.start = start
        self.end = end
        self.files = files
        self.error = error
    }
}

/// A chat's turns, oldest first. `git` is false outside a git repository
/// (the files are then the paths pi's edit and write tools named, with no
/// line counts or diffs), nil before the first turn.
public struct ChatChanges: Sendable, Equatable, Decodable {
    public var git: Bool?
    public var turns: [TurnChanges]

    public init(git: Bool?, turns: [TurnChanges]) {
        self.git = git
        self.turns = turns
    }

    /// The turns that changed something (or failed to tell), newest first.
    public var changedTurns: [TurnChanges] { turns.filter { !$0.files.isEmpty || $0.error != nil }.reversed() }
}

/// Which changes to ask for: one turn, or everything since the chat opened.
public enum TurnSelector: Sendable, Equatable, Hashable {
    case turn(Int)
    case all

    var query: String {
        switch self {
        case .turn(let n): String(n)
        case .all: "all"
        }
    }
}

/// `@` mentions in the composer, with dsh's grammar: `@path`, or
/// `@"path with spaces"`, never inside another word (an email address isn't
/// one). Only a path goes in; the model reads the file itself.
public enum AtMention {
    public struct Token: Sendable, Equatable {
        /// The token as typed, with its `@` (and opening quote).
        public var prefix: String
        /// What follows the `@`: the search query.
        public var query: String
        public var quoted: Bool
    }

    /// The mention being typed at the end of `text`, if any.
    public static func token(in text: String) -> Token? {
        // `@"…` with no closing quote yet.
        if let q = text.range(of: "@\"", options: .backwards) {
            let rest = text[q.upperBound...]
            if !rest.contains("\""), q.lowerBound == text.startIndex || text[text.index(before: q.lowerBound)].isWhitespace {
                return Token(prefix: String(text[q.lowerBound...]), query: String(rest), quoted: true)
            }
        }
        guard let at = text.lastIndex(of: "@") else { return nil }
        let rest = text[text.index(after: at)...]
        guard !rest.contains(where: \.isWhitespace) else { return nil }
        guard at == text.startIndex || text[text.index(before: at)].isWhitespace else { return nil }
        return Token(prefix: String(text[at...]), query: String(rest), quoted: false)
    }

    /// The text that mentions `path`: quoted when it has whitespace (or the
    /// quote was opened), a folder with a trailing slash (and an open quote,
    /// so picking can go on inside it). Nil for a path with quotes or
    /// control characters, which the grammar can't hold.
    public static func format(path: String, isDirectory: Bool, keepQuote: Bool = false) -> String? {
        let p = isDirectory ? path + "/" : path
        if p.unicodeScalars.contains(where: { $0 == "\"" || $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) { return nil }
        if !(keepQuote || p.contains(where: \.isWhitespace)) { return "@" + p }
        return isDirectory ? "@\"" + p : "@\"" + p + "\""
    }

    /// `text` with the mention being typed at its end replaced by `c`
    /// (followed by a space for a file, so typing goes on), or nil when
    /// there is no mention there.
    public static func apply(_ c: FileCandidate, to text: String) -> String? {
        guard let t = token(in: text), let m = format(path: c.path, isDirectory: c.isDirectory, keepQuote: t.quoted) else { return nil }
        return String(text.dropLast(t.prefix.count)) + m + (c.isDirectory ? "" : " ")
    }
}

extension PocketPiClient {
    /// A files endpoint's path with its query ("+" escaped: it would read as
    /// a space).
    static func filesPath(_ endpoint: String, _ items: [(String, String?)]) -> String {
        var c = URLComponents()
        c.path = "/api/files/" + endpoint
        c.queryItems = items.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        return (c.string ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    /// The folder `dir` ("" for the root) of `root` (a chat's or a project's folder).
    public func listFiles(root: String, dir: String = "") async throws -> FileListing {
        try await get(Self.filesPath("list", [("root", root), ("dir", dir)]))
    }

    /// A page of a text file from line `from`. A file with no text preview
    /// throws an error `FileReadProblem(_:)` recognizes.
    public func readFile(root: String, path: String, from: Int = 1) async throws -> FilePage {
        try await get(Self.filesPath("read", [("root", root), ("path", path), ("from", String(from))]))
    }

    /// The server path of a file's bytes (images, PDFs, downloads).
    public static func rawFilePath(root: String, path: String, download: Bool = false) -> String {
        filesPath("raw", [("root", root), ("path", path), ("download", download ? "1" : nil)])
    }

    /// Paths for an `@` mention, best first.
    public func searchFiles(root: String, query: String, limit: Int = 20) async throws -> [FileCandidate] {
        struct Answer: Decodable { var results: [FileCandidate] }
        return try await get(Self.filesPath("search", [("root", root), ("q", query), ("limit", String(limit))]), as: Answer.self).results
    }

    static func changesPath(key: String?, path: String?, turn: TurnSelector? = nil, file: String? = nil) -> String {
        filesPath("changes", [("path", path), ("key", path == nil ? key : nil), ("turn", turn?.query), ("file", file)])
    }

    /// A chat's turns and what each changed: by session file, or by live key
    /// for a chat not saved yet.
    public func changes(key: String?, path: String?) async throws -> ChatChanges {
        try await get(Self.changesPath(key: key, path: path))
    }

    /// The files changed in one turn or since the chat opened.
    public func changedFiles(key: String?, path: String?, turn: TurnSelector) async throws -> [ChangedFile] {
        struct Answer: Decodable { var files: [ChangedFile] }
        return try await get(Self.changesPath(key: key, path: path, turn: turn), as: Answer.self).files
    }

    /// One file's diff (a unified patch) in a turn or since the chat opened.
    public func fileDiff(key: String?, path: String?, turn: TurnSelector, file: String) async throws -> String {
        struct Answer: Decodable { var diff: String }
        return try await get(Self.changesPath(key: key, path: path, turn: turn, file: file), as: Answer.self).diff
    }
}

extension ChatSession {
    /// The `@` mention being typed at the end of the message box.
    public var mentionToken: AtMention.Token? { AtMention.token(in: composer) }

    /// Paths for the mention being typed, in this chat's folder.
    public func mentionCandidates(for query: String) async -> [FileCandidate] {
        (try? await client.searchFiles(root: cwd, query: query)) ?? []
    }

    /// Put a picked path in the message box in place of the mention.
    public func pickMention(_ c: FileCandidate) {
        if let t = AtMention.apply(c, to: composer) { composer = t }
    }

    /// This chat's turns and what each changed.
    public func loadChanges() async throws -> ChatChanges {
        guard path != nil || key != nil else { return ChatChanges(git: nil, turns: []) }
        return try await client.changes(key: key, path: path)
    }

    public func changedFiles(_ turn: TurnSelector) async throws -> [ChangedFile] {
        try await client.changedFiles(key: key, path: path, turn: turn)
    }

    public func fileDiff(_ turn: TurnSelector, file: String) async throws -> String {
        try await client.fileDiff(key: key, path: path, turn: turn, file: file)
    }
}
