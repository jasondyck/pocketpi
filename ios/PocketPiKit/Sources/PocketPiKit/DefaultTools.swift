import Foundation

// `defaultTools` in pi's settings (docs/settings.md; docs/pi-parity-plan.md
// F6): the tools a new chat starts with. The web twin is the "Default tools"
// card in web/manage-settings.js.
//
//   - plain names replace the inherited selection: ["read", "grep"]
//   - a list of only `+name` / `-name` entries changes it: ["+codemode"]
//   - in one list, the plain names form the selection, then the +/- entries
//     apply in order
//   - project settings apply on top of the user's: a project list of only
//     +/- changes the user's selection, one with a plain name replaces it
//   - an empty list turns every built-in tool off (not extension tools)
//
// Unset, pi starts with read, bash, edit and write.

public enum DefaultTools {
    /// pi's selection when nothing sets `defaultTools`.
    public static let piDefault = ["read", "bash", "edit", "write"]

    /// Names pi's docs list for `defaultTools`: the built-in tools, plus
    /// `codemode` and `tool_search`, which built-in extensions register off.
    public static let known = ["read", "bash", "edit", "write", "grep", "find", "ls", "powershell", "codemode", "tool_search"]

    public enum Op: String, Sendable { case use = "", add = "+", remove = "-" }

    public struct Entry: Hashable, Sendable, Identifiable {
        public var op: Op
        public var name: String
        public var id: String { raw }
        public var raw: String { op.rawValue + name }

        public init(op: Op, name: String) {
            self.op = op
            self.name = name
        }

        public init?(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if let f = t.first, f == "+" || f == "-" {
                let n = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return nil }
                self.init(op: f == "+" ? .add : .remove, name: n)
            } else {
                guard !t.isEmpty else { return nil }
                self.init(op: .use, name: t)
            }
        }
    }

    /// The file's list; nil when it doesn't set one.
    public static func parse(_ v: JSONValue?) -> [Entry]? {
        guard let a = v?.array else { return nil }
        return a.compactMap(\.string).compactMap(Entry.init)
    }

    /// Only +/- entries (or empty is not): changes what it inherits.
    public static func isRelative(_ list: [Entry]) -> Bool {
        !list.isEmpty && list.allSatisfy { $0.op != .use }
    }

    /// The selection a list gives on top of `inherited`, as pi works it out.
    public static func resolve(_ list: [Entry]?, inherited: [String] = piDefault) -> [String] {
        guard let list else { return inherited }
        var out = list.contains { $0.op == .use } || list.isEmpty ? [] : inherited
        for e in list where e.op == .use && !out.contains(e.name) { out.append(e.name) }
        for e in list where e.op != .use {
            out.removeAll { $0 == e.name }
            if e.op == .add { out.append(e.name) }
        }
        return out
    }

    /// The list after switching one tool, written the least surprising way:
    /// a relative list (or none) stays relative (`+name` / `-name`, and an
    /// entry that no longer changes anything is dropped); a list of plain
    /// names gets the name added or taken out.
    public static func toggling(_ list: [Entry]?, _ name: String, on: Bool, inherited: [String] = piDefault) -> [Entry] {
        let current = list ?? []
        if list == nil || isRelative(current) {
            var l = current.filter { $0.name != name }
            if inherited.contains(name) != on { l.append(Entry(op: on ? .add : .remove, name: name)) }
            return l
        }
        var l = current.filter { !($0.name == name && $0.op != .use) }
        if on {
            if !resolve(l, inherited: inherited).contains(name) { l.append(Entry(op: .use, name: name)) }
        } else {
            l.removeAll { $0.name == name }
        }
        return l
    }

    /// The patch for a list; nil goes back to inheriting (removes the key).
    /// An empty list is kept: it means "no built-in tools".
    public static func patch(_ list: [Entry]?) -> PiConfigPatch {
        guard let list else { return PiConfigPatch(unset: ["defaultTools"]) }
        return PiConfigPatch(set: ["defaultTools": .array(list.map { .string($0.raw) })])
    }

    /// One line on what a list does.
    public static func explain(_ list: [Entry]?, project: Bool = false) -> String {
        let from = project ? "your global selection" : "pi's default (read, bash, edit, write)"
        guard let list else { return "Not set: new chats get \(from)." }
        if list.isEmpty { return "Empty: new chats start with no built-in tools (extension tools still load)." }
        if isRelative(list) { return "Only +/− entries: they change \(from)." }
        return "Plain names replace \(from); +/− entries then apply in order."
    }

    /// Tools to offer as switches: the known ones, plus any the list or the
    /// inherited selection names.
    public static func offered(_ list: [Entry]?, inherited: [String] = piDefault) -> [String] {
        var out = known
        for n in inherited + (list ?? []).map(\.name) where !out.contains(n) { out.append(n) }
        return out
    }
}
