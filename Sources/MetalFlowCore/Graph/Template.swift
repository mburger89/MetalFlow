import Foundation

/// `{placeholder}` handling for node prompts and commands.
public enum Template {
    private static let regex = try! NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#)

    /// Placeholder names in `text`, in order of appearance (duplicates kept).
    /// A placeholder is `{name}` where name matches `[A-Za-z_][A-Za-z0-9_]*`.
    public static func placeholders(in text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    /// Quotes a value as a single POSIX shell word: wrapped in single quotes, each `'` written as `'\''`.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Replaces `{name}` with `values[name]`. Unknown placeholders are left as-is and `{{` becomes a literal `{`.
    public static func fill(_ template: String, with values: [String: String]) -> String {
        let chars = Array(template)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                if i + 1 < chars.count, chars[i + 1] == "{" {
                    out.append("{")
                    i += 2
                    continue
                }
                if let close = chars[i...].firstIndex(of: "}") {
                    let name = String(chars[(i + 1)..<close])
                    if let v = values[name], placeholders(in: "{\(name)}").count == 1 {
                        out += v
                        i = close + 1
                        continue
                    }
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
