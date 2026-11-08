import Foundation

/// Splits a reply into the blocks that need different views: fenced code,
/// headings, quotes, lists, rules and paragraphs. Inline markup inside them
/// (bold, code spans, links) is left for AttributedString(markdown:) to do.
public enum MarkdownBlock: Sendable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case quote(String)
    /// One list item; `marker` is "•" or "3." and `indent` its nesting depth.
    case listItem(marker: String, indent: Int, text: String)
    case rule

    /// Starts a section (the view gives it room above).
    public var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    public static func parse(_ src: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var para: [String] = []
        var quote: [String] = []
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0

        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                out.append(.code(language: lang.isEmpty ? nil : lang, text: body.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }

            if let h = heading(trimmed) { flush(); out.append(h); i += 1; continue }
            if isRule(trimmed) { flush(); out.append(.rule); i += 1; continue }
            if trimmed.hasPrefix(">") {
                if !para.isEmpty { flush() }
                var q = trimmed.dropFirst()
                if q.first == " " { q = q.dropFirst() }
                quote.append(String(q))
                i += 1
                continue
            }
            if let item = listItem(line) { flush(); out.append(item); i += 1; continue }

            if !quote.isEmpty { flush() }
            // A line after a list item, indented, continues it.
            if para.isEmpty, case .listItem(let m, let ind, let t)? = out.last, line.hasPrefix("  ") {
                out[out.count - 1] = .listItem(marker: m, indent: ind, text: t + "\n" + trimmed)
            } else {
                para.append(line)
            }
            i += 1
        }
        flush()
        return out
    }

    private static func heading(_ t: String) -> MarkdownBlock? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: t.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }
        let width = spaces.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(spaces.count)
        if let f = rest.first, "-*+".contains(f), rest.dropFirst().first == " " {
            var text = String(rest.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { marker = "☑"; text.removeFirst(4) }
            return .listItem(marker: marker, indent: width / 2, text: text)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
                return .listItem(marker: digits + ".", indent: width / 2, text: String(after.dropFirst(2)))
            }
        }
        return nil
    }
}
