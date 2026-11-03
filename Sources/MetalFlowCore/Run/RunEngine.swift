import Foundation

/// Failures of run engine operations.
public enum RunEngineError: Error, Equatable {
    /// The repository has a detached HEAD, so there is no base branch to start from.
    case detachedHead
    /// No run with this ID is known to the engine.
    case unknownRun(RunID)
    /// The flow failed validation.
    case invalid(FlowError)
    /// A fan-out node lists more candidates than there are lane letters (26).
    case tooManyCandidates(Int)
    /// The node is not waiting on a question, denied tools or an interruption, or the run is over.
    case notAnswerable(NodeKey)
    /// The run is not waiting for a winner, the lane does not exist, or a pick is already in progress.
    case notPickable
    /// The run is still running (or being picked); cancel it first.
    case notDiscardable
    /// The run has no lane with this ID.
    case unknownLane(LaneID)
    /// The run is already merged, discarded or has a pull request, so no branch can be made from it.
    case notBranchable
    /// Nothing is interrupted and nothing is waiting, so there is nothing to resume.
    case nothingToResume
    /// The run is busy: another engine (typically another `mflow` process) is working on it, or this engine
    /// suspended it and its stopped pass has not wound down yet. Try again in a moment.
    case runBusy(RunID)
    /// The name is not a valid git branch name.
    case invalidBranchName(String)
    /// The node has not failed, or the run is not in a state that can be retried.
    case notRetryable(NodeKey)
    /// The node is not a finished Prompt or Judge step of an open run.
    case notFollowable(NodeKey)
    /// The follow-up could not run yet: an earlier step is waiting on a question or was interrupted. The message says which.
    case followUpBlocked(String)
    /// The follow-up message is empty once trimmed.
    case emptyFollowUp
    /// The run was saved again since the caller last looked at it, so a choice made on what it showed may be wrong.
    case runChanged
    /// A launch field has no value and no default.
    case missingInput(String)
    /// The value given for the repo differs from the repo the flow is bound to.
    case repoMismatch(expected: URL)
    /// The flow cannot be launched from where it is.
    case launch(LaunchError)
}

extension RunEngineError: LocalizedError {
    /// A readable message.
    public var errorDescription: String? {
        switch self {
        case .detachedHead: return "the repository has a detached HEAD; check out a branch first"
        case .unknownRun(let id): return "no run \(id.rawValue)"
        case .invalid(let error): return "the flow is not valid: \(error.localizedDescription)"
        case .tooManyCandidates(let n): return "a fan-out lists \(n) candidates; at most 26 are supported"
        case .notAnswerable(let key): return "\(key) is not waiting for an answer (or the run is over)"
        case .notPickable: return "the run is not waiting for a winner, the lane does not exist, or a pick is in progress"
        case .notDiscardable: return "the run is still running; cancel it first"
        case .unknownLane(let lane): return "the run has no lane '\(lane)'"
        case .notBranchable: return "the run is already merged, discarded or has a pull request"
        case .nothingToResume: return "nothing to resume: no node is interrupted or waiting"
        case .runBusy(let id): return "run \(id.rawValue) is busy: running in another mflow, or still stopping"
        case .invalidBranchName(let name): return "'\(name)' is not a valid branch name"
        case .notRetryable(let key): return "\(key) cannot be retried: it has not failed, or the run is busy or over"
        case .notFollowable: return "Only a finished Prompt or Judge step of an open run can take a follow-up, and not a step before the candidates split."
        case .followUpBlocked(let message): return message
        case .emptyFollowUp: return "Type a message to send."
        case .runChanged: return "This run changed since you last saw it. Look again before picking."
        case .missingInput(let name): return "'\(name)' needs a value"
        case .repoMismatch(let expected): return "this flow always runs on \(expected.path)"
        case .launch(let error): return error.localizedDescription
        }
    }
}

