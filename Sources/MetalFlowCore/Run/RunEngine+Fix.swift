import Foundation

extension RunEngine {
    /// The message that sends the agent back to work after its gate failed. It keeps the gate's output, so the
    /// agent has the failure in front of it.
    static func fixMessage(command: String, exitCode: Int32, output: String) -> String {
        let shown = output.isEmpty ? "(no output)" : output
        return """
            The command `\(command)` failed with exit code \(exitCode) after your changes. The end of its output:

            \(shown)

            Fix the problem so that the command passes. Change the code, not the command.
            """
    }

    /// The commit message for a lane agent's turn: the issue's title (the flow's name when there is none) and the lane,
    /// labelled as a fix attempt when a failing gate started the turn.
    static func laneCommitMessage(runTitle: String, flowName: String, lane: LaneID, nodeTitle: String,
                                  fix: PendingFix?) -> String {
        let name = commitName(runTitle: runTitle, flowName: flowName)
        guard let fix else { return "\(name) (\(lane))\n\nNode: \(nodeTitle)" }
        return "Fix attempt \(fix.attempt) of \(fix.total): \(name) (\(lane))\n\nNode: \(nodeTitle)\nGate: \(fix.command)"
    }

    /// What a run's commits and pull request are called: its title without `#N `, else the flow's name.
    static func commitName(runTitle: String, flowName: String) -> String {
        let title = pullRequestTitle(runTitle)
        return title.isEmpty ? flowName : title
    }

    /// The agent a failing gate sends back to work: the nearest prompt node upstream of the gate, through wires
    /// (breadth first), in the gate's own scope, that has a session to resume. A lane gate looks at its lane's nodes,
    /// any other gate at the nodes outside the lanes. Judges never count. Nil when there is none.
    static func fixingAgent(for gate: NodeKey, in run: Run, laneScoped: Set<NodeID>) -> NodeKey? {
        let inLane = gate.lane != nil
        var seen: Set<NodeID> = [gate.node]
        var queue = [gate.node]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for wire in run.flow.inputs(of: current)
            where laneScoped.contains(wire.from) == inLane && seen.insert(wire.from).inserted {
                if case .prompt? = run.flow.node(wire.from)?.kind {
                    let key = NodeKey(node: wire.from, lane: gate.lane)
                    if run.nodes[key]?.sessionID != nil { return key }
                }
                queue.append(wire.from)
            }
        }
        return nil
    }

    /// The nodes strictly between `agent` and `gate`: downstream of the agent and upstream of the gate.
    static func nodesBetween(agent: NodeID, gate: NodeID, flow: Flow) -> Set<NodeID> {
        func reach(from start: NodeID, forward: Bool) -> Set<NodeID> {
            var found: Set<NodeID> = []
            var stack = [start]
            while let n = stack.popLast() {
                let next = forward ? flow.wires.filter { $0.from == n }.map(\.to) : flow.wires.filter { $0.to == n }.map(\.from)
                for m in next where found.insert(m).inserted { stack.append(m) }
            }
            return found
        }
        return reach(from: agent, forward: true).intersection(reach(from: gate, forward: false)).subtracting([agent, gate])
    }

    /// Sends a failed gate's agent back to work and puts the gate (and what lies between) up for a rerun, when the
    /// gate has attempts left and an agent to resume. Returns false when it did nothing.
    func beginFix(_ id: RunID, _ gate: NodeKey, config: ShellConfig, command: String, exitCode: Int32,
                  output: String, plan: FlowPlan) -> Bool {
        guard let run = runs[id], run.status == .running, !suspended.contains(id) else { return false }
        let used = run.nodes[gate]?.fixAttemptsUsed ?? 0
        guard used < config.fixAttempts,
              let agentKey = Self.fixingAgent(for: gate, in: run, laneScoped: plan.laneScoped) else { return false }
        let message = Self.fixMessage(command: command, exitCode: exitCode, output: output)
        let between = Self.nodesBetween(agent: agentKey.node, gate: gate.node, flow: run.flow)
            .map { NodeKey(node: $0, lane: gate.lane) }
        mutate(id) { run in
            var agent = run.nodes[agentKey] ?? NodeRun()
            agent.pendingReply = message
            agent.pendingFix = PendingFix(attempt: used + 1, total: config.fixAttempts, command: command)
            agent.state = .waiting
            agent.endedAt = nil
            run.nodes[agentKey] = agent
            for key in between where run.nodes[key] != nil {
                let old = run.nodes[key]
                run.nodes[key] = NodeRun(extraAllowedTools: old?.extraAllowedTools ?? [], costUSD: old?.costUSD ?? 0)
            }
            var node = run.nodes[gate] ?? NodeRun()
            node.fixAttemptsUsed = used + 1
            node.state = .waiting
            node.endedAt = nil
            node.appendLog("✕ exit \(exitCode), fix \(used + 1) of \(config.fixAttempts)")
            run.nodes[gate] = node
            if let lane = gate.lane, let index = run.lanes.firstIndex(where: { $0.id == lane }) {
                run.lanes[index].gatePassed = nil
            }
        }
        requestPass(id)
        return true
    }
}
