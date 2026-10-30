import Foundation

extension RunEngine {
    static let maxCandidateDiffLines = 400
    static let maxShellOutputLines = 40

    /// Runs one node (or one node in one lane) and records its state.
    func runNode(_ id: RunID, _ key: NodeKey, plan: FlowPlan) async {
        guard let run = runs[id], let node = run.flow.node(key.node) else { return }
        updateNode(id, key) { n in
            n.state = .running
            n.startedAt = n.startedAt ?? Date()
            n.endedAt = nil
        }
        switch node.kind {
        case .flowInput:
            // launch initialises the flow input; reaching here means the run was not created by launch.
            finish(id, key, .failed("The flow input was not set up by launch"))
        case .repo:
            finish(id, key, .succeeded, output: run.repo.path)
        case .prompt(let config):
            await runAgent(id, key, node: node, config: config, plan: plan, isJudge: false)
        case .judge(let config):
            await runAgent(id, key, node: node, config: config, plan: plan, isJudge: true)
        case .shell(let config):
            await runShell(id, key, config: config, plan: plan, isGate: false)
        case .gate(let config):
            await runShell(id, key, config: config, plan: plan, isGate: true)
        case .pick:
            let lanes = runs[id]?.lanes ?? []
            let allFailed = lanes.contains { $0.gatePassed != nil } && !lanes.contains { $0.gatePassed == true }
            let recommended = runs[id]?.recommendation
            finish(id, key, .needsYou(.pickWinner(recommended: recommended, allGatesFailed: allFailed)))
        }
    }

    func finish(_ id: RunID, _ key: NodeKey, _ state: NodeState, output: String? = nil) {
        updateNode(id, key) { n in
            n.state = state
            if let output { n.output = output }
            n.endedAt = Date()
        }
    }

    // MARK: - Inputs

    /// Placeholder values for a node from its wired inputs' outputs.
    func templateValues(_ id: RunID, _ key: NodeKey, plan: FlowPlan) -> [String: String] {
        guard let run = runs[id] else { return [:] }
        var values: [String: String] = [:]
        for wire in run.flow.inputs(of: key.node) {
            let sourceIsLane = plan.laneScoped.contains(wire.from)
            if !sourceIsLane {
                values[wire.input] = run.nodes[NodeKey(node: wire.from)]?.output ?? ""
            } else if let lane = key.lane {
                values[wire.input] = run.nodes[NodeKey(node: wire.from, lane: lane)]?.output ?? ""
            } else {
                values[wire.input] = run.lanes.compactMap { lane in
                    run.nodes[NodeKey(node: wire.from, lane: lane.id)]?.output.map { "## \(lane.id)\n\($0)" }
                }.joined(separator: "\n\n")
            }
        }
        return values
    }

