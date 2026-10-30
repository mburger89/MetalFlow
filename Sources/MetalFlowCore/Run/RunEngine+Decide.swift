import Foundation

extension RunEngine {
    // MARK: - Answering

    /// Answers a paused agent node (question, denied tools) or resumes an interrupted one, and requests a pass.
    ///
    /// `allowTools` are added to the node's extra allowed tools for the resumed session.
    public func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String] = []) throws {
        guard let run = runs[id] else { throw RunEngineError.unknownRun(id) }
        switch run.status {
        case .cancelled, .merged, .discarded, .failed: throw RunEngineError.notAnswerable(node)
        default: break
        }
        guard !picking.contains(id) else { throw RunEngineError.notAnswerable(node) }
        guard let current = run.nodes[node] else { throw RunEngineError.notAnswerable(node) }
        switch current.state {
        case .needsYou(.question), .needsYou(.deniedTools), .interrupted: break
        default: throw RunEngineError.notAnswerable(node)
        }
        mutate(id) { run in
            var n = run.nodes[node] ?? NodeRun()
            n.pendingReply = reply
            for tool in allowTools where !n.extraAllowedTools.contains(tool) { n.extraAllowedTools.append(tool) }
            n.state = .waiting
            run.nodes[node] = n
            if run.status == .needsYou { run.status = .running }
        }
        requestPass(id)
    }

    /// Resumes every interrupted node with "Continue where you left off."; throws if there is none.
    public func resumeInterrupted(_ id: RunID) throws {
        guard let run = runs[id] else { throw RunEngineError.unknownRun(id) }
        let keys = run.nodes.filter { $0.value.state == .interrupted }.map(\.key)
            .sorted { $0.description < $1.description }
        guard !keys.isEmpty else { throw RunEngineError.nothingToResume }
        for key in keys { try answer(id, node: key, reply: "Continue where you left off.") }
    }

    // MARK: - Picking

    /// Merges a candidate into the base branch. Only a successful merge changes the run; otherwise the
    /// result (blocked by local changes, or conflicting files) is returned for the UI to show.
    public func pick(_ id: RunID, lane: LaneID) async throws -> MergeResult {
        await waitForPass(id)
        guard let run = runs[id], run.status == .needsYou, !picking.contains(id),
              let pickNode = pickNodeKey(run),
              case .needsYou(.pickWinner)? = run.nodes[pickNode]?.state,
              let chosen = run.lanes.first(where: { $0.id == lane }) else { throw RunEngineError.notPickable }
        picking.insert(id)
        defer { picking.remove(id) }
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

    private func pickNodeKey(_ run: Run) -> NodeKey? {
        run.flow.nodes.first { if case .pick = $0.kind { return true } else { return false } }
            .map { NodeKey(node: $0.id) }
    }

    // MARK: - Discarding

    /// Throws away the run: its worktrees and branches are removed (except kept branches).
    public func discard(_ id: RunID) async throws {
        guard runs[id] != nil else { throw RunEngineError.unknownRun(id) }
        // Let a cancelled pass finish first, so it cannot write after the discard.
        if runs[id]?.status == .cancelled { await waitForPass(id) }
        guard let run = runs[id] else { throw RunEngineError.unknownRun(id) }
        switch run.status {
        case .needsYou, .failed, .completed, .cancelled: break
        case .discarded, .merged: return
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
        guard let run = runs[id] else { throw RunEngineError.unknownRun(id) }
        switch run.status {
        case .merged, .discarded: throw RunEngineError.notBranchable
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
    private func cleanup(_ id: RunID) async {
        guard let run = runs[id] else { return }
        var errors: [String] = []
        let fm = FileManager.default
        for path in run.lanes.map(\.worktree) + [run.worktree] {
            guard fm.fileExists(atPath: path.path) else { continue }
            do { try await git.removeWorktree(repo: run.repo, path: path) } catch {
                let text = String(describing: error)
                if !text.contains("not a working tree") && !text.contains("not a worktree") { errors.append(text) }
            }
        }
        let existing = (try? await git.branches(repo: run.repo)) ?? []
        for branch in run.lanes.map(\.branch) + [run.branch]
        where existing.contains(branch) && !run.keptBranches.contains(branch) {
            do { try await git.deleteBranch(repo: run.repo, name: branch) } catch { errors.append(String(describing: error)) }
        }
        let directory = store.worktreesDirectory.appendingPathComponent(id.rawValue)
        if fm.fileExists(atPath: directory.path) {
            do { try fm.removeItem(at: directory) } catch { errors.append(String(describing: error)) }
        }
        do { try await git.pruneWorktrees(repo: run.repo) } catch { errors.append(String(describing: error)) }
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
