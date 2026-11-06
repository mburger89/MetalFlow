import Foundation

/// Decides which local tools a node may use, from the same `allowedTools`
/// strings the flows already use (`Read`, `Bash(git diff:*)`, a bare `Bash`).
public struct ToolPermissions: Sendable {
    private let plainTools: Set<String>
    private let bashAllowsAny: Bool
    private let bashPrefixes: [[String]]
    private let bashExact: [[String]]

    public init(allowedTools: [String]) {
        var plain = Set<String>()
        var any = false
        var prefixes: [[String]] = []
        var exact: [[String]] = []
        for raw in allowedTools {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            if entry == "Bash" {
                any = true
            } else if entry.hasPrefix("Bash("), entry.hasSuffix(")") {
                let inner = String(entry.dropFirst(5).dropLast())
                if inner.hasSuffix(":*") {
                    let words = inner.dropLast(2).split(whereSeparator: \.isWhitespace).map(String.init)
                    if words.isEmpty { any = true } else { prefixes.append(words) }
                } else {
                    let words = inner.split(whereSeparator: \.isWhitespace).map(String.init)
                    if !words.isEmpty { exact.append(words) }
                }
            } else {
                plain.insert(entry)
            }
        }
        plainTools = plain
        bashAllowsAny = any
        bashPrefixes = prefixes
        bashExact = exact
    }

    /// Whether a plain tool such as `Read` or `Edit` is allowed.
    public func allows(tool: String) -> Bool {
        plainTools.contains(tool)
    }

    /// Whether `command` may run. A command with a shell operator is never
    /// allowed; otherwise its leading words must match an allowed prefix.
    public func allowsBash(command: String) -> Bool {
        guard CommandWords.forbiddenOperator(in: command) == nil,
              let words = CommandWords.split(command), !words.isEmpty else { return false }
        if bashAllowsAny { return true }
        if bashExact.contains(words) { return true }
        return bashPrefixes.contains { prefix in
            words.count >= prefix.count && Array(words.prefix(prefix.count)) == prefix
        }
    }
}

/// Word splitting and operator checks shared by the permissions and the bash tool.
enum CommandWords {
    /// The first forbidden operator found in the raw text, if any.
    static func forbiddenOperator(in command: String) -> String? {
        if command.contains("\n") || command.contains("\r") { return "newline" }
        if command.contains("$(") { return "$(" }
        for op in [";", "&", "|", "<", ">", "`"] where command.contains(op) { return op }
        return nil
    }

    /// Splits on whitespace, honouring single and double quotes. Nil when a quote is left open.
    static func split(_ command: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        for ch in command {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                inWord = true
            } else if ch.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(ch)
                inWord = true
            }
        }
        if quote != nil { return nil }
        if inWord { words.append(current) }
        return words
    }
}