/// Executes flow runs as headless agent sessions in git worktrees.
public actor RunEngine {
    /// Every saved run state, in order. One shared stream; consumers filter by run ID.
    public nonisolated let updates: AsyncStream<Run>

    /// The message of the last failed attempt to save a run, cleared by the next successful save.
    public private(set) var lastSaveError: String?

    let continuation: AsyncStream<Run>.Continuation
    let store: RunStore
    let runner: any CommandRunner
    let agent: any AgentSession
    let issues: GitHubIssues
    let pullRequests: GitHubPullRequests
    let git: Git
    let limiter: SessionLimiter
    let shellEnvironment: [String: String]

    var runs: [RunID: Run] = [:]
    var tasks: [RunID: Task<Void, Never>] = [:]
    var rerunRequested: Set<RunID> = []
    /// Runs suspended for quit: `mutate` ignores them until `resumeInterrupted` or `answer` clears the mark.
    var suspended: Set<RunID> = []
    var picking: Set<RunID> = []
    /// Run locks this engine holds: while a pass, pick, discard or branch is in progress for the run.
    var locks: [RunID: RunLock] = [:]
    /// Operations (discard, branch) that need the run lock but have no task of their own.
    var deciding: Set<RunID> = []
    /// Background cleanups started by `restore()`.
    var restoreCleanups: [Task<Void, Never>] = []

    /// Creates an engine. `shellEnvironment` is merged into the environment of shell and gate nodes.
    public init(store: RunStore, runner: any CommandRunner, agent: any AgentSession, issues: GitHubIssues,
                maxSessions: Int = RunSettings.defaultMaxSessions, shellEnvironment: [String: String] = [:]) {
        self.store = store
        self.runner = runner
        self.agent = agent
        self.issues = issues
        self.pullRequests = GitHubPullRequests(runner: runner)
        self.git = Git(runner: runner)
        self.limiter = SessionLimiter(max: maxSessions)
        self.shellEnvironment = shellEnvironment
        (updates, continuation) = AsyncStream.makeStream(of: Run.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Changes how many agent sessions run at once; takes effect for waiting and future sessions.
    public func setMaxSessions(_ max: Int) async { await limiter.setMax(max) }

    /// Loads persisted runs into memory and returns them; does not start any run.
    ///
    /// A merged, discarded or pull-request run whose worktree folder still exists (the process died during cleanup) has its
    /// cleanup finished in the background; that work is not cancellable.
    public func restore() throws -> [Run] {
        let loaded = try store.loadAll()
        for run in loaded {
            runs[run.id] = run
            switch run.status {
            case .merged, .discarded, .prOpened:
                let directory = store.worktreesDirectory.appendingPathComponent(run.id.rawValue)
                if FileManager.default.fileExists(atPath: directory.path) {
                    let id = run.id
                    restoreCleanups.append(Task { await self.finishInterruptedCleanup(id) })
                }
            default: break
            }
        }
        return loaded
    }

    /// Waits for the cleanups that `restore()` started.
    func waitForRestoreCleanups() async {
        for task in restoreCleanups { await task.value }
    }

    private func finishInterruptedCleanup(_ id: RunID) async {
        guard (try? ensureLock(id)) != nil else { return }
        deciding.insert(id)
        defer {
            deciding.remove(id)
            releaseLockIfIdle(id)
        }
        await cleanup(id)
    }

    /// The current state of a run.
    public func run(_ id: RunID) -> Run? { runs[id] }

    /// Starts a run of `flow` and returns immediately; execution continues in the background.
    /// Fields with no value fall back to their default, then fail with `missingInput`.
    public func launch(flow: Flow, location: FlowLocation, values: [String: String]) async throws -> RunID {
        let fields: [LaunchField]
        do { fields = try flow.launchFields(location: location) } catch { throw RunEngineError.launch(error) }
        let plan: FlowPlan
        do { plan = try flow.validate() } catch { throw RunEngineError.launch(.invalid(error)) }
        if let fan = plan.fanOut, case .prompt(let c)? = flow.node(fan)?.kind, c.candidates.count > 26 {
            throw RunEngineError.tooManyCandidates(c.candidates.count)
        }

        guard case .repo(let repoConfig)? = flow.repoNodes.first?.kind else { throw RunEngineError.launch(.noRepoNode) }
        let repoPath: String
        switch repoConfig.mode {
        case .thisRepo:
            guard case .repo(let root, _) = location else { throw RunEngineError.launch(.thisRepoOutsideRepo) }
            repoPath = root.path
        case .fixed(let path):
            repoPath = path
        case .exposed(let d):
            guard let chosen = values["repo"] ?? d else { throw RunEngineError.missingInput("repo") }
            repoPath = chosen
        }
        let repo = URL(fileURLWithPath: repoPath)
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        if case .exposed = repoConfig.mode {} else if let given = values["repo"], resolved(given) != resolved(repoPath) {
            throw RunEngineError.repoMismatch(expected: repo)
        }

        var inputs: [String: String] = [:]
        for field in fields {
            guard let value = values[field.name] ?? field.defaultValue else { throw RunEngineError.missingInput(field.name) }
            inputs[field.name] = value
        }

        let base = try await git.currentBranch(repo: repo)
        guard base != "HEAD" else { throw RunEngineError.detachedHead }

        var issue: Issue?
        var title = flow.name
        var firstNodes: [(NodeKey, NodeRun)] = []
        var isFirst = true
        for id in plan.order {
            guard let node = flow.node(id), case .flowInput(let config) = node.kind else { continue }
            let input: String
            switch config.binding {
            case .fixed(let v):
                input = v
                inputs[config.name] = v
            case .exposed:
                input = inputs[config.name] ?? ""
            }
            let output: String
            let fetched: Issue?
            switch config.source {
            case .githubIssue:
                let f = try await issues.fetch(input, repo: repo)
                fetched = f
                output = f.promptText
            case .text:
                fetched = nil
                output = input
            }
            if isFirst {
                isFirst = false
                if let fetched {
                    issue = fetched
                    title = "#\(fetched.number) \(fetched.title)"
                } else {
                    title = String(input.prefix(60))
                }
            }
            let now = Date()
            firstNodes.append((NodeKey(node: node.id), NodeRun(state: .succeeded, output: output, startedAt: now, endedAt: now)))
        }

        let branch = BranchNaming.runBranch(
            issue: issue?.number, title: issue?.title ?? title, existing: try await git.branches(repo: repo))
        let id = RunID()
        try ensureLock(id)
        defer { releaseLockIfIdle(id) }
        let worktree = store.worktreesDirectory.appendingPathComponent(id.rawValue).appendingPathComponent("run")
        try store.addKnownRepo(repo)
        try await git.addWorktree(repo: repo, path: worktree, newBranch: branch, from: base)

        var run = Run(id: id, flow: flow, title: title, repo: repo, baseBranch: base, branch: branch,
                      worktree: worktree, inputs: inputs, flowFile: location.file)
        for (key, node) in firstNodes { run.nodes[key] = node }
        runs[id] = run
        persist(run)
        requestPass(id)
        return id
    }

    /// Cancels a running run: stops its task, marks running nodes and the run cancelled. Worktrees are kept.
    /// A run that is not `.running` (waiting for you, completed, failed, merged...) is left alone.
    ///
    /// A run that has had a follow-up is suspended instead (see `suspend`): cancelling it would lose the pick it
    /// was waiting at, so it ends waiting for you with the running step interrupted, to resume or discard.
    public func cancel(_ id: RunID) {
        // Only a run this engine drives: a running run whose lock another process holds is not ours to touch.
        guard var run = runs[id], run.status == .running, locks[id] != nil else { return }
        if run.followedUp {
            suspend(id)
            return
        }
        tasks[id]?.cancel()
        rerunRequested.remove(id)
        let now = Date()
        for (key, node) in run.nodes where node.state == .running {
            run.nodes[key]?.state = .cancelled
            run.nodes[key]?.endedAt = now
        }
        run.status = .cancelled
        runs[id] = run
        persist(run)
    }

    /// Suspends a running run, for quitting: stops its task (and so its agent and shell processes) like `cancel`,
    /// but saves the run as `markingCutShort()` (running nodes interrupted, the run waiting for you) so it can be
    /// resumed with `resumeInterrupted`. Writes from the stopped pass are ignored until the run is resumed or
    /// answered. A run that is not `.running`, or not driven by this engine, is left alone.
    public func suspend(_ id: RunID) {
        guard let run = runs[id], run.status == .running, locks[id] != nil else { return }
        tasks[id]?.cancel()
        rerunRequested.remove(id)
        suspended.insert(id)
        persistForced(run.markingCutShort())
        // Nothing is driving the run any more: another process may take it. Lock-free even while the stopped
        // pass winds down, since its writes are ignored.
        locks.removeValue(forKey: id)?.release()
    }

    /// Ends a run's suspension so `mutate` writes again. Throws `runBusy` while the suspended run's old pass is
    /// still winding down: its late writes must stay ignored, and a new pass could not start beside it.
    func clearSuspension(_ id: RunID) throws {
        guard suspended.contains(id) else { return }
        guard tasks[id] == nil else { throw RunEngineError.runBusy(id) }
        suspended.remove(id)
    }

    /// Saves a run bypassing `mutate`'s guards.
    private func persistForced(_ run: Run) { persist(run) }

    // MARK: - Run locks

    /// Takes the run's lock unless this engine already holds it; throws `runBusy` when another engine has it.
    func ensureLock(_ id: RunID) throws {
        if locks[id] != nil { return }
        guard let lock = store.tryLock(id) else { throw RunEngineError.runBusy(id) }
        locks[id] = lock
        // Another engine may have changed the run since this one loaded it; never act on a stale snapshot.
        // Holding the lock means nobody drives the run, so work still marked running was cut short.
        if let fresh = store.load(id)?.markingCutShort(), fresh.revision >= (runs[id]?.revision ?? 0) {
            let newer = fresh.revision > (runs[id]?.revision ?? -1)
            runs[id] = fresh
            // Only news if another engine saved since; an identical snapshot would look like a settled state.
            if newer { continuation.yield(fresh) }
        }
    }

    /// Releases the lock once nothing is working on the run.
    func releaseLockIfIdle(_ id: RunID) {
        guard tasks[id] == nil, !picking.contains(id), !deciding.contains(id) else { return }
        locks.removeValue(forKey: id)?.release()
    }

    /// True when another engine or process holds the run's lock, so its saved state may be changing under us.
    public func isRunningElsewhere(_ id: RunID) -> Bool {
        locks[id] == nil && store.isLocked(id)
    }

    /// The newest known state of a run. A run this engine drives is returned as held. Otherwise the saved state
    /// replaces the cached one when its revision is higher (another process has been working on it). Nothing is yielded
    /// on `updates`: the caller applies the result.
    public func reload(_ id: RunID) -> Run? {
        if locks[id] != nil { return runs[id] }
        // A run cached as running that nobody here drives may have lost its driver after the last save the cache saw.
        // Only such a run is lock-probed when nothing newer was saved; an idle one never is.
        let driverGone = tasks[id] == nil && runs[id]?.status == .running && !store.isLocked(id)
        guard let saved = store.load(id) else { return runs[id] }
        if let cached = runs[id], saved.revision <= cached.revision {
            guard driverGone else { return cached }
            let cut = cached.markingCutShort()
            runs[id] = cut
            return cut
        }
        // Saved as running with nobody holding the lock: the process that drove it died.
        let shown = store.isLocked(id) ? saved : saved.markingCutShort()
        runs[id] = shown
        return shown
    }

    /// What one `discover()` pass learned about the store.
    public struct Discovery: Sendable, Equatable {
        /// Runs saved by another process that this engine had not seen; now cached.
        public var found: [Run]
        /// Cached runs whose file is gone (another process deleted them); now dropped from the cache.
        public var vanished: [RunID]
        public init(found: [Run] = [], vanished: [RunID] = []) {
            self.found = found
            self.vanished = vanished
        }
    }

    /// Compares the store with the cache. Runs saved by another process that this engine has not seen are cached and
    /// reported as found; a file that cannot be read yet is skipped and retried on a later pass. Cached runs whose file
    /// is gone are dropped and reported as vanished, unless this engine holds them (a lock or a pass). Takes no locks
    /// and leaves known runs alone.
    public func discover() -> Discovery {
        var discovery = Discovery()
        let saved = Set(store.ids())
        for id in saved where runs[id] == nil {
            guard let run = store.load(id) else { continue }
            runs[id] = run
            discovery.found.append(run)
        }
        for id in runs.keys where !saved.contains(id) && locks[id] == nil && tasks[id] == nil {
            runs[id] = nil
            discovery.vanished.append(id)
        }
        return discovery
    }

    // MARK: - State

    func persist(_ run: Run) {
        var run = run
        run.revision += 1
        runs[run.id] = run
        do {
            try store.save(run)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
        continuation.yield(run)
    }

    /// Applies a change and saves it. Ignored once the run is cancelled, merged, discarded or has a pull request, so work finishing late cannot undo it.
    func mutate(_ id: RunID, _ body: (inout Run) -> Void) {
        guard var run = runs[id], !suspended.contains(id) else { return }
        switch run.status {
        case .cancelled, .merged, .discarded, .prOpened: return
        default: break
        }
        body(&run)
        runs[id] = run
        persist(run)
    }

    func updateNode(_ id: RunID, _ key: NodeKey, _ body: (inout NodeRun) -> Void) {
        mutate(id) { run in
            var node = run.nodes[key] ?? NodeRun()
            body(&node)
            run.nodes[key] = node
        }
    }

    func nodeState(_ id: RunID, _ key: NodeKey) -> NodeState {
        runs[id]?.nodes[key]?.state ?? .waiting
    }

    // MARK: - Passes

    /// Starts an execution pass, or asks the live one to loop once more when it ends.
    func requestPass(_ id: RunID) {
        if tasks[id] != nil {
            rerunRequested.insert(id)
            return
        }
        tasks[id] = Task { await self.passLoop(id) }
    }

    private func passLoop(_ id: RunID) async {
        repeat {
            rerunRequested.remove(id)
            do {
                try await execute(id)
            } catch is CancellationError {
            } catch {
                mutate(id) { $0.status = .failed(error.localizedDescription) }
            }
            finalize(id)
        } while rerunRequested.contains(id) && !Task.isCancelled
        tasks[id] = nil
        releaseLockIfIdle(id)
    }

    /// Settles the run's status after a pass.
    private func finalize(_ id: RunID) {
        restorePick(id)
        guard let run = runs[id], run.status == .running, !rerunRequested.contains(id) else { return }
        if !run.needsYou.isEmpty || hasInterrupted(run) {
            mutate(id) { $0.status = .needsYou }
            return
        }
        // The last failed step in flow order names the failure, not whichever the dictionary lists first.
        for key in run.orderedNodeKeys.reversed() where key.lane == nil {
            if case .failed(let message)? = run.nodes[key]?.state {
                mutate(id) { $0.status = .failed(message) }
                return
            }
        }
        // The pass ended with nothing runnable left and nothing waiting on the user; failed lanes count as finished.
        mutate(id) { $0.status = .completed }
    }

    /// After a follow-up to a step that does not belong to a candidate: the pick that waited before it waits again if a
    /// step outside the candidates failed, since no candidate changed. Done once the pick is no longer waiting. While a
    /// later step is parked (on a question, say) nothing is decided: once answered it can still fail.
    private func restorePick(_ id: RunID) {
        guard let run = runs[id], run.status == .running, !rerunRequested.contains(id),
              run.pickToRestore != nil, let pickNode = pickNodeKey(run),
              let pickState = run.nodes[pickNode]?.state else { return }
        if pickState != .waiting {
            mutate(id) { $0.pickToRestore = nil }
            return
        }
        guard run.nodes.contains(where: { $0.key.lane == nil && $0.value.state.isFailed }) else { return }
        mutate(id) { run in
            run.nodes[pickNode]?.state = Self.pickWaiting(lanes: run.lanes, recommendation: run.recommendation)
            run.pickToRestore = nil
        }
    }

    /// True while any node is interrupted: it waits for an explicit answer or resume, never restarts on its own.
    func hasInterrupted(_ run: Run) -> Bool {
        run.nodes.values.contains { $0.state == .interrupted }
    }

    /// Suspends until the run's background execution (including a pass interrupted by `cancel`) has fully ended.
    public func waitUntilSettled(_ id: RunID) async { await waitForPass(id) }

    /// Waits for the run's current execution pass (including any requested rerun) to end.
    func waitForPass(_ id: RunID) async {
        if let task = tasks[id] { await task.value }
    }

    private func execute(_ id: RunID) async throws {
        guard let initial = runs[id] else { throw RunEngineError.unknownRun(id) }
        if initial.status == .needsYou { mutate(id) { $0.status = .running } }
        guard let run = runs[id], run.status == .running else { return }
        let plan: FlowPlan
        do { plan = try run.flow.validate() } catch { throw RunEngineError.invalid(error) }
        let laneNodes = plan.order.filter { plan.laneScoped.contains($0) }

        // Non-lane nodes that feed lanes must run before them; the rest (judge, pick, ...) run after.
        var children: [NodeID: [NodeID]] = [:]
        for w in run.flow.wires { children[w.from, default: []].append(w.to) }
        var afterLanes = Set<NodeID>()
        var stack = Array(plan.laneScoped)
        while let n = stack.popLast() {
            for c in children[n] ?? [] where !plan.laneScoped.contains(c) && afterLanes.insert(c).inserted {
                stack.append(c)
            }
        }
        let nonLane = plan.order.filter { !plan.laneScoped.contains($0) }
        for nodeID in nonLane where !afterLanes.contains(nodeID) {
            guard try await runNonLane(id, nodeID, run: run, plan: plan) else { return }
        }
        if !laneNodes.isEmpty {
            try await runLaneGroup(id, plan: plan, nodes: laneNodes)
            if !(runs[id]?.needsYou.isEmpty ?? true) { return }
            // An interrupted lane node blocks the judge until it is resumed.
            if let current = runs[id], hasInterrupted(current) { return }
            // A lane answered during this pass is waiting again; the requested rerun finishes it before judge/pick.
            if rerunRequested.contains(id) || anyLaneCanProgress(id, nodes: laneNodes) { return }
            if !hasFinishedLane(id, nodes: laneNodes) {
                mutate(id) { $0.status = .failed("all candidates failed") }
                return
            }
        }
        for nodeID in nonLane where afterLanes.contains(nodeID) {
            guard try await runNonLane(id, nodeID, run: run, plan: plan) else { return }
        }
    }

    /// Runs a non-lane node unless already done; returns false when the pass must stop.
    private func runNonLane(_ id: RunID, _ nodeID: NodeID, run: Run, plan: FlowPlan) async throws -> Bool {
        try Task.checkCancellation()
        let key = NodeKey(node: nodeID)
        let isPick = { if case .pick = run.flow.node(nodeID)?.kind { return true } else { return false } }()
        switch nodeState(id, key) {
        case .succeeded: return true
        case .failed:
            // A step that failed a follow-up before the pick was made (the pick was offered again) must not stop the
            // pass that carries the pick on to Open PR.
            guard let current = runs[id], current.pickedLane != nil, !isOpenPR(run.flow, nodeID),
                  let pickNode = pickNodeKey(current), current.nodes[pickNode]?.state == .succeeded else { return false }
            return true
        case .needsYou where !isPick: return false
        case .interrupted: return false
        case .waiting where skipsAfterPick(id, nodeID):
            updateNode(id, key) { node in
                let note = "Skipped: the pick was made without this step."
                if !node.log.contains(note) { node.appendLog(note) }
            }
            return true
        default: break
        }
        await runNode(id, key, plan: plan)
        return nodeState(id, key) == .succeeded
    }

    /// True for a waiting step the pass leaves alone because the pick was made past a failed step: the pick has
    /// succeeded with a chosen lane, and the step is not downstream of the pick but either feeds it or depends on a failed
    /// step (it would run on blank input).
    private func skipsAfterPick(_ id: RunID, _ nodeID: NodeID) -> Bool {
        guard let run = runs[id], run.pickedLane != nil, let pickKey = pickNodeKey(run),
              run.nodes[pickKey]?.state == .succeeded else { return false }
        var children: [NodeID: [NodeID]] = [:], parents: [NodeID: [NodeID]] = [:]
        for w in run.flow.wires {
            children[w.from, default: []].append(w.to)
            parents[w.to, default: []].append(w.from)
        }
        func reach(_ start: NodeID, _ edges: [NodeID: [NodeID]]) -> Set<NodeID> {
            var seen = Set<NodeID>(), stack = [start]
            while let n = stack.popLast() { for c in edges[n] ?? [] where seen.insert(c).inserted { stack.append(c) } }
            return seen
        }
        if reach(pickKey.node, children).contains(nodeID) { return false }
        if reach(nodeID, children).contains(pickKey.node) { return true }
        return reach(nodeID, parents).contains { run.nodes[NodeKey(node: $0)]?.state.isFailed == true }
    }

    private func isOpenPR(_ flow: Flow, _ id: NodeID) -> Bool {
        if case .openPR? = flow.node(id)?.kind { return true } else { return false }
    }

    /// True when a lane is about to run again: its first node (in plan order) that has not succeeded is waiting.
    /// A lane stopped at a failed node is finished, even if later nodes of it were reset to waiting.
    func anyLaneCanProgress(_ id: RunID, nodes: [NodeID]) -> Bool {
        guard let run = runs[id] else { return false }
        return run.lanes.contains { lane in
            for node in nodes {
                let state = run.nodes[NodeKey(node: node, lane: lane.id)]?.state
                if state == .succeeded { continue }
                return state == .waiting
            }
            return false
        }
    }

    private func hasFinishedLane(_ id: RunID, nodes: [NodeID]) -> Bool {
        guard let run = runs[id] else { return false }
        return run.lanes.contains { lane in
            nodes.allSatisfy { run.nodes[NodeKey(node: $0, lane: lane.id)]?.state == .succeeded }
        }
    }

    // MARK: - Fan-out

    private func runLaneGroup(_ id: RunID, plan: FlowPlan, nodes: [NodeID]) async throws {
        try await ensureLanes(id, plan: plan)
        let laneIDs = runs[id]?.lanes.map(\.id) ?? []
        await withTaskGroup(of: Void.self) { group in
            for lane in laneIDs {
                group.addTask { await self.runLane(id, lane: lane, plan: plan, nodes: nodes) }
            }
        }
        try Task.checkCancellation()
    }

    private func runLane(_ id: RunID, lane: LaneID, plan: FlowPlan, nodes: [NodeID]) async {
        for node in nodes {
            if Task.isCancelled { return }
            let key = NodeKey(node: node, lane: lane)
            switch nodeState(id, key) {
            case .succeeded: continue
            case .failed, .needsYou, .interrupted: return
            default: break
            }
            await runNode(id, key, plan: plan)
            if nodeState(id, key) != .succeeded { return }
        }
    }

    /// Commits the run worktree and creates the worktree of every candidate lane that does not exist yet.
    /// Safe to repeat after a crash: lanes already recorded are kept, and a lane branch or worktree left behind
    /// by an interrupted attempt is adopted instead of recreated.
    func ensureLanes(_ id: RunID, plan: FlowPlan) async throws {
        guard let run = runs[id], let fan = plan.fanOut,
              case .prompt(let config)? = run.flow.node(fan)?.kind else { return }
        guard config.candidates.count <= 26 else { throw RunEngineError.tooManyCandidates(config.candidates.count) }
        if run.lanes.count >= config.candidates.count { return }
        if run.lanes.isEmpty {
            _ = try await git.commitAll(worktree: run.worktree, message: "MetalFlow: before fan-out")
        }
        for (index, model) in config.candidates.enumerated() {
            try Task.checkCancellation()
            let laneID = String(UnicodeScalar(UInt8(97 + index)))
            if runs[id]?.lanes.contains(where: { $0.id == laneID }) == true { continue }
            let branch = BranchNaming.laneBranch(run: run.branch, lane: laneID)
            let path = store.worktreesDirectory.appendingPathComponent(id.rawValue).appendingPathComponent(laneID)
            try await adoptOrAddWorktree(run: run, path: path, branch: branch)
            // Recorded even if the run was cancelled meanwhile, so cleanup can find the worktree.
            // A suspended run is not ours to write: the lock is gone. A later resume adopts the worktree.
            guard !suspended.contains(id), var current = runs[id] else { return }
            current.lanes.append(Lane(id: laneID, model: model, branch: branch, worktree: path))
            runs[id] = current
            persist(current)
        }
    }

    private func adoptOrAddWorktree(run: Run, path: URL, branch: String) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.appendingPathComponent(".git").path) { return }
        let existing = try await git.branches(repo: run.repo)
        if existing.contains(branch) {
            try await git.pruneWorktrees(repo: run.repo)
            try await git.addWorktree(repo: run.repo, path: path, existingBranch: branch)
        } else {
            try await git.addWorktree(repo: run.repo, path: path, newBranch: branch, from: run.branch)
        }
    }
}
