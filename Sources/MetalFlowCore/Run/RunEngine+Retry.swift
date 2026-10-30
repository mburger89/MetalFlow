import Foundation

extension RunEngine {
    /// Re-runs a failed node and everything downstream of it, and requests a pass.
    ///
    /// Allowed when the node is `.failed` and the run is `.needsYou`, `.failed` or `.completed`; otherwise throws
    /// `notRetryable`. The node keeps its `sessionID` and `pendingReply` (a pending reply resumes the session,
    /// otherwise it starts fresh). Every node downstream of it goes back to `.waiting` with its output cleared:
    /// for a lane node that is the lane's later nodes plus the judge, pick and other after-lane nodes (the
    /// candidates changed, so the recommendation is stale); for a non-lane node, everything it feeds.
    public func retry(_ id: RunID, node: NodeKey) throws {
        guard runs[id] != nil else { throw RunEngineError.unknownRun(id) }
        try ensureLock(id)
        defer { releaseLockIfIdle(id) }
        guard let run = runs[id], !picking.contains(id),
              case .failed? = run.nodes[node]?.state else { throw RunEngineError.notRetryable(node) }
        switch run.status {
        case .needsYou, .failed, .completed: break
        default: throw RunEngineError.notRetryable(node)
        }
        guard let plan = try? run.flow.validate() else { throw RunEngineError.notRetryable(node) }

        var children: [NodeID: [NodeID]] = [:]
        for w in run.flow.wires { children[w.from, default: []].append(w.to) }
        var downstream = Set<NodeID>()
        var stack = [node.node]
        while let n = stack.popLast() {
            for c in children[n] ?? [] where downstream.insert(c).inserted { stack.append(c) }
        }
        if node.lane != nil {
            // Everything after the lanes (judge, pick, ...) depends on every candidate.
            var queue = Array(plan.laneScoped)
            while let n = queue.popLast() {
                for c in children[n] ?? [] where !plan.laneScoped.contains(c) && downstream.insert(c).inserted {
                    queue.append(c)
                }
            }
        }

        var keys = Set<NodeKey>()
        for d in downstream {
            if plan.laneScoped.contains(d) {
                if let lane = node.lane { keys.insert(NodeKey(node: d, lane: lane)) }
                else { for lane in run.lanes { keys.insert(NodeKey(node: d, lane: lane.id)) } }
            } else {
                keys.insert(NodeKey(node: d))
            }
        }
        keys.remove(node)

        mutate(id) { run in
            if var retried = run.nodes[node] {
                retried.state = .waiting
                retried.output = nil
                retried.startedAt = nil
                retried.endedAt = nil
                run.nodes[node] = retried
            }
            for key in keys where run.nodes[key] != nil {
                let old = run.nodes[key]
                run.nodes[key] = NodeRun(extraAllowedTools: old?.extraAllowedTools ?? [], costUSD: old?.costUSD ?? 0)
            }
            let resetLanes = Set(keys.compactMap(\.lane) + (node.lane.map { [$0] } ?? []))
            for index in run.lanes.indices where resetLanes.contains(run.lanes[index].id) {
                // A reset gate re-measures the lane; one that did not reset keeps its numbers.
                let gateReset = (Array(keys) + [node]).contains { key in
                    guard key.lane == run.lanes[index].id, case .gate? = run.flow.node(key.node)?.kind else { return false }
                    return true
                }
                if gateReset {
                    run.lanes[index].gatePassed = nil
                    run.lanes[index].added = 0
                    run.lanes[index].removed = 0
                }
            }
            run.recommendation = nil
            run.status = .running
        }
        requestPass(id)
    }

    /// The `.flow` files in `<repo>/.flows`, sorted by file name; empty when the folder is missing.
    public nonisolated func flows(in repo: URL) -> [URL] {
        let directory = repo.appendingPathComponent(".flows", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "flow" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
