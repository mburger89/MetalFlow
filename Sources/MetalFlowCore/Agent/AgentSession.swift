import Foundation

/// A request to run one headless agent session.
public struct AgentRequest: Sendable, Equatable {
    /// The prompt text.
    public var prompt: String
    /// Directory the agent works in.
    public var workingDirectory: URL
    /// Model name or alias.
    public var model: String
    /// Tools the agent may use without asking.
    public var allowedTools: [String]
    /// Maximum agentic turns, if limited.
    public var maxTurns: Int?
    /// Session to resume, if continuing an earlier one.
    public var resumeSessionID: String?
    /// The local provider (`ollama` or `lmstudio`) set by `AgentRouter`; nil for Claude.
    public var provider: String?

    /// Creates a request.
    public init(prompt: String, workingDirectory: URL, model: String, allowedTools: [String] = [], maxTurns: Int? = nil, resumeSessionID: String? = nil, provider: String? = nil) {
        self.provider = provider
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.model = model
        self.allowedTools = allowedTools
        self.maxTurns = maxTurns
        self.resumeSessionID = resumeSessionID
    }
}

/// The final outcome of an agent session.
public struct AgentResult: Sendable, Equatable, Codable {
    /// Session identifier (stable across resumes).
    public var sessionID: String
    /// The agent's final reply text.
    public var text: String
    /// True when the session ended in an error.
    public var isError: Bool
    /// Names of tools whose use was denied.
    public var deniedTools: [String]
    /// Cost of this invocation in US dollars.
    public var costUSD: Double
    /// Number of turns in this invocation.
    public var turns: Int

    /// Creates a result.
    public init(sessionID: String, text: String, isError: Bool, deniedTools: [String], costUSD: Double, turns: Int) {
        self.sessionID = sessionID
        self.text = text
        self.isError = isError
        self.deniedTools = deniedTools
        self.costUSD = costUSD
        self.turns = turns
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, text, isError, deniedTools, costUSD, turns
    }

    /// The text after the last line starting with `QUESTION:` (trimmed), or nil when there is none.
    public var question: String? {
        let marker = "QUESTION:"
        guard let line = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix(marker) }) else { return nil }
        return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
    }
}

/// Progress reported by a running agent session.
public enum AgentEvent: Sendable, Equatable {
    /// The session started with this identifier.
    case started(sessionID: String)
    /// The agent produced a piece of text.
    case text(String)
    /// The agent invoked a tool, with a short summary of its input.
    case toolUse(name: String, summary: String)
    /// The session finished with its final result.
    case finished(AgentResult)
}

/// Runs a prompt as an agent session.
public protocol AgentSession: Sendable {
    /// Starts the session and streams its events; cancelling the consumer stops the session.
    func run(_ r: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error>
}
