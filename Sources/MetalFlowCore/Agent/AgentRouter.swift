import Foundation

/// Sends requests for `ollama:` and `lmstudio:` models to a local session and everything else to Claude.
public struct AgentRouter: AgentSession {
    private let claude: AgentSession
    private let local: AgentSession

    /// Creates a router over a Claude session and a local-model session.
    public init(claude: AgentSession, local: AgentSession) {
        self.claude = claude
        self.local = local
    }

    /// Splits `ollama:name` or `lmstudio:name` at the first colon; nil for a Claude name or an empty model part.
    public static func split(model: String) -> (provider: String, model: String)? {
        guard let colon = model.firstIndex(of: ":") else { return nil }
        let provider = String(model[..<colon])
        let name = String(model[model.index(after: colon)...])
        guard provider == "ollama" || provider == "lmstudio", !name.isEmpty else { return nil }
        return (provider, name)
    }

    public func run(_ r: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        guard let parts = Self.split(model: r.model) else { return claude.run(r) }
        var routed = r
        routed.model = parts.model
        routed.provider = parts.provider
        return local.run(routed)
    }
}
