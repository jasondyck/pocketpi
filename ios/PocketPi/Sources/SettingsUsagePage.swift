import Charts
import PocketPiKit
import SwiftUI

// Settings › Usage (plan H1): cost and tokens across every chat, per day,
// model, provider and project (GET /api/usage; PocketPiKit's Usage.swift).
// The web twin is web/manage-usage.js. Subscription costs are an API-rate
// equivalent, kept out of "Spent"; OpenCode Go's pool is shown on its own.

extension SettingsPage {
    static let usage = SettingsPage(id: "usage", title: "Usage", subtitle: "Cost and tokens by day, model and project",
                                    systemImage: "chart.bar", order: 60) { SettingsUsagePage() }
}

extension Billing {
    /// The same validated colors as the web page.
    var color: Color {
        switch self {
        case .api: Color(light: Color(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255), dark: Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255))
        case .pool: Color(light: Color(red: 0xEB / 255, green: 0x68 / 255, blue: 0x34 / 255), dark: Color(red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255))
        case .subscription: Color(light: Color(red: 0x1B / 255, green: 0xAF / 255, blue: 0x7A / 255), dark: Color(red: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255))
        }
    }
}

private struct SettingsUsagePage: View {
    @Environment(SettingsHub.self) private var hub
    @Environment(AppModel.self) private var model
    @AppStorage("usage.days") private var days = 30
    @AppStorage("usage.cost") private var showCost = true
    @State private var report: UsageReport?
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $days) {
                    ForEach(UsageReport.ranges, id: \.self) { Text("\($0) days").tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            }
            if let r = report {
                Section {
                    LabeledContent("Spent", value: Format.cost(r.spent))
                    LabeledContent("Tokens", value: Format.tokens(r.totals.tokens))
                    LabeledContent("Replies", value: r.totals.count.formatted())
                } footer: {
                    Text("Spent is billed API cost plus OpenCode Go's pool.")
                }
                Section("Cost by billing") {
                    ForEach(Billing.allCases, id: \.self) { b in
                        let t = r.billing[b] ?? UsageTotals()
                        HStack {
                            RoundedRectangle(cornerRadius: 3).fill(b.color).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.label)
                                Text(b.costNote).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Format.cost(t.cost))
                                Text(Format.tokens(t.tokens) + " tokens").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Picker("Show", selection: $showCost) {
                        Text("Cost").tag(true)
                        Text("Tokens").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Chart(r.points(cost: showCost)) { p in
                        BarMark(x: .value("Day", p.day), y: .value(showCost ? "Cost" : "Tokens", p.value))
                            .foregroundStyle(by: .value("Billing", p.billing.label))
                    }
                    .chartForegroundStyleScale(domain: Billing.allCases.map(\.label), range: Billing.allCases.map(\.color))
                    .chartXScale(domain: r.byDay.map(\.day))
                    .chartXAxis {
                        AxisMarks(values: r.axisDays()) { v in
                            AxisValueLabel { Text(r.byDay.first { $0.day == v.as(String.self) }?.shortLabel ?? "") }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { v in
                            AxisGridLine()
                            AxisValueLabel {
                                if let d = v.as(Double.self) { Text(showCost ? Format.cost(d) : Format.tokens(Int(d))) }
                            }
                        }
                    }
                    .chartLegend(position: .bottom)
                    .frame(height: 200)
                    .accessibilityLabel("\(showCost ? "Cost" : "Tokens") per day, \(r.from) to \(r.to)")
                } header: {
                    Text("Per day")
                }
                rows("By model", r.byModel) { ($0.model ?? "", $0.provider ?? "") }
                rows("By provider", r.byProvider) { ($0.provider ?? "", "") }
                rows("By project", r.byProject) { row in
                    let p = row.project ?? ""
                    return (model.projectName(for: p), p)
                }
                Section {} footer: {
                    Text("* Subscription costs are pi's API-rate equivalent (often $0), not money spent. \(r.files) session files · \(r.from) to \(r.to).")
                }
            } else if problem == nil {
                Section { ProgressView("Adding up your sessions…") }
            }
        }
        .monospacedDigit()
        .task(id: days) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func rows(_ title: String, _ list: [UsageRow], _ names: @escaping (UsageRow) -> (String, String)) -> some View {
        Section(title) {
            if list.isEmpty {
                Text("Nothing in this range").foregroundStyle(.secondary)
            }
            ForEach(list.prefix(25)) { row in
                let (name, detail) = names(row)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).lineLimit(2)
                        let note = [detail.isEmpty ? nil : detail,
                                    row.billing == .subscription ? "API-rate equivalent" : row.billing == .pool ? "OpenCode Go pool" : nil]
                            .compactMap { $0 }.joined(separator: " · ")
                        if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.cost(row.totals.cost) + (row.billing == .subscription ? "*" : ""))
                        Text(Format.tokens(row.totals.tokens)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            report = try await hub.client.usage(days: days)
            problem = nil
        } catch {
            if let e = error.reportable { problem = e }
        }
    }
}
