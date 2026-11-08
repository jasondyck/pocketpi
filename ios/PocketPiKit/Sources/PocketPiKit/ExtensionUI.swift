import Foundation

/// What pi's extensions keep on screen with the fire-and-forget
/// `extension_ui_request`s: status chips (`setStatus`), blocks of lines above
/// or below the composer (`setWidget`) and a title (`setTitle`). It belongs to
/// one pi process: pocketpi replays it in `pocketpi_hello`, and it goes when
/// pi exits.
public struct ExtensionUIState: Sendable, Equatable {
    public struct Status: Sendable, Equatable, Identifiable {
        public var key: String
        public var text: String
        public var id: String { key }
    }

    public struct Widget: Sendable, Equatable, Identifiable {
        public enum Placement: String, Sendable { case aboveEditor, belowEditor }
        public var key: String
        public var lines: [String]
        public var placement: Placement
        public var id: String { key }
    }

    /// In the order the keys were first set.
    public private(set) var statuses: [Status] = []
    public private(set) var widgets: [Widget] = []
    public private(set) var title: String?

    public init() {}

    public var isEmpty: Bool { statuses.isEmpty && widgets.isEmpty }
    public var aboveEditor: [Widget] { widgets.filter { $0.placement == .aboveEditor } }
    public var belowEditor: [Widget] { widgets.filter { $0.placement == .belowEditor } }

    /// Apply one setStatus / setWidget / setTitle request. False for any
    /// other method.
    @discardableResult
    public mutating func apply(_ ev: JSONValue) -> Bool {
        switch ev["method"]?.string {
        case "setStatus":
            let key = ev["statusKey"]?.string ?? ""
            if let t = ev["statusText"]?.string {
                let s = Status(key: key, text: Self.plain(t))
                if let i = statuses.firstIndex(where: { $0.key == key }) { statuses[i] = s } else { statuses.append(s) }
            } else {
                statuses.removeAll { $0.key == key }
            }
        case "setWidget":
            let key = ev["widgetKey"]?.string ?? ""
            if let lines = ev["widgetLines"]?.array {
                let w = Widget(key: key, lines: lines.compactMap(\.string).map(Self.plain),
                               placement: Widget.Placement(rawValue: ev["widgetPlacement"]?.string ?? "") ?? .aboveEditor)
                if let i = widgets.firstIndex(where: { $0.key == key }) { widgets[i] = w } else { widgets.append(w) }
            } else {
                widgets.removeAll { $0.key == key }
            }
        case "setTitle":
            let t = Self.plain(ev["title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            title = t.isEmpty ? nil : t
        default:
            return false
        }
        return true
    }

    /// Start over with what `pocketpi_hello` says is in effect.
    public mutating func reset(replaying requests: [JSONValue] = []) {
        self = ExtensionUIState()
        for r in requests { apply(r) }
    }

    /// Text without the terminal's escape sequences (extensions colour their
    /// status with the TUI theme).
    public static func plain(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = ""
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\u{1B}" else { out.unicodeScalars.append(c); continue }
            guard let n = it.next() else { break }
            if n == "[" {
                // CSI: parameters, then one final byte in @...~
                while let p = it.next(), !(0x40...0x7E).contains(p.value) {}
            } else if n == "]" {
                // OSC: up to BEL or ESC \
                while let p = it.next() {
                    if p == "\u{07}" { break }
                    if p == "\u{1B}" { _ = it.next(); break }
                }
            }
        }
        return out
    }
}

extension ExtensionRequest {
    /// Seconds left before pi answers the dialog itself, or nil without a
    /// timeout.
    public func remaining(at now: Date = Date()) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        deadline.map { now >= $0 } ?? false
    }

    /// "Closes in 9 s", for the dialog; nil without a timeout.
    public func countdown(at now: Date = Date()) -> String? {
        remaining(at: now).map { "Closes in \(Int($0.rounded(.up))) s" }
    }
}
