import Foundation

/// `{placeholder}` handling for node prompts and commands.
public enum Template {
    /// Placeholder names in `text`, in order of appearance (duplicates kept).
    /// A placeholder is `{name}` where name matches `[A-Za-z_][A-Za-z0-9_]*`.
    public static func placeholders(in text: String) -> [String] {
        let pattern = #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }
}
