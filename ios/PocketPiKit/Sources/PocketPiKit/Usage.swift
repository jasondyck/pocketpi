import Foundation

// Settings › Usage: cost and tokens across every chat (`GET /api/usage`,
// src/usage.rs), per day, model, provider and project.
//
// Costs are what pi recorded. Subscription providers (pi's OAuth logins,
// Codex, Copilot) don't bill per token: their cost is an API-rate
// equivalent (often $0), so it's kept apart from what was billed. OpenCode Go
// draws from a prepaid dollar pool and is shown on its own too.

/// How a provider is paid for.
public enum Billing: String, Sendable, Equatable, CaseIterable {
    /// Billed per token.
    case api
    /// A subscription: the cost is an API-rate equivalent.
    case subscription
    /// OpenCode Go's prepaid pool.
    case pool

    public var label: String {
        switch self {
        case .api: "API (billed)"
        case .subscription: "Subscriptions"
        case .pool: "OpenCode Go"
        }
    }

    /// What its cost figure means.
    public var costNote: String {
        switch self {
        case .api: "billed per token"
        case .subscription: "API-rate equivalent, not billed"
        case .pool: "from the prepaid pool"
        }
    }
}

public struct UsageTotals: Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var tokens = 0
    public var cost = 0.0
    /// Replies, summaries and usage entries counted.
    public var count = 0

    public init() {}

    init(_ v: JSONValue?) {
        guard let v else { return }
        input = v["input"]?.int ?? 0
        output = v["output"]?.int ?? 0
        cacheRead = v["cacheRead"]?.int ?? 0
        cacheWrite = v["cacheWrite"]?.int ?? 0
        tokens = v["tokens"]?.int ?? (input + output + cacheRead + cacheWrite)
        cost = v["cost"]?.double ?? 0
        count = v["count"]?.int ?? 0
    }
}

/// One row of a breakdown: a model, a provider or a project.
public struct UsageRow: Sendable, Equatable, Identifiable {
    /// "provider/model", the provider, or the project's path.
    public var id: String
    public var provider: String?
    public var model: String?
    public var project: String?
    public var billing: Billing?
    public var totals: UsageTotals

    init(_ v: JSONValue) {
        provider = v["provider"]?.string
        model = v["model"]?.string
        project = v["project"]?.string
        billing = v["billing"]?.string.flatMap(Billing.init(rawValue:))
        totals = UsageTotals(v)
        id = project ?? [provider, model].compactMap { $0 }.joined(separator: "/")
    }
}

public struct UsageDay: Sendable, Equatable, Identifiable {
    /// `YYYY-MM-DD` in the time zone asked for.
    public var day: String
    public var totals: UsageTotals
    public var cost: [Billing: Double]
    public var tokens: [Billing: Int]
    public var id: String { day }

    init(_ v: JSONValue) {
        day = v["day"]?.string ?? ""
        totals = UsageTotals(v)
        var c: [Billing: Double] = [:], t: [Billing: Int] = [:]
        for b in Billing.allCases {
            c[b] = v[b.rawValue]?["cost"]?.double ?? 0
            t[b] = v[b.rawValue]?["tokens"]?.int ?? 0
        }
        cost = c
        tokens = t
    }

    /// "Nov 8" from `2026-11-08`.
    public var shortLabel: String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), (1...12).contains(m), let d = Int(parts[2]) else { return day }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[m - 1]) \(d)"
    }
}

public struct UsageReport: Sendable, Equatable {
    public var days: Int
    public var from: String
    public var to: String
    public var totals: UsageTotals
    public var billing: [Billing: UsageTotals]
    public var byDay: [UsageDay]
    public var byModel: [UsageRow]
    public var byProvider: [UsageRow]
    public var byProject: [UsageRow]
    /// Session files looked at, and how long the server took.
    public var files: Int
    public var milliseconds: Int

    public init(_ v: JSONValue) {
        days = v["days"]?.int ?? 0
        from = v["from"]?.string ?? ""
        to = v["to"]?.string ?? ""
        totals = UsageTotals(v["totals"])
        var b: [Billing: UsageTotals] = [:]
        for k in Billing.allCases { b[k] = UsageTotals(v["billing"]?[k.rawValue]) }
        billing = b
        byDay = (v["byDay"]?.array ?? []).map(UsageDay.init)
        byModel = (v["byModel"]?.array ?? []).map(UsageRow.init)
        byProvider = (v["byProvider"]?.array ?? []).map(UsageRow.init)
        byProject = (v["byProject"]?.array ?? []).map(UsageRow.init)
        files = v["files"]?.int ?? 0
        milliseconds = v["ms"]?.int ?? 0
    }

    /// The ranges the dashboard offers.
    public static let ranges = [7, 30, 90]

    /// Billing kinds with anything in them, in a fixed order.
    public var billingUsed: [Billing] { Billing.allCases.filter { (billing[$0]?.count ?? 0) > 0 } }

    /// Real money: billed API cost plus what came out of OpenCode Go's pool
    /// (subscriptions' API-rate equivalents left out).
    public var spent: Double { (billing[.api]?.cost ?? 0) + (billing[.pool]?.cost ?? 0) }

    /// The tallest bar, for scaling the chart (`cost: false` for tokens).
    public func peak(cost: Bool) -> Double {
        byDay.map { cost ? $0.totals.cost : Double($0.totals.tokens) }.max() ?? 0
    }

    /// One day's bar as stacked segments 0...1 of the chart's height, in
    /// `Billing.allCases` order; empty segments left out.
    public func segments(of day: UsageDay, cost: Bool) -> [(Billing, Double)] {
        let peak = peak(cost: cost)
        guard peak > 0 else { return [] }
        return Billing.allCases.compactMap { b in
            let v = cost ? (day.cost[b] ?? 0) : Double(day.tokens[b] ?? 0)
            return v > 0 ? (b, v / peak) : nil
        }
    }
}
