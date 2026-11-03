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
            await runAgent(id, key, node: node, config: config, plan: plan, role: .work)
        case .judge(let config):
            await runAgent(id, key, node: node, config: config, plan: plan, role: .judge)
        case .shell(let config):
            await runShell(id, key, config: config, plan: plan, isGate: false)
        case .gate(let config):
            await runShell(id, key, config: config, plan: plan, isGate: true)
        case .openPR(let config):
            await runOpenPR(id, key, config: config, plan: plan)
        case .review(let config):
            let lane = key.lane.flatMap { laneID in run.lanes.first { $0.id == laneID } }
            if lane?.gatePassed == false {
                finish(id, key, .succeeded, output: "Skipped: tests failed")
            } else {
                await runAgent(id, key, node: node, config: config.agent, plan: plan, role: .review(config))
            }
        case .pick:
            finish(id, key, Self.pickWaiting(lanes: runs[id]?.lanes ?? [], recommendation: runs[id]?.recommendation))
        }
    }

    /// The state of a pick that waits for the user: the recommended candidate, and whether every gate failed.
    static func pickWaiting(lanes: [Lane], recommendation: LaneID?) -> NodeState {
        let allFailed = lanes.contains { $0.gatePassed != nil } && !lanes.contains { $0.gatePassed == true }
        return .needsYou(.pickWinner(recommended: recommendation, allGatesFailed: allFailed))
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
        let names = Set(run.flow.inputNames(of: key.node))
        for (name, binding) in run.flow.node(key.node)?.inputs ?? [:] where names.contains(name) {
            switch binding {
            case .fixed(let v): values[name] = v
            case .exposed(let d): values[name] = run.inputs[name] ?? d ?? ""
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
            var section = "## \(lane.id) (\(lane.model)) — \(Self.checksSummary(of: lane, in: run)), +\(lane.added) −\(lane.removed)\n\(await clippedDiff(lane, run: run).text)"
            if let findings = run.reviewFindings(of: lane) { section += "\n\nReview:\n" + findings }
            sections.append(section)
        }
        return sections.joined(separator: "\n\n")
    }

    /// A lane's committed diff against the run's branch, cut to `maxCandidateDiffLines`; `cut` says whether it was.
    private func clippedDiff(_ lane: Lane, run: Run) async -> (text: String, cut: Bool) {
        do {
            let diff = try await git.diff(worktree: lane.worktree, base: run.branch)
            // `git diff` ends with a newline, which is not another line.
            let lines = diff.split(whereSeparator: \.isNewline)
            return (lines.prefix(Self.maxCandidateDiffLines).joined(separator: "\n"), lines.count > Self.maxCandidateDiffLines)
        } catch {
            return ("(diff unavailable: \(error.localizedDescription))", false)
        }
    }

    /// How a lane's checks read in a header or PR body: "tests passed, review approved", "tests not finished",
    /// "no gate" and so on. A review that was skipped or is not in the flow adds nothing.
    static func checksSummary(of lane: Lane, in run: Run) -> String {
        let tests: String
        switch run.testsStatus(of: lane) {
        case .passed: tests = "tests passed"
        case .failed: tests = "tests failed"
        case .notFinished: tests = "tests not finished"
        case .none: tests = "no gate"
        }
        switch run.reviewStatus(of: lane) {
        case .passed: return tests + ", review approved"
        case .failed: return tests + ", review asked for changes"
        case .notFinished: return tests + ", review not finished"
        case .none: return tests
        }
    }

    /// The last `count` lines of `text`, without trailing blank lines.
    static func lastLines(_ text: String, _ count: Int) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.suffix(count).joined(separator: "\n")
    }

    // MARK: - Agent nodes

    /// What an agent node is for: it changes the code, judges the candidates, or reviews a candidate's diff.
    enum AgentRole {
        case work, judge
        case review(ReviewConfig)
    }

    /// What a step that continues a session is told when it runs again in a conversation that already had it.
    static let rerunNotice = "This step already ran earlier in this conversation, and the work it builds on has changed since. Do it again for the work as it stands now, and keep what is still right.\n\n"

    func runAgent(_ id: RunID, _ key: NodeKey, node: Node, config: PromptConfig, plan: FlowPlan, role: AgentRole) async {
        guard let run = runs[id] else { return }
        let lane = key.lane.flatMap { laneID in run.lanes.first { $0.id == laneID } }

        var values = templateValues(id, key, plan: plan)
        var instruction = ""
        var isJudge = false, review: ReviewConfig?
        switch role {
        case .work: break
        case .judge:
            isJudge = true
            values["candidates"] = await candidatesText(id, plan: plan)
        case .review(let reviewConfig):
            review = reviewConfig
            instruction = "\n\nPut all your findings in your final reply, and end it with a line that is exactly `VERDICT: approve` or `VERDICT: changes`."
            var diff = ""
            if let lane {
                let clipped = await clippedDiff(lane, run: run)
                diff = clipped.text
                if clipped.cut {
                    diff += "\n(cut at \(Self.maxCandidateDiffLines) lines; read the rest with git diff \(run.branch))"
                }
            }
            values["diff"] = diff
        }
        let current = runs[id]?.nodes[key] ?? NodeRun()
        // A Review stays a fresh reader; validation refuses a flow that says otherwise.
        let isReview = review != nil

        var request = AgentRequest(
            prompt: Template.fill(config.prompt, with: values) + instruction,
            workingDirectory: lane?.worktree ?? run.worktree,
            // A review keeps its own model; the lane's is the candidate's.
            model: review == nil ? (lane?.model ?? config.model) : config.model,
            allowedTools: config.allowedTools + current.extraAllowedTools,
            maxTurns: config.maxTurns)
        if let reply = current.pendingReply, let session = current.sessionID {
            request.prompt = reply
            request.resumeSessionID = session
        } else {
            // A message with no session to resume goes along with the full prompt. The nudge that resumes an interrupted
            // node is not one: a fresh start needs no telling to continue.
            if let reply = current.pendingReply, reply != Self.continueNudge {
                request.prompt += "\n\nA message about this step:\n" + reply
            }
            if let source = config.continuesSessionOf, !isReview {
                if let session = runs[id]?.nodes[NodeKey(node: source, lane: key.lane)]?.sessionID {
                    request.resumeSessionID = session
                    if let ran = current.ranInSession, ran == session { request.prompt = Self.rerunNotice + request.prompt }
                } else {
                    updateNode(id, key) { $0.appendLog("⚠ no session to continue; starting fresh") }
                }
            }
        }
        let agent = self.agent
        let finalRequest = request
        let result: AgentResult?
        do {
            result = try await limiter.withSlot {
                var finished: AgentResult?
                for try await event in agent.run(finalRequest) {
                    switch event {
                    case .started(let session):
                        // The message is on its way: if the turn fails it goes back to `pendingReply`.
                        await self.updateNode(id, key) {
                            $0.sessionID = session
                            // A second `.started` in one turn must not wipe the message.
                            // The resume nudge does not replace a message the interrupted turn is carrying; with none, it
                            // goes in flight too, so a failed turn keeps it and Retry resumes the same session.
                            if let reply = $0.pendingReply, reply != Self.continueNudge || $0.replyInFlight == nil {
                                $0.replyInFlight = reply
                            }
                            $0.pendingReply = nil
                        }
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
            // An interrupted turn keeps its message in flight: the resumed session already has it.
            if !(error is CancellationError) { keepReply(id, key) }
            finish(id, key, .failed(error is CancellationError ? "interrupted" : error.localizedDescription))
            return
        }
        guard let result else {
            keepReply(id, key)
            finish(id, key, .failed("The agent ended without a result"))
            return
        }
        updateNode(id, key) { $0.costUSD += result.costUSD }
        if result.sessionLost, let lost = finalRequest.resumeSessionID {
            // A continuer shares its source's session, so every node holding it forgets it, or Retry would loop.
            mutate(id) { run in
                for k in run.nodes.keys where run.nodes[k]?.sessionID == lost { run.nodes[k]?.sessionID = nil }
            }
            keepReply(id, key)
            // Only a message the step was sent is promised; the resume nudge is not one.
            let kept = runs[id]?.nodes[key]?.pendingReply
            let withMessage = kept != nil && kept != Self.continueNudge ? " and the message it was sent" : ""
            finish(id, key, .failed("The agent's conversation can no longer be found. Retry starts this step again from its original prompt\(withMessage)."))
            return
        }
        if result.isError {
            keepReply(id, key)
            finish(id, key, .failed(result.text))
            return
        }
        // A reviewer never edits, so there is nothing of its to commit.
        if let lane, review == nil {
            let message = Self.laneCommitMessage(
                runTitle: run.title, flowName: run.flow.name, lane: lane.id, nodeTitle: node.title, fix: current.pendingFix,
                followUp: current.followUpMessage)
            do {
                _ = try await git.commitAll(worktree: lane.worktree, message: message)
            } catch {
                // The message stays for Retry: the session already has it, and a retry must resume with it.
                keepReply(id, key)
                finish(id, key, .failed("commit failed: \(error.localizedDescription)"), output: result.text)
                return
            }
        }
        // The turn's work is committed (or there is none to commit): the message no longer labels anything.
        updateNode(id, key) { $0.replyInFlight = nil; $0.ranInSession = nil; $0.followUpMessage = nil }
        // The turn is over: a later one (an answer to a question) is ordinary work.
        if current.pendingFix != nil { updateNode(id, key) { $0.pendingFix = nil } }
        if !result.deniedTools.isEmpty {
            let tools = result.deniedTools.joined(separator: ", ")
            updateNode(id, key) { $0.appendLog("⚠ denied: \(tools)") }
        }
        if let question = result.question {
            finish(id, key, .needsYou(.question(question)), output: result.text)
        } else if let review {
            await concludeReview(id, key, node: node, config: review, text: result.text, plan: plan)
        } else {
            // Only the reply is read for a recommendation, never the question or the earlier verdict.
            let recommended = isJudge ? Self.recommendation(in: result.text, lanes: runs[id]?.lanes ?? []) : nil
            var output = result.text
            let base = isJudge ? runs[id]?.nodes[key]?.followUpBase : nil
            if let base, recommended == nil {
                output = base.previousOutput + "\n\nFollow-up: " + base.message + "\n\n" + result.text
            }
            finish(id, key, .succeeded, output: output)
            if isJudge {
                mutate(id) { run in
                    // A question put to the judge keeps the recommendation it had unless the reply names another.
                    if base == nil || recommended != nil { run.recommendation = recommended }
                    run.nodes[key]?.followUpBase = nil
                }
            }
        }
    }

    /// Puts the message of a turn that failed back to be sent again, so a retry resumes the session with it.
    private func keepReply(_ id: RunID, _ key: NodeKey) {
        updateNode(id, key) { n in
            // A newer message (an answer typed meanwhile) is not overwritten by the one that failed.
            // The nudge that resumed an interrupted turn gives way to the message that turn was carrying.
            if n.pendingReply == nil || n.pendingReply == Self.continueNudge, let reply = n.replyInFlight { n.pendingReply = reply }
            n.replyInFlight = nil
        }
    }

    /// What a review decided at the end of a reply.
    enum ReviewVerdict { case approve, changes }

    /// Records a finished review turn: approved, sent back for changes (when attempts and an agent are left), or
    /// not approved because the verdict was refused or unreadable.
    private func concludeReview(_ id: RunID, _ key: NodeKey, node: Node, config: ReviewConfig, text: String,
                                plan: FlowPlan) async {
        func setPassed(_ passed: Bool) {
            guard let laneID = key.lane else { return }
            mutate(id) { run in
                if let index = run.lanes.firstIndex(where: { $0.id == laneID }) { run.lanes[index].reviewPassed = passed }
            }
        }
        switch Self.reviewVerdict(in: text) {
        case .approve?:
            setPassed(true)
        case .changes?:
            let n = (runs[id]?.nodes[key]?.fixAttemptsUsed ?? 0) + 1
            let source = PendingFix(attempt: n, total: config.fixAttempts, command: node.title, label: "Review")
            if beginFix(id, key, attempts: config.fixAttempts, message: Self.reviewFixMessage(findings: text),
                        source: source, logLine: "✕ changes requested, fix \(n) of \(config.fixAttempts)", plan: plan) {
                return
            }
            setPassed(false)
        case nil:
            updateNode(id, key) { $0.appendLog("⚠ no VERDICT line") }
            setPassed(false)
        }
        finish(id, key, .succeeded, output: text)
    }

    /// The verdict on the last `VERDICT:` line; nil when there is none or it is neither `approve` nor `changes`.
    static func reviewVerdict(in text: String) -> ReviewVerdict? {
        // Reviewers write `## VERDICT: approve` and `VERDICT: approve.` too; neither should read as no verdict.
        let lead = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "`*#"))
        let trail = lead.union(CharacterSet(charactersIn: ".!"))
        switch lastMarkedValue("VERDICT:", in: text, leading: lead, trailing: trail)?.lowercased() {
        case "approve": return .approve
        case "changes": return .changes
        default: return nil
        }
    }

    /// The message that sends the agent back to work after a reviewer asked for changes.
    static func reviewFixMessage(findings: String) -> String {
        """
        A reviewer asked for changes to your work:

        \(lastLines(findings, 200))

        Make the changes that are right. If you disagree with one, leave it and say why in your reply.
        """
    }

    /// The lane named by the last `RECOMMEND: <lane>` line, if it exists.
    static func recommendation(in text: String, lanes: [Lane]) -> LaneID? {
        guard let name = lastMarkedValue("RECOMMEND:", in: text) else { return nil }
        return lanes.contains { $0.id == name } ? name : nil
    }

    /// What follows `marker` on the last line that starts with it, ignoring case and the `leading` characters
    /// before the marker and the `trailing` ones around the value (spaces, backticks and asterisks by default).
    private static func lastMarkedValue(
        _ marker: String, in text: String,
        leading: CharacterSet = .whitespaces.union(CharacterSet(charactersIn: "`*")),
        trailing: CharacterSet? = nil
    ) -> String? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: leading) }
        guard let line = lines.last(where: { $0.range(of: marker, options: [.anchored, .caseInsensitive]) != nil })
        else { return nil }
        return line.dropFirst(marker.count).trimmingCharacters(in: trailing ?? leading)
    }

    // MARK: - Open PR

    /// Pushes the picked candidate's branch and opens a pull request for it. Any failure leaves the node failed
    /// and the run exactly as it was, so retrying the node starts over (pushing again is safe).
    func runOpenPR(_ id: RunID, _ key: NodeKey, config: OpenPRConfig, plan: FlowPlan) async {
        guard let run = runs[id] else { return }
        guard let laneID = run.pickedLane, let lane = run.lanes.first(where: { $0.id == laneID }) else {
            finish(id, key, .failed("No candidate was picked, so there is no branch to open a pull request for."))
            return
        }
        func fail(_ error: Error) {
            finish(id, key, .failed(error is CancellationError ? "interrupted" : error.localizedDescription))
        }
        func note(_ line: String) { updateNode(id, key) { $0.appendLog(line) } }

        let base = run.baseBranch
        switch await git.unpublishedCommits(repo: run.repo, base: base) {
        case .count(let n) where n > 0:
            note("\(base) has \(n) commit\(n == 1 ? "" : "s") not on origin; they will appear in this PR.")
        case .remoteBranchMissing:
            note("origin/\(base) was not found; commits of \(base) that are not on origin will appear in this PR.")
        default: break
        }

        note("Pushing \(lane.branch) to origin")
        do { try await git.push(repo: run.repo, branch: lane.branch) } catch { return fail(error) }

        var body = "Candidate \(lane.id) (\(lane.model)), \(Self.checksSummary(of: lane, in: run)), chosen in MetalFlow."
        if let issue = Self.closedIssue(of: run, plan: plan) { body = "Closes #\(issue)\n\n" + body }
        let title = Self.commitName(runTitle: run.title, flowName: run.flow.name)

        note("Opening pull request")
        let url: String
        do {
            url = try await pullRequests.create(
                repo: run.repo, base: base, head: lane.branch, title: title, body: body, draft: config.draft)
        } catch { return fail(error) }

        // Unstructured, and written even if the run was cancelled meanwhile: the pull request exists now.
        await Task {
            guard !self.suspended.contains(id) else { return }
            self.setDirect(id) { run in
                run.nodes[key]?.state = .succeeded
                run.nodes[key]?.output = url
                run.nodes[key]?.endedAt = Date()
                // The pushed branch stays, as "branch from here" branches do.
                if !run.keptBranches.contains(lane.branch) { run.keptBranches.append(lane.branch) }
                run.status = .prOpened(lane.id, url: url)
            }
            await self.cleanup(id)
        }.value
    }

    /// The run's title without a leading `#N `.
    static func pullRequestTitle(_ title: String) -> String {
        title.replacing(/^#\d+\s+/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The issue number the run came from, when its first flow input is a GitHub issue (the title is `#N title`).
    static func closedIssue(of run: Run, plan: FlowPlan) -> Int? {
        let first = plan.order.compactMap { run.flow.node($0) }.first { if case .flowInput = $0.kind { true } else { false } }
        guard case .flowInput(let config)? = first?.kind, config.source == .githubIssue,
              let match = run.title.firstMatch(of: /^#(\d+)\s/) else { return nil }
        return Int(match.1)
    }

    // MARK: - Shell and gate nodes

    func runShell(_ id: RunID, _ key: NodeKey, config: ShellConfig, plan: FlowPlan, isGate: Bool) async {
        guard let run = runs[id] else { return }
        let lane = key.lane.flatMap { laneID in run.lanes.first { $0.id == laneID } }
        let worktree = lane?.worktree ?? run.worktree
        // Values come from issues and model output, so each is quoted as one shell word.
        let command = Template.fill(config.command, with: templateValues(id, key, plan: plan).mapValues(Template.shellQuote))
        let result: CommandResult
        do {
            result = try await runner.run(Command(
                executable: "/bin/sh", arguments: ["-c", command],
                workingDirectory: worktree, environment: shellEnvironment))
        } catch {
            finish(id, key, .failed(error is CancellationError ? "interrupted" : error.localizedDescription))
            return
        }
        // Stdout goes last: a build logs to stderr and a test run reports on stdout, and only the last lines are kept.
        var output = result.stderr
        if let last = output.last, !last.isNewline { output += "\n" }
        output += result.stdout
        let tail = Self.lastLines(output, Self.maxShellOutputLines)
        if isGate, !result.succeeded {
            let n = (run.nodes[key]?.fixAttemptsUsed ?? 0) + 1
            let source = PendingFix(attempt: n, total: config.fixAttempts, command: command)
            if beginFix(id, key, attempts: config.fixAttempts,
                        message: Self.fixMessage(command: command, exitCode: result.exitCode, output: tail),
                        source: source, logLine: "✕ exit \(result.exitCode), fix \(n) of \(config.fixAttempts)", plan: plan) {
                return
            }
        }
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
