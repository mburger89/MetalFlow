import Foundation

extension Run {
    /// Whether `key` can take a follow-up message: a finished Prompt or Judge step with a session that is not before the candidates split, in a run that is
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
        // A step before the candidates split would reset every lane and restart them on worktrees that already hold
        // the earlier attempt's commits.
        guard let plan = try? flow.validate() else { return false }
        if key.lane == nil {
            var children: [NodeID: [NodeID]] = [:]
            for w in flow.wires { children[w.from, default: []].append(w.to) }
            var seen = Set<NodeID>()
            var stack = [key.node]
            while let n = stack.popLast() {
                for c in children[n] ?? [] where seen.insert(c).inserted { stack.append(c) }
            }
            if !seen.isDisjoint(with: plan.laneScoped) { return false }
        }
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
            let recommendation = run.recommendation
            let previousOutput = run.nodes[node]?.output
            let pickWasOffered = pickNodeKey(run).map { key in
                if case .needsYou(.pickWinner)? = run.nodes[key]?.state { true } else { false }
            } ?? false
            resetForRerun(node, plan: plan, in: &run)
            run.nodes[node]?.pendingReply = reply
            run.nodes[node]?.followUpMessage = reply
            run.nodes[node]?.appendLog("↩ follow-up: " + reply.prefix(200))
            if case .judge? = run.flow.node(node.node)?.kind {
                // A question put to the judge does not withdraw its verdict.
                run.recommendation = recommendation
                run.nodes[node]?.followUpBase = FollowUpBase(previousOutput: previousOutput ?? "", message: reply)
            }
            run.followedUp = true
            run.pickToRestore = nil
            // A pick still waiting on the user would stop the pass before it reached a step that does not feed the
            // pick; it asks again once the pass gets there.
            if pickWasOffered, let pickNode = pickNodeKey(run) {
                run.nodes[pickNode]?.state = .waiting
                // If this step fails the pick is offered again, since no candidate changed.
                if node.lane == nil { run.pickToRestore = node }
            }
            run.status = .running
        }
        requestPass(id)
    }
}
