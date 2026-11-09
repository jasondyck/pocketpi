import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PocketPiKit

/// Settings › Safety and pending-dialog notifications against fake-pi (its
/// "permission" prompt asks like @gotgenes/pi-permission-system). Part of
/// IntegrationTests (serialized, same scratch server).
private let safetyProjectDir = ProcessInfo.processInfo.environment["POCKETPI_TEST_CWD"] ?? ""

@MainActor
private final class RunsListener {
    var events: [JSONValue] = []
    var task: Task<Void, Never>?

    init(_ client: PocketPiClient) {
        task = Task { [weak self] in
            do {
                for try await ev in client.runEvents() { self?.events.append(ev) }
            } catch {}
        }
    }

    var notices: [DialogNotice] { events.compactMap(DialogNotice.init) }
    func stop() { task?.cancel() }
}

@MainActor
private func waitUntil(_ what: String, timeout: Double = 10, _ cond: () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > end { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(25))
    }
}

/// The first event of a chat's stream: its pocketpi_hello.
private func hello(_ client: PocketPiClient, _ key: String) async throws -> JSONValue {
    for try await ev in client.events(key: key) { return ev }
    throw PocketPiError.unexpected("no hello")
}

extension IntegrationTests {
    @Test func notifiesAboutAPermissionPromptNobodySees() async throws {
        let runs = RunsListener(client)
        defer { runs.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let key = try await client.newChat(cwd: safetyProjectDir).key
        _ = try await client.command(key: key, ["type": "prompt", "message": "hello first"])
        try await Task.sleep(for: .milliseconds(300))
        _ = try await client.command(key: key, ["type": "prompt", "message": "permission please"])

        try await waitUntil("the notification") { runs.notices.contains { $0.key == key } }
        let n = try #require(runs.notices.first { $0.key == key })
        #expect(n.title.hasPrefix("Permission Required · "))
        #expect(n.body == "pi wants to run: rm -rf junk")
        #expect(n.url.hasPrefix("/?s=") && n.url.hasSuffix(".jsonl"))

        // The chat a notification opens shows the question.
        let h = try await hello(client, key)
        let pending = h["dialogs"]?.array ?? []
        #expect(pending.map { $0["id"]?.string } == [n.id])
        var t = Transcript()
        let effects = t.apply(h)
        #expect(effects.contains { if case .extensionRequest(let r) = $0 { return r.id == n.id && r.options.first == "Yes" }; return false })

        _ = try await client.command(key: key, ["type": "extension_ui_response", "id": .string(n.id), "value": "Yes"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await hello(client, key)["dialogs"]?.array?.isEmpty == true)
        #expect(runs.notices.filter { $0.key == key }.count == 1)
        try? await client.close(key: key)
    }

    @Test func waitsBeforeNotifyingAChatSomeoneHasOpen() async throws {
        let runs = RunsListener(client)
        defer { runs.stop() }
        let s = ChatSession(client: client, newIn: safetyProjectDir)
        try await s.send("permission while watching")
        try await waitUntil("the dialog") { s.pendingRequest != nil }
        // Watched: no notification yet (it would come after 20 s).
        try await Task.sleep(for: .seconds(1.5))
        #expect(runs.notices.isEmpty)
        let r = try #require(s.pendingRequest)
        await s.respond(to: r, .value("No"))
        try await waitUntil("the reply") { s.transcript.items.contains { if case .assistant(let m, false) = $0.kind { return m.content.compactMap(\.text).contains { $0.contains("denied") } }; return false } }
        if let k = s.key { try? await client.close(key: k) }
    }

    @Test func safetyPageModel() async throws {
        try await client.saveProject(path: safetyProjectDir)
        let m = SafetyModel(client: client)
        await m.load()
        #expect(m.loaded && m.problem == nil)
        let row = try #require(m.projects.first { $0.path == safetyProjectDir })
        #expect(!row.trusted, "the scratch project isn't in trust.json")
        await m.setMode(.strict, for: row.path)
        await m.load()
        #expect(m.projects.first { $0.path == safetyProjectDir }?.mode == .strict)
        await m.setMode(.standard, for: row.path)
        #expect(m.projects.first { $0.path == safetyProjectDir }?.mode == .standard)
        try await client.saveProject(path: safetyProjectDir, name: "")
    }

    @Test func safetyPoliciesRoundTrip() async throws {
        // Install (fake-pi adds it to settings.json) and the recommended policy.
        let job = try await client.installPermissionSystem()
        #expect(job.status == "ok")
        #expect(Safety.isInstalled(settings: try await client.config(.settings).data))
        var chats = try await client.policy(.chats)
        #expect(chats.exists)
        #expect(chats.path.hasSuffix(".pi/agent/extensions/pi-permission-system/config.json"))
        #expect(chats.rules(for: "bash").first == PolicyRule(pattern: "*", action: .allow))
        #expect(chats.rules(for: "bash").contains(PolicyRule(pattern: "rm *", action: .ask)))
        #expect(chats.promptTimeoutMs == 600000)

        // Edit a list: the order (last match wins) survives the trip.
        var bash = chats.rules(for: "bash")
        bash.append(PolicyRule(pattern: "docker *", action: .ask))
        bash.append(PolicyRule(pattern: "aaa *", action: .deny, reason: "no"))
        chats = try await client.patchPolicy(.chats, Safety.setRules("bash", bash))
        #expect(chats.rules(for: "bash") == bash)
        #expect(try await client.policy(.chats).rules(for: "bash").suffix(2).map(\.pattern) == ["docker *", "aaa *"])
        await #expect(throws: PocketPiError.self) {
            try await client.patchPolicy(.chats, PiConfigPatch(set: ["permission.bash": [["x", "maybe"]]]))
        }

        // Per project: Off / Strict / back to the global policy.
        for mode in [Safety.ProjectMode.off, .strict, .standard] {
            let doc = try await client.patchPolicy(.chats, Safety.patch(for: mode), cwd: safetyProjectDir)
            #expect(Safety.mode(of: doc) == mode)
        }

        // The stage policy is pocketpi's own file.
        let stages = try await client.useRecommendedPolicy(.stages)
        #expect(stages.path.hasSuffix("pocketpi/safety/stage-policy.json"))
        #expect(stages.rules(for: "bash").contains { $0.pattern == "git push *--force*" && $0.action == .deny })
        #expect(!stages.rules(for: "bash").contains { $0.pattern == "git push *" })
        let info = try await client.safetyInfo()
        #expect(info["stage_policy_active"]?.bool == true)
        #expect(info["package"]?.string == Safety.package)
    }

    @Test func autoReviewRoundTrip() async throws {
        // Install (fake-pi adds it to settings.json), which also turns it on
        // and writes the recommended config.
        let job = try await client.installAutoReview()
        #expect(job.status == "ok")
        #expect(AutoReview.isInstalled(settings: try await client.config(.settings).data))
        let info = try await client.safetyInfo()
        #expect(info["auto_review"]?["package"]?.string == AutoReview.package)
        #expect(info["auto_review"]?["link"]?.string == AutoReview.link)
        var chats = try await client.policy(.chats)
        #expect(AutoReview.isOn(chats))
        #expect(chats.rules(for: "path_write").contains { $0.pattern == "~/.pi/agent/settings.json" && $0.action == .deny })
        var cfg = AutoReviewConfig(try await client.config(.autoReview))
        #expect(cfg.exists)
        #expect(cfg.preset == .claudeCode)
        #expect(cfg.modelKey == "opencode-go/claude-haiku-5-5")
        #expect(cfg.followUpReviews == "off")
        #expect(!cfg.claudeViaOpenCodeGo)

        // The settings rows' patches; a config write bumps the epoch.
        let before = try await client.piStatus().configEpoch
        cfg = AutoReviewConfig(try await client.patchConfig(.autoReview, AutoReviewConfig.followUpPatch("")))
        #expect(cfg.followUpReviews == nil && cfg.claudeViaOpenCodeGo)
        cfg = AutoReviewConfig(try await client.patchConfig(.autoReview, AutoReviewConfig.modelPatch("")))
        #expect(cfg.modelKey == nil && !cfg.claudeViaOpenCodeGo)
        cfg = AutoReviewConfig(try await client.patchConfig(.autoReview, AutoReviewConfig.reasoningPatch("medium")))
        #expect(cfg.reasoning == "medium")
        cfg = AutoReviewConfig(try await client.patchConfig(.autoReview, AutoReviewConfig.presetPatch(.codex)))
        #expect(cfg.preset == .codex && cfg.reasoning == "medium")
        #expect(try await client.piStatus().configEpoch > before)

        // The review log test-linux.sh seeded, newest first.
        let reviews = try await client.autoReviews()
        #expect(reviews.map(\.id) == ["r2", "r1"])
        #expect(reviews.first?.outcomeLabel == "Asked you · you denied")
        #expect(reviews.first?.detail().hasPrefix("provider-error · ") == true)
        #expect(reviews.last?.outcomeLabel == "Allowed")
        #expect(reviews.last?.subject == "rm -rf build")
        #expect(reviews.last?.detail().hasPrefix("4.0 s · claude-haiku-5-5 · ") == true)
        #expect(reviews.last?.detail().hasSuffix(" min ago") == true)

        // Off takes only the link out: the config stays, and on again keeps it.
        let m = SafetyModel(client: client)
        await m.load()
        #expect(m.autoReviewInstalled && m.autoReviewOn && m.reviews.count == 2)
        #expect(await m.setAutoReview(false))
        #expect(!m.autoReviewOn && m.problem == nil)
        chats = try await client.policy(.chats)
        #expect(!AutoReview.isOn(chats))
        #expect(await m.setAutoReview(true))
        #expect(m.autoReviewOn && m.autoReview.preset == .codex)
        #expect(await m.patchAutoReview(AutoReviewConfig.reasoningPatch("")))
        #expect(m.autoReview.reasoning == nil)
        await m.setAutoReview(false)
    }
}
