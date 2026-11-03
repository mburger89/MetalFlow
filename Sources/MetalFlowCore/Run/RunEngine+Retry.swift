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
        guard let run = runs[id], !picking.contains(id), !deciding.contains(id),
              case .failed? = run.nodes[node]?.state else { throw RunEngineError.notRetryable(node) }
        switch run.status {
        case .needsYou, .failed, .completed: break
        default: throw RunEngineError.notRetryable(node)
        }
        guard let plan = try? run.flow.validate() else { throw RunEngineError.notRetryable(node) }
        try clearSuspension(id)

        mutate(id) { run in
            // A step whose failure left the pick on offer (see `followUp`) gives it back if it fails again.
            let pickWasOffered = pickNodeKey(run).map { key in
                if case .needsYou(.pickWinner)? = run.nodes[key]?.state { true } else { false }
            } ?? false
            resetForRerun(node, plan: plan, in: &run)
            run.pickToRestore = pickWasOffered && node.lane == nil ? node : nil
            run.status = .running
        }
        requestPass(id)
    }

    /// Sends `node` and everything downstream of it back to `.waiting` with outputs cleared (see `retry`). The node keeps its
    /// `sessionID` and `pendingReply`; the run's status is left to the caller.
    func resetForRerun(_ node: NodeKey, plan: FlowPlan, in run: inout Run) {
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

        if var retried = run.nodes[node] {
            retried.state = .waiting
            retried.output = nil
            retried.startedAt = nil
            retried.endedAt = nil
            retried.fixAttemptsUsed = 0
            run.nodes[node] = retried
        }
        for key in keys where run.nodes[key] != nil {
            let old = run.nodes[key]
            run.nodes[key] = NodeRun(extraAllowedTools: old?.extraAllowedTools ?? [], costUSD: old?.costUSD ?? 0)
        }
        let resetLanes = Set(keys.compactMap(\.lane) + (node.lane.map { [$0] } ?? []))
        for index in run.lanes.indices where resetLanes.contains(run.lanes[index].id) {
            // A reset gate re-measures the lane and a reset review has no verdict; ones that did not reset keep theirs.
            func reset(_ isKind: (NodeKind) -> Bool) -> Bool {
                (Array(keys) + [node]).contains { key in
                    guard key.lane == run.lanes[index].id, let kind = run.flow.node(key.node)?.kind else { return false }
                    return isKind(kind)
                }
            }
            if reset({ if case .gate = $0 { true } else { false } }) {
                run.lanes[index].gatePassed = nil
                run.lanes[index].added = 0
                run.lanes[index].removed = 0
            }
            if reset({ if case .review = $0 { true } else { false } }) { run.lanes[index].reviewPassed = nil }
        }
        // The recommendation is stale only when the judge runs again.
        let judgeResets = (Array(keys) + [node]).contains { key in
            if case .judge? = run.flow.node(key.node)?.kind { return true }
            return false
        }
        // A judge answering a follow-up keeps the verdict it had, even when its turn is retried.
        if judgeResets && run.nodes[node]?.followUpBase == nil { run.recommendation = nil }
        // A pick that is reset must be made again.
        if let pickNode = pickNodeKey(run), keys.contains(pickNode) { run.pickedLane = nil }
    }

    /// The `.flow` files in `<repo>/.flows`, sorted by file name; empty when the folder is missing.
    public nonisolated func flows(in repo: URL) -> [URL] { Self.flows(in: repo) }

    /// Same as the instance method, for callers that have no engine yet.
    public static func flows(in repo: URL) -> [URL] {
        let directory = repo.appendingPathComponent(FlowFile.directoryName, isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "flow" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

extension RunEngine {
    /// The unified diff of a lane's committed changes against the run's branch; empty when the run or lane is unknown,
    /// or a short "(diff unavailable: ...)" note when git fails.
    public func laneDiff(_ id: RunID, lane: LaneID) async -> String {
        guard let run = runs[id], let chosen = run.lanes.first(where: { $0.id == lane }) else { return "" }
        do {
            return try await git.diff(worktree: chosen.worktree, base: run.branch)
        } catch {
            return "(diff unavailable: \(error.localizedDescription))"
        }
    }
}
