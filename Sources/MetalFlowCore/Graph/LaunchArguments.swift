import Foundation

/// Command-line launch argument problems.
public enum LaunchArgumentError: Error, Equatable, LocalizedError {
    case badSet(String)
    case unknownInput(String)
    case noFieldForValue
    case noFlowNamed(String)
    case ambiguousFlow(String, [String])

    public var errorDescription: String? {
        switch self {
        case .badSet(let s): return "expected --set name=value, got '\(s)'"
        case .unknownInput(let n): return "the flow has no input named '\(n)'"
        case .noFieldForValue: return "the flow takes no input besides the repo, so there is no place for a value"
        case .noFlowNamed(let n): return "no flow named '\(n)' (and no such file)"
        case .ambiguousFlow(let n, let paths):
            return "several flows are named '\(n)'; pass a path instead:\n" + paths.map { "  \($0)" }.joined(separator: "\n")
        }
    }
}

/// Pure parsing for `mflow launch`.
public enum LaunchArguments {
    /// Splits `name=value` at the first `=`. The name must be non-empty; the value may be empty or contain `=`.
    public static func parseSet(_ s: String) throws -> (String, String) {
        guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { throw LaunchArgumentError.badSet(s) }
        return (String(s[..<eq]), String(s[s.index(after: eq)...]))
    }

    /// Launch values from the positional (first non-repo field) and `--set` pairs; `--set` wins over the positional.
    public static func values(fields: [LaunchField], positional: String?, sets: [(String, String)]) throws -> [String: String] {
        var out: [String: String] = [:]
        if let positional {
            guard let first = fields.first(where: { $0.kind != .repo }) else { throw LaunchArgumentError.noFieldForValue }
            out[first.name] = positional
        }
        for (name, value) in sets {
            guard fields.contains(where: { $0.name == name }) else { throw LaunchArgumentError.unknownInput(name) }
            out[name] = value
        }
        return out
    }
}

extension FlowCatalog {
    /// The entry whose name equals `flowArgument`, ignoring case. Throws when none or several match.
    public static func resolve(flowArgument: String, entries: [FlowEntry]) throws -> FlowEntry {
        let wanted = flowArgument.lowercased()
        let matches = entries.filter { $0.name.lowercased() == wanted }
        guard let first = matches.first else { throw LaunchArgumentError.noFlowNamed(flowArgument) }
        if matches.count > 1 {
            throw LaunchArgumentError.ambiguousFlow(flowArgument, matches.map { $0.file?.path ?? "(built-in)" })
        }
        return first
    }
}
