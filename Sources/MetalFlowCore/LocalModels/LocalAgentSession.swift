import Foundation

public struct LocalAgentError: Error, CustomStringConvertible {
    public let description: String
}

/// Runs an agent session against a local model server, with the local tools and resumable transcripts.
public struct LocalAgentSession: AgentSession {
    public static let defaultMaxTurns = 30

    /// The system prompt for local models. The question convention alone makes qwen2.5-coder reply with a QUESTION
    /// line after a tool result instead of its answer (verified against Ollama), so the second sentence tells it to
    /// answer directly when it can.
    static let systemPrompt = ClaudeCLI.questionConvention + " Otherwise do not ask questions; answer the user directly."

    private let client: LocalChatClient
    private let transcripts: LocalTranscriptStore

    public init(client: LocalChatClient, transcripts: LocalTranscriptStore) {
        self.client = client
        self.transcripts = transcripts
    }

    public func run(_ r: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.loop(r, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let permissionNames = [
        "read": "Read", "grep": "Grep", "glob": "Glob", "edit": "Edit", "write": "Write", "bash": "Bash",
    ]

    private func loop(_ r: AgentRequest, _ out: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        guard let providerName = r.provider else {
            throw LocalAgentError(description: "No local provider set for model \(r.model).")
        }
        guard let provider = LocalProvider(rawValue: providerName) else {
            throw LocalAgentError(description: "Unknown local provider: \(providerName).")
        }
        let sessionID = r.resumeSessionID ?? "local-" + UUID().uuidString
        var messages = try transcripts.load(sessionID: sessionID)
        if messages.first?.role != .system {
            messages.insert(ChatMessage(role: .system, content: Self.systemPrompt), at: 0)
        }
        messages.append(ChatMessage(role: .user, content: r.prompt))
        out.yield(.started(sessionID: sessionID))

        let tools = LocalTools(workingDirectory: r.workingDirectory)
        let permissions = ToolPermissions(allowedTools: r.allowedTools)
        let specs = LocalTools.specs.map { ToolSpec(name: $0.name, description: $0.description, parameters: $0.parametersJSON) }
        let limit = r.maxTurns ?? Self.defaultMaxTurns
        var denied: [String] = []
        var lastText = ""
        var turns = 0

        while turns < limit {
            if Task.isCancelled { return }
            turns += 1
            let reply = try await client.complete(provider: provider, model: r.model, messages: messages, tools: specs)
            if let content = reply.content, !content.isEmpty {
                lastText = content
                out.yield(.text(content))
            }
            messages.append(ChatMessage(role: .assistant, content: reply.content, toolCalls: reply.toolCalls))
            if reply.toolCalls.isEmpty {
                try transcripts.save(sessionID: sessionID, messages: messages)
                out.yield(.finished(AgentResult(sessionID: sessionID, text: lastText, isError: false, deniedTools: denied, costUSD: 0, turns: turns)))
                return
            }
            for call in reply.toolCalls {
                out.yield(.toolUse(name: call.name, summary: String(call.arguments.prefix(120))))
                let result = await execute(call, tools: tools, permissions: permissions, denied: &denied)
                messages.append(ChatMessage(role: .tool, content: result, toolCallID: call.id))
            }
            try transcripts.save(sessionID: sessionID, messages: messages)
        }
        let text = "Stopped: the turn limit of \(limit) was reached."
        out.yield(.finished(AgentResult(sessionID: sessionID, text: text, isError: true, deniedTools: denied, costUSD: 0, turns: turns)))
    }

    private func execute(_ call: ToolCall, tools: LocalTools, permissions: ToolPermissions, denied: inout [String]) async -> String {
        guard let permission = Self.permissionNames[call.name] else { return "Unknown tool: \(call.name)." }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { args[key] as? String }
        func missing(_ key: String) -> String { "Missing argument: \(key)." }

        let allowed: Bool
        if call.name == "bash" {
            allowed = string("command").map { permissions.allowsBash(command: $0) } ?? false
        } else {
            allowed = permissions.allows(tool: permission)
        }
        if !allowed {
            if !denied.contains(permission) { denied.append(permission) }
            return "Denied: \(permission) is not allowed for this node."
        }
        do {
            switch call.name {
            case "read":
                guard let path = string("path") else { return missing("path") }
                return try tools.read(path: path)
            case "grep":
                guard let pattern = string("pattern") else { return missing("pattern") }
                return try tools.grep(pattern: pattern, path: string("path"))
            case "glob":
                guard let pattern = string("pattern") else { return missing("pattern") }
                return try tools.glob(pattern: pattern)
            case "edit":
                guard let path = string("path") else { return missing("path") }
                guard let old = string("old_string") else { return missing("old_string") }
                guard let new = string("new_string") else { return missing("new_string") }
                return try tools.edit(path: path, oldString: old, newString: new)
            case "write":
                guard let path = string("path") else { return missing("path") }
                guard let content = string("content") else { return missing("content") }
                return try tools.write(path: path, content: content)
            default:
                guard let command = string("command") else { return missing("command") }
                if let timeout = args["timeout"] as? Double, timeout > 0 {
                    return try await tools.bash(command: command, timeout: timeout)
                }
                return try await tools.bash(command: command)
            }
        } catch let e as LocalToolError {
            return e.message
        } catch {
            return "\(error)"
        }
    }
}