    /// The `{candidates}` text for a judge: one section per lane.
    private func candidatesText(_ id: RunID, plan: FlowPlan) async -> String {
        guard let run = runs[id] else { return "" }
        var sections: [String] = []
        for lane in run.lanes {
            let failure = run.nodes.first { key, node in
                guard key.lane == lane.id else { return false }
                if case .failed = node.state { return true }
                return false
            }
            if let failure, case .failed(let message) = failure.value.state {
                sections.append("## \(lane.id) (\(lane.model)) — failed: \(message)")
                continue
            }
            let tests: String
            switch lane.gatePassed {
            case true?: tests = "tests passed"
            case false?: tests = "tests failed"
            case nil: tests = "no gate"
            }
            let clipped: String
            do {
                let diff = try await git.diff(worktree: lane.worktree, base: run.branch)
                let lines = diff.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                clipped = lines.prefix(Self.maxCandidateDiffLines).joined(separator: "\n")
            } catch {
                clipped = "(diff unavailable: \(error.localizedDescription))"
            }
            sections.append("## \(lane.id) (\(lane.model)) — \(tests), +\(lane.added) −\(lane.removed)\n\(clipped)")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Agent nodes

    func runAgent(_ id: RunID, _ key: NodeKey, node: Node, config: PromptConfig, plan: FlowPlan, isJudge: Bool) async {
        guard let run = runs[id] else { return }
        let lane = key.lane.flatMap { laneID in run.lanes.first { $0.id == laneID } }

        var values = templateValues(id, key, plan: plan)
        if isJudge { values["candidates"] = await candidatesText(id, plan: plan) }
        let current = runs[id]?.nodes[key] ?? NodeRun()

        var request = AgentRequest(
            prompt: Template.fill(config.prompt, with: values),
            workingDirectory: lane?.worktree ?? run.worktree,
            model: lane?.model ?? config.model,
            allowedTools: config.allowedTools + current.extraAllowedTools,
            maxTurns: config.maxTurns)
        if let reply = current.pendingReply, let session = current.sessionID {
            request.prompt = reply
            request.resumeSessionID = session
        }
        updateNode(id, key) { $0.pendingReply = nil }

        let agent = self.agent
        let finalRequest = request
        let result: AgentResult?
        do {
            result = try await limiter.withSlot {
                var finished: AgentResult?
                for try await event in agent.run(finalRequest) {
                    switch event {
                    case .started(let session):
                        await self.updateNode(id, key) { $0.sessionID = session }
                    case .text(let text):
                        let line = String(text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                            .first ?? "").prefix(200)
                        await self.updateNode(id, key) { $0.appendLog(String(line)) }
                    case .toolUse(let name, let summary):
                        await self.updateNode(id, key) { $0.appendLog("▸ \(name) \(summary)") }
                    case .finished(let r):
                        finished = r
                    }
                }
                return finished
            }
        } catch {
            // A cancelled run ignores this write; otherwise the node must not stay `.running`.
            finish(id, key, .failed(error is CancellationError ? "interrupted" : error.localizedDescription))
            return
        }
        guard let result else {
            finish(id, key, .failed("The agent ended without a result"))
            return
        }
        updateNode(id, key) { $0.costUSD += result.costUSD }
        if result.isError {
            finish(id, key, .failed(result.text))
            return
        }
        if let lane {
            do {
                _ = try await git.commitAll(worktree: lane.worktree, message: "\(node.title) (\(lane.id))")
            } catch {
                finish(id, key, .failed("commit failed: \(error.localizedDescription)"), output: result.text)
                return
            }
        }
        if !result.deniedTools.isEmpty {
            finish(id, key, .needsYou(.deniedTools(result.deniedTools)), output: result.text)
        } else if let question = result.question {
            finish(id, key, .needsYou(.question(question)), output: result.text)
        } else {
            finish(id, key, .succeeded, output: result.text)
            if isJudge {
                let recommended = Self.recommendation(in: result.text, lanes: runs[id]?.lanes ?? [])
                mutate(id) { $0.recommendation = recommended }
            }
        }
    }

    /// The lane named by the last `RECOMMEND: <lane>` line, if it exists.
    static func recommendation(in text: String, lanes: [Lane]) -> LaneID? {
        let marker = "RECOMMEND:"
        let junk = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "`*"))
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: junk) }
        guard let line = lines.last(where: { $0.hasPrefix(marker) }) else { return nil }
        let name = line.dropFirst(marker.count).trimmingCharacters(in: junk)
        return lanes.contains { $0.id == name } ? name : nil
    }

    // MARK: - Shell and gate nodes

    func runShell(_ id: RunID, _ key: NodeKey, config: ShellConfig, plan: FlowPlan, isGate: Bool) async {
        guard let run = runs[id] else { return }
        let lane = key.lane.flatMap { laneID in run.lanes.first { $0.id == laneID } }
        let worktree = lane?.worktree ?? run.worktree
        let command = Template.fill(config.command, with: templateValues(id, key, plan: plan))
        let result: CommandResult
        do {
            result = try await runner.run(Command(
                executable: "/bin/sh", arguments: ["-c", command],
                workingDirectory: worktree, environment: shellEnvironment))
        } catch {
            finish(id, key, .failed(error is CancellationError ? "interrupted" : error.localizedDescription))
            return
        }
        var lines = (result.stdout + result.stderr)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        let tail = lines.suffix(Self.maxShellOutputLines).joined(separator: "\n")
        if isGate, let lane {
            let stat = try? await git.diffStat(worktree: worktree, base: run.branch)
            mutate(id) { run in
                guard let index = run.lanes.firstIndex(where: { $0.id == lane.id }) else { return }
                run.lanes[index].gatePassed = result.succeeded
                if let stat {
                    run.lanes[index].added = stat.added
                    run.lanes[index].removed = stat.removed
                }
            }
        }
        finish(id, key, .succeeded, output: "exit \(result.exitCode)\n" + tail)
    }
}
