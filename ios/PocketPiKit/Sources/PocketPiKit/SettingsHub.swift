import Foundation
import Observation

// The Settings tab's shared state (docs/pi-parity-plan.md §7): which running
// pis are behind pi's config ("Restart to apply") and the reload that fixes
// it. One per server, in the app model; every Settings page gets it from the
// environment (`@Environment(SettingsHub.self)`), uses `client` for its own
// calls, and calls `changed()` after anything that edits pi's config.

@MainActor
@Observable
public final class SettingsHub {
    public let client: PocketPiClient
    /// The last `/api/pi/status`; nil until the first answer.
    public internal(set) var status: PiStatus?
    /// Chats the last reload left alone because they were busy.
    public private(set) var busyLeft: [String] = []
    public private(set) var reloading = false
    /// A failed reload or status call, for an alert.
    public var problem: String?

    public init(client: PocketPiClient) {
        self.client = client
    }

    // MARK: - what the banner shows

    /// Chats (not workflow stages) whose pi started before the last config change.
    public var staleChats: [LivePi] { (status?.live ?? []).filter { $0.stale && $0.kind != "stage" } }
    public var needsRestart: Bool { !staleChats.isEmpty }

    /// The Settings banner's line, or nil when every chat is current.
    public var bannerText: String? {
        let stale = staleChats
        guard !stale.isEmpty else { return nil }
        let busy = stale.filter(\.streaming).count
        let n = stale.count == 1 ? "1 open chat still uses" : "\(stale.count) open chats still use"
        return "Settings changed. \(n) the old ones" + (busy > 0 ? " (\(busy) busy)." : ".")
    }

    /// Whether a chat should offer "Restart to apply". Combines this hub's
    /// status with the chat's own hello, whichever is newer, so the banner
    /// goes as soon as the chat reconnects after a restart and comes as soon
    /// as the next status poll sees a change.
    public func needsRestart(_ chat: ChatSession) -> Bool {
        guard let key = chat.key else { return false }
        let live = status?.live.first { $0.key == key }
        return Self.isBehind(liveEpoch: live?.epoch, helloEpoch: chat.piEpoch,
                             configEpoch: status?.configEpoch, helloConfigEpoch: chat.helloConfigEpoch,
                             helloStale: chat.needsRestart)
    }

    /// The pi's epoch is the newest either source saw; so is the config's.
    nonisolated static func isBehind(liveEpoch: UInt64?, helloEpoch: UInt64?, configEpoch: UInt64?,
                                     helloConfigEpoch: UInt64?, helloStale: Bool) -> Bool {
        let pi = [liveEpoch, helloEpoch].compactMap { $0 }.max()
        let config = [configEpoch, helloConfigEpoch].compactMap { $0 }.max()
        guard let pi, let config else { return helloStale }
        return pi < config
    }

    /// What a reload did, as one line for a toast or alert.
    public nonisolated static func summary(of r: PiReloadResult) -> String {
        var parts: [String] = []
        if !r.restarted.isEmpty { parts.append("Restarted \(r.restarted.count) chat\(r.restarted.count == 1 ? "" : "s")") }
        if !r.busy.isEmpty {
            let one = r.busy.count == 1
            parts.append("\(r.busy.count) busy chat\(one ? "" : "s") left: try again when \(one ? "it finishes" : "they finish")")
        }
        if let f = r.failed.first { parts.append("\(r.failed.count) failed: \(f.error)") }
        return parts.isEmpty ? "Nothing to restart" : parts.joined(separator: " · ")
    }

    // MARK: - actions

    /// Fetch `/api/pi/status`. Quietly keeps the last one on failure.
    public func refresh() async {
        guard let s = try? await client.piStatus() else { return }
        status = s
        busyLeft.removeAll { k in !s.live.contains { $0.key == k && $0.stale } }
    }

    /// Call after changing pi's config (a patch, a job that changed files):
    /// refreshes the status so "Restart to apply" shows.
    public func changed() async { await refresh() }

    /// "Restart to apply": restarts every idle chat that's behind. Busy ones
    /// stay in `busyLeft` (and stale) until they're idle and this runs again.
    @discardableResult
    public func reload() async -> PiReloadResult? {
        reloading = true
        defer { reloading = false }
        do {
            let r = try await client.reload()
            busyLeft = r.busy
            await refresh()
            return r
        } catch {
            problem = error.reportable
            return nil
        }
    }

    /// Keep `status` fresh while the caller's task runs (the app runs this
    /// for as long as it's connected). Cancel the task to stop.
    public func watch(every interval: Duration = .seconds(8)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }
}
