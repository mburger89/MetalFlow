import Foundation

extension RunEngine {
    // MARK: - Answering

    /// Answers a paused agent node (question, denied tools) or resumes an interrupted one, and requests a pass.
    ///
    /// `allowTools` are added to the node's extra allowed tools for the resumed session.
    public func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String] = []) throws {
        guard runs[id] != nil else { throw RunEngineError.unknownRun(id) }
        try ensureLock(id)
        defer { releaseLockIfIdle(id) }
        guard let run = runs[id] else { throw RunEngineError.unknownRun(id) }
        switch run.status {
        case .cancelled, .merged, .discarded, .failed, .prOpened: throw RunEngineError.notAnswerable(node)
        default: break
        }
        guard !picking.contains(id) else { throw RunEngineError.notAnswerable(node) }
        guard let current = run.nodes[node] else { throw RunEngineError.notAnswerable(node) }
        switch current.state {
        case .needsYou(.question), .needsYou(.deniedTools), .interrupted: break
        default: throw RunEngineError.notAnswerable(node)
        }
        try clearSuspension(id)
        mutate(id) { run in
            var n = run.nodes[node] ?? NodeRun()
            n.pendingReply = reply
            n.replyInFlight = nil
            for tool in allowTools where !n.extraAllowedTools.contains(tool) { n.extraAllowedTools.append(tool) }
            n.state = .waiting
            run.nodes[node] = n
            if run.status == .needsYou { run.status = .running }
        }
        requestPass(id)
    }

    /// What an interrupted node is told when it has no reply of its own to receive. It is not the user's words.
    static let continueNudge = "Continue where you left off."

    /// Resumes every interrupted node with "Continue where you left off." (or the reply it was still to receive). A run that stopped between nodes (nothing
    /// interrupted, nothing waiting on you) simply continues. Throws `nothingToResume` when there is nothing to do.
    public func resumeInterrupted(_ id: RunID) throws {
        guard runs[id] != nil else { throw RunEngineError.unknownRun(id) }
        try ensureLock(id)
        defer { releaseLockIfIdle(id) }
        guard let run = runs[id] else { throw RunEngineError.unknownRun(id) }
        let keys = run.nodes.filter { $0.value.state == .interrupted }.map(\.key)
            .sorted { $0.description < $1.description }
        guard !keys.isEmpty else {
            // The process died between nodes: the run reloaded as needs-you but nothing is waiting on the user.
            guard run.status == .needsYou, run.needsYou.isEmpty, !picking.contains(id) else {
                throw RunEngineError.nothingToResume
            }
            try clearSuspension(id)
            mutate(id) { $0.status = .running }
            requestPass(id)
            return
        }
        for key in keys {
            // A reply that never reached the agent (a fix turn cut short before it started) must not be lost.
            let reply = run.nodes[key]?.pendingReply ?? Self.continueNudge
            let carrying = run.nodes[key]?.replyInFlight
            try answer(id, node: key, reply: reply)
            // The turn being resumed was carrying a message: it stays in flight until the turn finishes cleanly.
            if carrying != nil { updateNode(id, key) { $0.replyInFlight = carrying } }
        }
    }

    // MARK: - Picking

    /// Merges a candidate into the base branch. Only a successful merge changes the run; otherwise the
    /// result (blocked by local changes, or conflicting files) is returned for the UI to show.
    ///
    /// When the flow has an Open PR node nothing is merged: the choice is recorded in `Run.pickedLane`, the pick
    /// node succeeds, the run carries on to push the branch and open the pull request, and `.handedToPullRequest`
    /// is returned straight away. Follow the run (`waitUntilSettled`, `updates`) for the outcome.
    ///
    /// `expectedRevision` is the revision of the run the caller is showing. If the run has moved on since (another
    /// process saved it, for one), nothing is picked and `runChanged` is thrown, so a choice made on a stale card
    /// cannot merge another candidate than the one shown. `nil` skips the check.
    public func pick(_ id: RunID, lane: LaneID, expectedRevision: Int? = nil) async throws -> MergeResult {
        guard runs[id] != nil else { throw RunEngineError.notPickable }
        try ensureLock(id)
        defer { releaseLockIfIdle(id) }
        await waitForPass(id)
        if let expectedRevision, let current = runs[id], current.revision != expectedRevision {
            throw RunEngineError.runChanged
        }
        guard let run = runs[id], run.status == .needsYou, !picking.contains(id),
              let pickNode = pickNodeKey(run),
              case .needsYou(.pickWinner)? = run.nodes[pickNode]?.state,
              let chosen = run.lanes.first(where: { $0.id == lane }) else { throw RunEngineError.notPickable }
        picking.insert(id)
        defer { picking.remove(id) }
        if run.flow.hasOpenPR {
            try clearSuspension(id)
            setDirect(id) { run in
                run.pickedLane = lane
                run.nodes[pickNode]?.state = .succeeded
                run.nodes[pickNode]?.output = "chose \(lane)"
                run.nodes[pickNode]?.endedAt = Date()
                run.status = .running
            }
            requestPass(id)
            return .handedToPullRequest
        }
        // Unstructured so a cancelled caller cannot interrupt the status write and cleanup after a merge.
        return try await Task {
            let result = try await self.git.merge(
                repo: run.repo, branch: chosen.branch, into: run.baseBranch,
                message: "Merge \(run.title) (candidate \(lane), MetalFlow)")
            guard case .merged(let commit) = result else { return result }
            self.setDirect(id) { run in
                run.nodes[pickNode]?.state = .succeeded
                run.nodes[pickNode]?.output = "merged \(lane) as \(commit)"
                run.nodes[pickNode]?.endedAt = Date()
                run.status = .merged(lane)
            }
            await self.cleanup(id)
            return result
        }.value
    }

    func pickNodeKey(_ run: Run) -> NodeKey? { Self.pickNodeKey(in: run) }

    static func pickNodeKey(in run: Run) -> NodeKey? {
        run.flow.nodes.first { if case .pick = $0.kind { return true } else { return false } }
            .map { NodeKey(node: $0.id) }
    }

    // MARK: - Discarding

    /// Throws away the run: its worktrees and branches are removed (except kept branches).
    public func discard(_ id: RunID) async throws {
        guard runs[id] != nil else { throw RunEngineError.unknownRun(id) }
        try ensureLock(id)
        deciding.insert(id)
        defer {
            deciding.remove(id)
            releaseLockIfIdle(id)
        }
        // Let a cancelled pass finish first, so it cannot write after the discard.
        if runs[id]?.status == .cancelled || suspended.contains(id) { await waitForPass(id) }
        guard let run = runs[id] else { throw RunEngineError.unknownRun(id) }
        switch run.status {
        case .needsYou, .failed, .completed, .cancelled: break
        case .discarded, .merged, .prOpened: return
        case .running: throw RunEngineError.notDiscardable
        }
        guard !picking.contains(id) else { throw RunEngineError.notDiscardable }
        await Task {
            self.setDirect(id) { $0.status = .discarded }
            await self.cleanup(id)
        }.value
    }

    // MARK: - Branching

    /// Creates a local branch `name` at the head of the lane's branch. It survives discard and merge.
    public func branchFromHere(_ id: RunID, lane: LaneID, name: String) async throws {
        guard runs[id] != nil else { throw RunEngineError.unknownRun(id) }
        guard !name.hasPrefix("-"), try await git.isValidBranchName(name) else {
            throw RunEngineError.invalidBranchName(name)
        }
        try ensureLock(id)
        deciding.insert(id)
        defer {
            deciding.remove(id)
            releaseLockIfIdle(id)
        }
        guard let run = runs[id] else { throw RunEngineError.unknownRun(id) }
        switch run.status {
        case .merged, .discarded, .prOpened: throw RunEngineError.notBranchable
        default: break
        }
        guard let chosen = run.lanes.first(where: { $0.id == lane }) else { throw RunEngineError.unknownLane(lane) }
        try await git.createBranch(repo: run.repo, name: name, at: chosen.branch)
        setDirect(id) { run in
            if !run.keptBranches.contains(name) { run.keptBranches.append(name) }
        }
    }

    // MARK: - Cleanup

    /// Writes a change even to a cancelled run; used for terminal transitions the user asked for.
    func setDirect(_ id: RunID, _ body: (inout Run) -> Void) {
        guard var run = runs[id] else { return }
        body(&run)
        runs[id] = run
        persist(run)
    }

    /// Removes all worktrees and run/lane branches except kept ones, then prunes. Errors are logged on the run.
    func cleanup(_ id: RunID) async {
        guard let run = runs[id] else { return }
        var errors: [String] = []
        let fm = FileManager.default
        for path in run.lanes.map(\.worktree) + [run.worktree] {
            guard fm.fileExists(atPath: path.path) else { continue }
            do { try await git.removeWorktree(repo: run.repo, path: path) } catch {
                let text = error.localizedDescription
                if !text.contains("not a working tree") && !text.contains("not a worktree") { errors.append(text) }
            }
        }
        let existing = (try? await git.branches(repo: run.repo)) ?? []
        for branch in run.lanes.map(\.branch) + [run.branch]
        where existing.contains(branch) && !run.keptBranches.contains(branch) {
            do { try await git.deleteBranch(repo: run.repo, name: branch) } catch { errors.append(error.localizedDescription) }
        }
        let directory = store.worktreesDirectory.appendingPathComponent(id.rawValue)
        if fm.fileExists(atPath: directory.path) {
            do { try fm.removeItem(at: directory) } catch { errors.append(error.localizedDescription) }
        }
        do { try await git.pruneWorktrees(repo: run.repo) } catch { errors.append(error.localizedDescription) }
        if !errors.isEmpty {
            let key = pickNodeKey(run) ?? run.flow.nodes.first.map { NodeKey(node: $0.id) }
            setDirect(id) { run in
                guard let key else { return }
                var node = run.nodes[key] ?? NodeRun()
                for e in errors { node.appendLog("cleanup: \(e)") }
                run.nodes[key] = node
            }
        }
    }
}
