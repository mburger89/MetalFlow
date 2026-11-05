/// A block-level piece of Markdown. Inline styling stays in the strings and is
/// parsed later by the renderer.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case code(language: String?, text: String)
    case quote(String)
    case rule
}

/// A small, pure, CommonMark-style block parser. It is deliberately simplified:
/// no nested lists, tables, images, HTML or footnotes (those read as paragraphs).
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var parser = Parser()
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        for line in lines { parser.feed(String(line)) }
        return parser.finish()
    }

    private struct Parser {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []
        var fence: (char: Character, count: Int, language: String?)?
        var code: [String] = []

        mutating func flushText() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }

        mutating func feed(_ raw: String) {
            let line = trimTrailing(raw)

            if let open = fence {
                let t = trimLeading(line)
                if let run = fenceRun(t), run.char == open.char, run.count >= open.count,
                   trimTrailing(String(t.drop(while: { $0 == open.char }))).isEmpty {
                    blocks.append(.code(language: open.language, text: code.joined(separator: "\n")))
                    fence = nil
                    code = []
                } else {
                    code.append(line)
                }
                return
            }

            let t = trimLeading(line)
            let indented = t.count != line.count

            if t.isEmpty { flushText(); return }

            if let run = fenceRun(t) {
                flushText()
                let info = trim(String(t.drop(while: { $0 == run.char })))
                // A backtick fence's info string may not contain backticks.
                if run.char == "`" && info.contains("`") {
                    paragraph.append(line)
                } else {
                    fence = (run.char, run.count, info.isEmpty ? nil : info)
                }
                return
            }

            if !indented, let h = heading(t) {
                flushText()
                blocks.append(.heading(level: h.level, text: h.text))
                return
            }

            if isRule(t) { flushText(); blocks.append(.rule); return }

            if t.hasPrefix(">") {
                if quote.isEmpty { flushText() }
                var rest = t.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
                quote.append(String(rest))
                return
            }

            if let item = bulletItem(t) {
                if bullets.isEmpty { flushText() }
                bullets.append(item)
                return
            }

            if let item = numberedItem(t) {
                if numbered.isEmpty { flushText() }
                numbered.append(item)
                return
            }

            // An indented line continues the item above it.
            if indented && !bullets.isEmpty { bullets[bullets.count - 1] += "\n" + t; return }
            if indented && !numbered.isEmpty { numbered[numbered.count - 1] += "\n" + t; return }

            if paragraph.isEmpty { flushText() }
            paragraph.append(line)
        }

        mutating func finish() -> [MarkdownBlock] {
            if let open = fence {
                blocks.append(.code(language: open.language, text: code.joined(separator: "\n")))
                fence = nil
                code = []
            }
            flushText()
            return blocks
        }
    }

    // MARK: Line helpers

    private static func trimTrailing(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)].isWhitespace { end = s.index(before: end) }
        return String(s[s.startIndex..<end])
    }

    private static func trimLeading(_ s: String) -> String {
        String(s.drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func trim(_ s: String) -> String { trimLeading(trimTrailing(s)) }

    private static func fenceRun(_ t: String) -> (char: Character, count: Int)? {
        guard let c = t.first, c == "`" || c == "~" else { return nil }
        let n = t.prefix(while: { $0 == c }).count
        return n >= 3 ? (c, n) : nil
    }

    private static func heading(_ t: String) -> (level: Int, text: String)? {
        let level = t.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var body = trim(String(rest))
        // Strip an optional closing run of #s (only when separated by a space, or the whole body).
        if body.last == "#" {
            let stripped = trimTrailing(String(body.dropLast(body.reversed().prefix(while: { $0 == "#" }).count)))
            if stripped.isEmpty || body[body.index(body.startIndex, offsetBy: stripped.count)] == " " { body = stripped }
        }
        return (level, body)
    }

    private static func isRule(_ t: String) -> Bool {
        let chars = t.filter { $0 != " " && $0 != "\t" }
        guard let c = chars.first, c == "-" || c == "*" || c == "_", chars.count >= 3 else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func bulletItem(_ t: String) -> String? {
        guard let c = t.first, c == "-" || c == "*" || c == "+" else { return nil }
        let rest = t.dropFirst()
        guard rest.first == " " else { return nil }
        return trim(String(rest))
    }

    private static func numberedItem(_ t: String) -> String? {
        let digits = t.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return nil }
        let rest = t.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest == "." else { return nil }
        return trim(String(rest.dropFirst()))
    }
}
