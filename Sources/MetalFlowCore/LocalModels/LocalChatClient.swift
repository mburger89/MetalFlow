import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A local server that speaks the OpenAI-compatible chat API.
public enum LocalProvider: String, Sendable, CaseIterable {
    case ollama
    case lmstudio

    public static let defaultOllamaURL = "http://localhost:11434/v1"
    public static let defaultLMStudioURL = "http://localhost:1234/v1"

    /// The base URL for this provider, from `MF_OLLAMA_URL` / `MF_LMSTUDIO_URL` in `environment`.
    public func baseURL(environment: [String: String]) -> URL {
        let (key, fallback) = switch self {
        case .ollama: ("MF_OLLAMA_URL", Self.defaultOllamaURL)
        case .lmstudio: ("MF_LMSTUDIO_URL", Self.defaultLMStudioURL)
        }
        if let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty, let url = URL(string: value) {
            return url
        }
        return URL(string: fallback)!
    }

    /// The base URL from the process environment (read on each call; clients capture it once at creation).
    public var baseURL: URL { baseURL(environment: ProcessInfo.processInfo.environment) }

    /// Splits `ollama:qwen2.5-coder:7b` on the first colon. Nil for a Claude model name.
    public static func parse(model: String) -> (provider: LocalProvider, model: String)? {
        guard let colon = model.firstIndex(of: ":"),
              let provider = LocalProvider(rawValue: String(model[..<colon])) else { return nil }
        return (provider, String(model[model.index(after: colon)...]))
    }
}

public struct ToolCall: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    /// The arguments as a JSON string, as the server sent them.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Equatable, Codable { case system, user, assistant, tool }

    public var role: Role
    public var content: String?
    public var toolCalls: [ToolCall]
    public var toolCallID: String?

    public init(role: Role, content: String? = nil, toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    /// The parameters as a JSON-schema string.
    public var parameters: String

    public init(name: String, description: String, parameters: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ChatReply: Sendable, Equatable {
    public var content: String?
    public var toolCalls: [ToolCall]
    public var finishReason: String?

    public init(content: String? = nil, toolCalls: [ToolCall] = [], finishReason: String? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.finishReason = finishReason
    }
}

public enum LocalChatError: Error, Equatable, LocalizedError {
    case http(status: Int, message: String)
    case malformed
    case unreachable(provider: LocalProvider)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): "The local model server returned HTTP \(status): \(message)"
        case .malformed: "The local model server sent a reply without a message."
        case .unreachable(let provider): "Could not reach \(provider == .ollama ? "Ollama" : "LM Studio"). Is it running?"
        }
    }
}

public protocol LocalChatClient: Sendable {
    func complete(provider: LocalProvider, model: String, messages: [ChatMessage], tools: [ToolSpec]) async throws -> ChatReply
}

public struct URLSessionChatClient: LocalChatClient {
    private let session: URLSession
    private let baseURLs: [LocalProvider: URL]

    /// Base URLs are read from `environment` once, here.
    public init(session: URLSession = .shared, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.session = session
        var urls: [LocalProvider: URL] = [:]
        for provider in LocalProvider.allCases { urls[provider] = provider.baseURL(environment: environment) }
        self.baseURLs = urls
    }

    public func complete(provider: LocalProvider, model: String, messages: [ChatMessage], tools: [ToolSpec]) async throws -> ChatReply {
        let base = baseURLs[provider] ?? provider.baseURL
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.body(model: model, messages: messages, tools: tools)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw LocalChatError.unreachable(provider: provider)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LocalChatError.http(status: http.statusCode, message: Self.errorMessage(in: data))
        }
        return try Self.reply(from: data, toolNames: tools.map(\.name))
    }

    static func body(model: String, messages: [ChatMessage], tools: [ToolSpec]) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(encode),
            "stream": false,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                let params = (try? JSONSerialization.jsonObject(with: Data(tool.parameters.utf8))) ?? [String: Any]()
                return ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": params]]
            }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func encode(_ message: ChatMessage) -> [String: Any] {
        var out: [String: Any] = ["role": message.role.rawValue]
        if let content = message.content {
            out["content"] = content
        } else if message.role == .assistant {
            out["content"] = NSNull()
        }
        if !message.toolCalls.isEmpty {
            out["tool_calls"] = message.toolCalls.map { call -> [String: Any] in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
            }
        }
        if let id = message.toolCallID { out["tool_call_id"] = id }
        return out
    }

    private static func errorMessage(in data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let error = json["error"] as? String { return error }
        }
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func reply(from data: Data, toolNames: [String] = []) throws -> ChatReply {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else { throw LocalChatError.malformed }
        var calls: [ToolCall] = []
        for (index, raw) in (message["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
            guard let function = raw["function"] as? [String: Any], let name = function["name"] as? String else { continue }
            let arguments: String
            if let s = function["arguments"] as? String {
                arguments = s
            } else if let object = function["arguments"], JSONSerialization.isValidJSONObject(object),
                      let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                arguments = String(decoding: d, as: UTF8.self)   // some servers send an object
            } else {
                arguments = "{}"
            }
            calls.append(ToolCall(id: (raw["id"] as? String) ?? "call_\(index)", name: name, arguments: arguments))
        }
        let reply = ChatReply(content: message["content"] as? String, toolCalls: calls, finishReason: first["finish_reason"] as? String)
        return textToolCallFallback(reply, toolNames: toolNames)
    }

    /// Some servers return a tool call as JSON text in `content` instead of `tool_calls`. When the reply has no
    /// tool calls and its content (optionally in a Markdown code fence) is one JSON object with a `name` that is in
    /// `toolNames` and `arguments` (an object, or a string holding JSON), returns the reply with that one call
    /// (id `text_0`). The content is kept. Any other reply is returned unchanged.
    static func textToolCallFallback(_ reply: ChatReply, toolNames: [String]) -> ChatReply {
        guard reply.toolCalls.isEmpty, let content = reply.content, !toolNames.isEmpty else { return reply }
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            text = String(text.dropFirst(3).dropLast(3))
            if let newline = text.firstIndex(of: "\n") {
                let tag = text[..<newline].trimmingCharacters(in: .whitespaces)
                if tag.allSatisfy({ $0.isLetter || $0.isNumber }) { text = String(text[text.index(after: newline)...]) }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.hasPrefix("{"), text.hasSuffix("}"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let name = object["name"] as? String, toolNames.contains(name) else { return reply }
        let arguments: String
        switch object["arguments"] {
        case let dictionary as [String: Any]:
            guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) else { return reply }
            arguments = String(decoding: data, as: UTF8.self)
        case let string as String:
            guard (try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]) != nil else { return reply }
            arguments = string
        default:
            return reply
        }
        var result = reply
        result.toolCalls = [ToolCall(id: "text_0", name: name, arguments: arguments)]
        return result
    }
}
