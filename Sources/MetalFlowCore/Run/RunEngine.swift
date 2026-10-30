import Foundation

/// Failures of run engine operations.
public enum RunEngineError: Error, Equatable {
    /// The repository has a detached HEAD, so there is no base branch to start from.
    case detachedHead
    /// The flow has more than one `flowInput` node.
    case multipleFlowInputs
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
    /// The run is already merged or discarded, so no branch can be made from it.
    case notBranchable
    /// No node of the run is interrupted.
    case nothingToResume
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
    let git: Git
    let limiter: SessionLimiter
    let shellEnvironment: [String: String]

    var runs: [RunID: Run] = [:]
    var tasks: [RunID: Task<Void, Never>] = [:]
    var rerunRequested: Set<RunID> = []
    var picking: Set<RunID> = []

    /// Creates an engine. `shellEnvironment` is merged into the environment of shell and gate nodes.
    public init(store: RunStore, runner: any CommandRunner, agent: any AgentSession, issues: GitHubIssues,
                maxSessions: Int = 4, shellEnvironment: [String: String] = [:]) {
        self.store = store
        self.runner = runner
        self.agent = agent
        self.issues = issues
        self.git = Git(runner: runner)
        self.limiter = SessionLimiter(max: maxSessions)
        self.shellEnvironment = shellEnvironment
        (updates, continuation) = AsyncStream.makeStream(of: Run.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Loads persisted runs into memory and returns them; does not start any execution.
    public func restore() throws -> [Run] {
        let loaded = try store.loadAll()
        for run in loaded { runs[run.id] = run }
        return loaded
    }

    /// The current state of a run.
    public func run(_ id: RunID) -> Run? { runs[id] }

    /// Starts a run of `flow` in `repo` and returns immediately; execution continues in the background.
    public func launch(flow: Flow, repo: URL, input: String) async throws -> RunID {
        let plan: FlowPlan
        do { plan = try flow.validate() } catch { throw RunEngineError.invalid(error) }
        if let fan = plan.fanOut, case .prompt(let c)? = flow.node(fan)?.kind, c.candidates.count > 26 {
            throw RunEngineError.tooManyCandidates(c.candidates.count)
        }
        let inputNodes = flow.nodes.compactMap { node -> (Node, FlowInputConfig)? in
            if case .flowInput(let c) = node.kind { return (node, c) }
            return nil
        }
        guard inputNodes.count <= 1 else { throw RunEngineError.multipleFlowInputs }

        let base = try await git.currentBranch(repo: repo)
        guard base != "HEAD" else { throw RunEngineError.detachedHead }

        var issue: Issue?
        var title = flow.name
        var inputs: [String: String] = [:]
        var firstNode: (NodeKey, NodeRun)?
        if let (node, config) = inputNodes.first {
            inputs[config.name] = input
            let output: String
            switch config.source {
            case .githubIssue:
                let fetched = try await issues.fetch(input, repo: repo)
                issue = fetched
                title = "#\(fetched.number) \(fetched.title)"
                output = fetched.promptText
            case .text:
                title = String(input.prefix(60))
                output = input
            }
            let now = Date()
            firstNode = (NodeKey(node: node.id), NodeRun(state: .succeeded, output: output, startedAt: now, endedAt: now))
        }

        let branch = BranchNaming.runBranch(
            issue: issue?.number, title: issue?.title ?? title, existing: try await git.branches(repo: repo))
        let id = RunID()
        let worktree = store.worktreesDirectory.appendingPathComponent(id.rawValue).appendingPathComponent("run")
        try await git.addWorktree(repo: repo, path: worktree, newBranch: branch, from: base)
        try store.addKnownRepo(repo)

        var run = Run(id: id, flow: flow, title: title, repo: repo, baseBranch: base, branch: branch,
                      worktree: worktree, inputs: inputs)
        if let (key, node) = firstNode { run.nodes[key] = node }
        runs[id] = run
        persist(run)
        requestPass(id)
        return id
    }

    /// Cancels the run: stops its task, marks running nodes and the run cancelled. Worktrees are kept.
    public func cancel(_ id: RunID) {
        guard var run = runs[id] else { return }
        switch run.status {
        case .merged, .discarded, .cancelled: return
        default: break
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

    // MARK: - State

    func persist(_ run: Run) {
        do {
            try store.save(run)
            lastSaveError = nil
        } catch {
            lastSaveError = String(describing: error)
        }
        continuation.yield(run)
    }

    /// Applies a change and saves it. Ignored once the run is cancelled, merged or discarded, so work finishing late cannot undo it.
    func mutate(_ id: RunID, _ body: (inout Run) -> Void) {
        guard var run = runs[id] else { return }
        switch run.status {
        case .cancelled, .merged, .discarded: return
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
                mutate(id) { $0.status = .failed(String(describing: error)) }
            }
            finalize(id)
        } while rerunRequested.contains(id) && !Task.isCancelled
        tasks[id] = nil
    }

    /// Settles the run's status after a pass.
    private func finalize(_ id: RunID) {
        guard let run = runs[id], run.status == .running, !rerunRequested.contains(id) else { return }
        if !run.needsYou.isEmpty {
            mutate(id) { $0.status = .needsYou }
            return
        }
        for (key, node) in run.nodes where key.lane == nil {
            if case .failed(let message) = node.state {
                mutate(id) { $0.status = .failed(message) }
                return
            }
        }
        // The pass ended with nothing runnable left and nothing waiting on the user; failed lanes count as finished.
        mutate(id) { $0.status = .completed }
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
            // A lane answered during this pass is waiting again; the requested rerun finishes it before judge/pick.
            if rerunRequested.contains(id) || (runs[id]?.nodes.contains { $0.key.lane != nil && $0.value.state == .waiting } ?? false) {
                return
            }
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
        case .failed: return false
        case .needsYou where !isPick: return false
        default: break
        }
        await runNode(id, key, plan: plan)
        return nodeState(id, key) == .succeeded
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
            case .failed, .needsYou: return
            default: break
            }
            await runNode(id, key, plan: plan)
            if nodeState(id, key) != .succeeded { return }
        }
    }

    /// Commits the run worktree and creates one worktree per candidate model, once per run.
    private func ensureLanes(_ id: RunID, plan: FlowPlan) async throws {
        guard let run = runs[id], run.lanes.isEmpty, let fan = plan.fanOut,
              case .prompt(let config)? = run.flow.node(fan)?.kind else { return }
        guard config.candidates.count <= 26 else { throw RunEngineError.tooManyCandidates(config.candidates.count) }
        _ = try await git.commitAll(worktree: run.worktree, message: "MetalFlow: before fan-out")
        for (index, model) in config.candidates.enumerated() {
            try Task.checkCancellation()
            let laneID = String(UnicodeScalar(UInt8(97 + index)))
            let branch = BranchNaming.laneBranch(run: run.branch, lane: laneID)
            let path = store.worktreesDirectory.appendingPathComponent(id.rawValue).appendingPathComponent(laneID)
            try await git.addWorktree(repo: run.repo, path: path, newBranch: branch, from: run.branch)
            // Recorded even if the run was cancelled meanwhile, so cleanup can find the worktree.
            guard var current = runs[id] else { return }
            current.lanes.append(Lane(id: laneID, model: model, branch: branch, worktree: path))
            runs[id] = current
            persist(current)
        }
    }
}
