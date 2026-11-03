import Foundation

extension Run {
    /// Whether `key` can take a follow-up message: a finished Prompt or Judge step with a session, in a run that is
    /// waiting on the user, failed or completed. A Review is left out: a resumed turn sends only the message, so the
    /// reviewer would get no `VERDICT` instruction.
    public func canFollowUp(_ key: NodeKey) -> Bool {
        switch status {
        case .needsYou, .failed, .completed: break
        default: return false
        }
        guard let kind = flow.node(key.node)?.kind else { return false }
        switch kind {
        case .prompt, .judge: break
        default: return false
        }
        guard let node = nodes[key], node.state == .succeeded, node.sessionID != nil else { return false }
        return true
    }
}

extension RunEngine {
    /// Sends `message` to a finished Prompt or Judge step's agent session and re-runs everything downstream of it.
    ///
    /// Allowed when `Run.canFollowUp(node)` and the message is not empty after trimming; otherwise throws
    /// `notFollowable`. The step resumes its own session with the trimmed message as the prompt; its output, and
    /// that of every later step (and the recommendation), is cleared the way `retry` clears them. This never picks
    /// or merges anything: the run stops at the pick again.
    public func followUp(_ id: RunID, node: NodeKey, message: String) throws {
        guard runs[id] != nil else { throw RunEngineError.unknownRun(id) }
        try ensureLock(id)
        defer { releaseLockIfIdle(id) }
        let reply = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let run = runs[id], !picking.contains(id), !deciding.contains(id), !reply.isEmpty,
              run.canFollowUp(node) else { throw RunEngineError.notFollowable(node) }
        guard let plan = try? run.flow.validate() else { throw RunEngineError.notFollowable(node) }
        try clearSuspension(id)

        mutate(id) { run in
            resetForRerun(node, plan: plan, in: &run)
            run.nodes[node]?.pendingReply = reply
            run.status = .running
        }
        requestPass(id)
    }
}
