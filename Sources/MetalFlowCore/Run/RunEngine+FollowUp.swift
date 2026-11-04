import Foundation

extension RunEngine {
    /// Whether `node` can be sent a follow-up now: the run waits for a winner (needs you, with the pick node
    /// asking for one), and the node is a finished candidate agent, a prompt node inside a lane that succeeded and
    /// has a session to resume. Pure; `followUp` also refuses while a pick is in progress or the run is locked.
    public static func canFollowUp(_ run: Run, node: NodeKey) -> Bool {
        guard run.status == .needsYou,
              let lane = node.lane, run.lanes.contains(where: { $0.id == lane }),
              case .prompt? = run.flow.node(node.node)?.kind,
              let current = run.nodes[node], current.state == .succeeded, current.sessionID != nil,
              let pick = run.flow.nodes.first(where: { if case .pick = $0.kind { true } else { false } }),
              case .needsYou(.pickWinner)? = run.nodes[NodeKey(node: pick.id)]?.state else { return false }
        return true
    }

    /// Sends a finished candidate's agent a follow-up and requests a pass.
    ///
    /// The agent resumes its own session with `message`. Its lane's later nodes (gate, review) and every node after
    /// the fan-out (judge, pick, ...) are reset to run again; other lanes keep their results. Costs and fix budgets
    /// survive the reset. Throws `emptyFollowUp` for a blank message, `notFollowable` when `canFollowUp` is false or a
    /// pick is in progress, and `runBusy` when another engine holds the run.
    public func followUp(_ id: RunID, node: NodeKey, message: String) throws {
        guard runs[id] != nil else { throw RunEngineError.unknownRun(id) }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RunEngineError.emptyFollowUp }
        try ensureLock(id)
        defer { releaseLockIfIdle(id) }
        guard let run = runs[id], !picking.contains(id), !deciding.contains(id), Self.canFollowUp(run, node: node),
              let plan = try? run.flow.validate(), let lane = node.lane else { throw RunEngineError.notFollowable(node) }
        try clearSuspension(id)

        var children: [NodeID: [NodeID]] = [:]
        for w in run.flow.wires { children[w.from, default: []].append(w.to) }
        var downstream = Set<NodeID>()
        var stack = [node.node]
        while let n = stack.popLast() {
            for c in children[n] ?? [] where downstream.insert(c).inserted { stack.append(c) }
        }
        // Everything after the lanes (judge, pick, ...) depends on every candidate, this one included.
        var queue = Array(downstream.filter { !plan.laneScoped.contains($0) })
        while let n = queue.popLast() {
            for c in children[n] ?? [] where !plan.laneScoped.contains(c) && downstream.insert(c).inserted { queue.append(c) }
        }
        var keys = Set<NodeKey>()
        for d in downstream { keys.insert(NodeKey(node: d, lane: plan.laneScoped.contains(d) ? lane : nil)) }
        keys.remove(node)

        mutate(id) { run in
            var agent = run.nodes[node] ?? NodeRun()
            agent.pendingReply = text
            agent.pendingFollowUp = text
            agent.state = .waiting
            agent.endedAt = nil
            run.nodes[node] = agent
            // Budgets do not refill: a node downstream keeps its cost, extra tools and fixes used.
            for key in keys where run.nodes[key] != nil {
                let old = run.nodes[key]
                run.nodes[key] = NodeRun(extraAllowedTools: old?.extraAllowedTools ?? [], costUSD: old?.costUSD ?? 0,
                                         fixAttemptsUsed: old?.fixAttemptsUsed ?? 0)
            }
            if let index = run.lanes.firstIndex(where: { $0.id == lane }) {
                run.lanes[index].gatePassed = nil
                run.lanes[index].reviewPassed = nil
            }
            run.recommendation = nil
            run.status = .running
        }
        requestPass(id)
    }
}
