import Foundation
import Testing
@testable import PocketPiKit

@Suite struct ExportUsageTests {
    @Test func fileNamesFromTitles() {
        #expect(ExportName.file(title: "Fix the build: now!", ext: "html") == "Fix-the-build-now.html")
        #expect(ExportName.file(title: "  ", ext: "jsonl") == "pi-session.jsonl")
        #expect(ExportName.file(title: nil, fallback: "chat", ext: "html") == "chat.html")
        #expect(ExportName.file(title: "../../etc/passwd", ext: "html") == "etc-passwd.html")
        #expect(ExportName.file(title: "Café über alles", ext: "html") == "Café-über-alles.html")
        #expect(ExportName.file(title: String(repeating: "a", count: 100), ext: "html").count == 65)
    }

    @Test func compactInstructionsAreTrimmedOrLeftOut() {
        #expect(ExportName.instructions(nil) == nil)
        #expect(ExportName.instructions("  \n ") == nil)
        #expect(ExportName.instructions("  the API changes \n") == "the API changes")
    }

    @Test func sessionFilePathIsEscaped() {
        let p = PocketPiClient.sessionFilePath("/s/--home-x--/2026_a+b c&d.jsonl")
        #expect(p == "/api/sessions/file?path=/s/--home-x--/2026_a%2Bb%20c%26d.jsonl")
    }

    private let report = #"""
    {"days":3,"from":"2026-11-06","to":"2026-11-08","tz":-300,
     "totals":{"input":1100,"output":120,"cacheRead":20,"cacheWrite":10,"tokens":1250,"cost":1.25,"count":3},
     "billing":{"api":{"cost":1.0,"count":1,"tokens":135},"subscription":{"cost":0.0,"count":1,"tokens":1115},"pool":{"cost":0.25,"count":1,"tokens":26}},
     "byDay":[
       {"day":"2026-11-06","cost":0,"tokens":0,"count":0,"api":{"cost":0,"tokens":0},"subscription":{"cost":0,"tokens":0},"pool":{"cost":0,"tokens":0}},
       {"day":"2026-11-07","cost":0.25,"tokens":1141,"count":2,"api":{"cost":0,"tokens":0},"subscription":{"cost":0,"tokens":1115},"pool":{"cost":0.25,"tokens":26}},
       {"day":"2026-11-08","cost":1.0,"tokens":135,"count":1,"api":{"cost":1.0,"tokens":135},"subscription":{"cost":0,"tokens":0},"pool":{"cost":0,"tokens":0}}],
     "byModel":[{"provider":"anthropic","model":"claude-x","billing":"api","cost":1.0,"tokens":135,"count":1},
                {"provider":"openai-codex","model":"gpt-y","billing":"subscription","cost":0,"tokens":1115,"count":1}],
     "byProvider":[{"provider":"opencode-go","billing":"pool","cost":0.25,"tokens":26,"count":1}],
     "byProject":[{"project":"/p/one","cost":1.25,"tokens":1250,"count":3}],
     "files":2,"ms":4}
    """#

    @Test func readsAReport() throws {
        let r = UsageReport(try JSONDecoder().decode(JSONValue.self, from: Data(report.utf8)))
        #expect(r.days == 3 && r.from == "2026-11-06" && r.to == "2026-11-08")
        #expect(r.totals.tokens == 1250 && r.totals.count == 3)
        #expect(abs(r.spent - 1.25) < 1e-9)
        #expect(r.billingUsed == [.api, .subscription, .pool])
        #expect(r.byDay.map(\.shortLabel) == ["Nov 6", "Nov 7", "Nov 8"])
        #expect(r.byModel.first?.id == "anthropic/claude-x")
        #expect(r.byModel.last?.billing == .subscription)
        #expect(r.byProvider.first?.billing == .pool)
        #expect(r.byProject.first?.id == "/p/one")
        #expect(r.files == 2 && r.milliseconds == 4)
        #expect(Billing.subscription.costNote.contains("API-rate equivalent"))
    }

    @Test func barsStackByBilling() throws {
        let r = UsageReport(try JSONDecoder().decode(JSONValue.self, from: Data(report.utf8)))
        #expect(r.peak(cost: true) == 1.0)
        #expect(r.peak(cost: false) == 1141)
        #expect(r.segments(of: r.byDay[0], cost: true).isEmpty)
        let cost = r.segments(of: r.byDay[1], cost: true)
        #expect(cost.map(\.0) == [.pool] && cost[0].1 == 0.25)
        let tokens = r.segments(of: r.byDay[1], cost: false)
        #expect(tokens.map(\.0) == [.subscription, .pool])
        #expect(abs(tokens.map(\.1).reduce(0, +) - 1) < 1e-9)
        let pts = r.points(cost: false)
        #expect(pts.map(\.id) == ["2026-11-07/subscription", "2026-11-07/pool", "2026-11-08/api"])
        #expect(pts.first?.label == "Nov 7" && pts.first?.value == 1115)
        #expect(r.axisDays() == ["2026-11-06", "2026-11-07", "2026-11-08"])
        let empty = UsageReport(.object([:]))
        #expect(empty.byDay.isEmpty && empty.peak(cost: true) == 0 && empty.billingUsed.isEmpty)
    }
}
