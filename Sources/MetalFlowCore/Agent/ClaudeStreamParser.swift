import Foundation

/// Failures while parsing Claude Code stream-json output.
public enum ClaudeStreamError: Error, Equatable {
    /// A line was not a valid JSON object.
    case malformedLine(String)
}

/// Converts `claude -p --output-format stream-json` lines into `AgentEvent`s.
public struct ClaudeStreamParser {
    /// Creates a parser.
    public init() {}

    /// Parses one line. Unknown line types and subtypes yield no events; malformed JSON throws.
    public mutating func parse(line: String) throws -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeStreamError.malformedLine(line)
        }
        switch object["type"] as? String {
        case "system":
            guard object["subtype"] as? String == "init", let id = object["session_id"] as? String else { return [] }
            return [.started(sessionID: id)]
        case "assistant":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap(Self.event(forContent:))
        case "result":
            let denials = (object["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
            let result = AgentResult(
                sessionID: object["session_id"] as? String ?? "",
                text: object["result"] as? String ?? "",
                isError: object["is_error"] as? Bool ?? false,
                deniedTools: denials,
                costUSD: (object["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0,
                turns: (object["num_turns"] as? NSNumber)?.intValue ?? 0)
            return [.finished(result)]
        default:
            return []
        }
    }

    private static func event(forContent item: [String: Any]) -> AgentEvent? {
        switch item["type"] as? String {
        case "text":
            return (item["text"] as? String).map(AgentEvent.text)
        case "tool_use":
            guard let name = item["name"] as? String else { return nil }
            var summary = ""
            if let input = item["input"], JSONSerialization.isValidJSONObject(input),
               let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) {
                summary = String(String(decoding: data, as: UTF8.self).prefix(80))
            }
            return .toolUse(name: name, summary: summary)
        default:
            return nil
        }
    }
}
