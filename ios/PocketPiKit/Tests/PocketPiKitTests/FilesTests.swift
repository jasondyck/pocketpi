import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// The files panel: decoding, request paths, previews and `@` mentions.
struct FilesTests {
    @Test func decodesAListing() throws {
        let json = #"{"root":"/p","dir":"src","entries":[{"name":"lib","kind":"dir","size":0,"mtime":1},{"name":"a.rs","kind":"file","size":12,"mtime":1794000000000},{"name":"in","kind":"link","size":0,"mtime":2,"target":"dir"},{"name":"out","kind":"link","size":0,"mtime":2},{"name":"fifo","kind":"socket","size":0,"mtime":3}],"truncated":true}"#
        let l = try JSONDecoder().decode(FileListing.self, from: Data(json.utf8))
        #expect(l.dir == "src" && l.truncated)
        #expect(l.entries.map(\.kind) == [.dir, .file, .link, .link, .other])
        #expect(l.entries.map(\.isDirectory) == [true, false, true, false, false])
        #expect(l.entries.map(\.canPreview) == [false, true, false, false, false])
        #expect(l.entries[1].size == 12 && l.entries[1].mtime == 1_794_000_000_000)
        #expect(l.entries[3].target == nil)
    }

    @Test func decodesAPageAndChanges() throws {
        let page = try JSONDecoder().decode(FilePage.self, from: Data(#"{"path":"a","from":5001,"lines":["x",""],"next":null,"size":9,"mtime":3,"version":"3-9"}"#.utf8))
        #expect(page == FilePage(from: 5001, lines: ["x", ""], next: nil, size: 9, mtime: 3, version: "3-9"))
        let json = #"{"git":true,"cwd":"/p","turns":[{"turn":1,"start":10,"end":20,"files":[],"error":null},{"turn":2,"start":30,"end":40,"files":[{"path":"src/a.rs","added":3,"removed":1},{"path":"img.png","added":null,"removed":null},{"path":"new.rs","added":2,"removed":0,"from":"old.rs"}],"error":null},{"turn":3,"files":[],"error":"git add failed"}]}"#
        let c = try JSONDecoder().decode(ChatChanges.self, from: Data(json.utf8))
        #expect(c.git == true)
        #expect(c.turns.count == 3)
        #expect(c.turns[1].files[0] == ChangedFile(path: "src/a.rs", added: 3, removed: 1))
        #expect(c.turns[1].files[1].added == nil)
        #expect(c.turns[1].files[2].from == "old.rs")
        // Newest first, and only turns with something to show.
        #expect(c.changedTurns.map(\.turn) == [3, 2])
        let plain = try JSONDecoder().decode(ChatChanges.self, from: Data(#"{"git":null,"turns":[]}"#.utf8))
        #expect(plain.git == nil && plain.changedTurns.isEmpty)
    }

    @Test func paths() {
        #expect(PocketPiClient.filesPath("list", [("root", "/home/x/a+b"), ("dir", "src dir")]) == "/api/files/list?root=/home/x/a%2Bb&dir=src%20dir")
        #expect(PocketPiClient.rawFilePath(root: "/p", path: "a.png") == "/api/files/raw?root=/p&path=a.png")
        #expect(PocketPiClient.rawFilePath(root: "/p", path: "a.png", download: true) == "/api/files/raw?root=/p&path=a.png&download=1")
        // A session file wins over the key.
        #expect(PocketPiClient.changesPath(key: "k1", path: "/s/a.jsonl") == "/api/files/changes?path=/s/a.jsonl")
        #expect(PocketPiClient.changesPath(key: "k1", path: nil, turn: .turn(3), file: "src/a.rs") == "/api/files/changes?key=k1&turn=3&file=src/a.rs")
        #expect(PocketPiClient.changesPath(key: nil, path: "/s/a.jsonl", turn: .all) == "/api/files/changes?path=/s/a.jsonl&turn=all")
    }

    @Test func previewKinds() {
        #expect(FilePreviewKind.of("logo.PNG") == .quickLook)
        #expect(FilePreviewKind.of("docs/spec.pdf") == .quickLook)
        #expect(FilePreviewKind.of("README.md") == .markdown)
        #expect(FilePreviewKind.of("main.rs") == .text)
        #expect(FilePreviewKind.of("Makefile") == .text)
    }

    @Test func readProblems() {
        #expect(FileReadProblem(PocketPiError.http(status: 422, message: "not-text")) == .notText)
        #expect(FileReadProblem(PocketPiError.http(status: 413, message: "too-large")) == .tooLarge)
        #expect(FileReadProblem(PocketPiError.http(status: 404, message: "not found")) == nil)
        #expect(FileReadProblem(CancellationError()) == nil)
    }

    @Test func mentionTokens() {
        #expect(AtMention.token(in: "look at @src/ma") == .init(prefix: "@src/ma", query: "src/ma", quoted: false))
        #expect(AtMention.token(in: "@") == .init(prefix: "@", query: "", quoted: false))
        #expect(AtMention.token(in: "mail me@example.com") == nil)
        #expect(AtMention.token(in: "@src/main.rs done") == nil)
        #expect(AtMention.token(in: "see @\"My Doc") == .init(prefix: "@\"My Doc", query: "My Doc", quoted: true))
        #expect(AtMention.token(in: "see @\"My Doc.md\" and @RE") == .init(prefix: "@RE", query: "RE", quoted: false))
        #expect(AtMention.token(in: "see @\"My Doc.md\" ok") == nil)
    }

    @Test func mentionFormatAndApply() {
        #expect(AtMention.format(path: "src/main.rs", isDirectory: false) == "@src/main.rs")
        #expect(AtMention.format(path: "src", isDirectory: true) == "@src/")
        #expect(AtMention.format(path: "My Docs/a b.md", isDirectory: false) == "@\"My Docs/a b.md\"")
        #expect(AtMention.format(path: "My Docs", isDirectory: true) == "@\"My Docs/")
        #expect(AtMention.format(path: "x", isDirectory: false, keepQuote: true) == "@\"x\"")
        #expect(AtMention.format(path: "bad\"name", isDirectory: false) == nil)

        #expect(AtMention.apply(FileCandidate(path: "src/main.rs"), to: "fix @mai") == "fix @src/main.rs ")
        #expect(AtMention.apply(FileCandidate(path: "src", kind: "dir"), to: "@s") == "@src/")
        #expect(AtMention.apply(FileCandidate(path: "My Doc.md"), to: "read @\"My") == "read @\"My Doc.md\" ")
        #expect(AtMention.apply(FileCandidate(path: "x"), to: "no mention") == nil)
        let c = FileCandidate(path: "web/app/files.js")
        #expect(c.name == "files.js" && c.folder == "web/app/" && !c.isDirectory)
        #expect(FileCandidate(path: "top").folder == "")
    }
}

/// The files panel against a scratch pocketpi with ios/fake-pi.py as pi
/// (ios/test-linux.sh). Skipped without POCKETPI_TEST_URL.
private let filesEnv = ProcessInfo.processInfo.environment
private let filesServer = filesEnv["POCKETPI_TEST_URL"]
private let filesCwd = filesEnv["POCKETPI_TEST_CWD"] ?? ""

@Suite(.serialized, .enabled(if: filesServer != nil))
@MainActor
struct FilesIntegrationTests {
    let client = PocketPiClient(server: ServerAddress(url: URL(string: filesServer ?? "http://127.0.0.1:1")!))

    private func waitFor(_ what: String, _ cond: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while await !cond() {
            if Date() > end { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func browsesReadsAndSearchesAChatsFolder() async throws {
        let s = ChatSession(client: client, newIn: filesCwd)
        await s.start()
        await s.prepare() // a live chat in the folder makes it browsable
        let top = try await client.listFiles(root: filesCwd)
        #expect(top.entries.contains { $0.name == ".pi" && $0.isDirectory })
        let prompts = try await client.listFiles(root: filesCwd, dir: ".pi/prompts")
        #expect(prompts.entries.map(\.name).contains("deploy.md"))
        let page = try await client.readFile(root: filesCwd, path: ".pi/prompts/deploy.md")
        #expect(page.from == 1 && page.lines.contains("Deploy.") && page.next == nil)
        let hits = try await client.searchFiles(root: filesCwd, query: ".pi/prompts/dep")
        #expect(hits.first?.path == ".pi/prompts/deploy.md")
        // Nothing outside the folder, and no folder that isn't a project.
        await #expect(throws: PocketPiError.self) { try await client.readFile(root: filesCwd, path: "../.bashrc") }
        await #expect(throws: PocketPiError.self) { try await client.listFiles(root: "/etc") }
        s.leave()
    }

    @Test func recordsTheFilesATurnChanged() async throws {
        let s = ChatSession(client: client, newIn: filesCwd)
        try await s.send("write file for the files panel")
        var changes = ChatChanges(git: nil, turns: [])
        try await waitFor("the turn's changed files") {
            changes = (try? await s.loadChanges()) ?? changes
            return changes.turns.contains { !$0.files.isEmpty }
        }
        // Not a git folder: the path the write tool named, no line counts.
        #expect(changes.git == false)
        let turn = try #require(changes.changedTurns.first)
        #expect(turn.files.map(\.path) == ["notes/pp-written.txt"])
        #expect(turn.files[0].added == nil)
        #expect(try await s.changedFiles(.all).map(\.path) == ["notes/pp-written.txt"])
        // The file it wrote can be read back.
        let page = try await client.readFile(root: filesCwd, path: "notes/pp-written.txt")
        #expect(page.lines.contains("write file for the files panel"))
        s.leave()
    }
}
