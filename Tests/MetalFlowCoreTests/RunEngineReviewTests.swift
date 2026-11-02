import Foundation
import Testing
import os
@testable import MetalFlowCore

@Suite struct RunEngineReviewTests {
    typealias Harness = RunEngineTests.Harness
    typealias Step = @Sendable (URL) throws -> Void

    // MARK: - Helpers

    private func result(_ session: String, _ text: String = "done", error: Bool = false) -> AgentResult {
        AgentResult(sessionID: session, text: text, isError: error, deniedTools: [], costUSD: 0.25, turns: 1)
    }

    /// The harness flow (implement fan-out, a gate that passes once ok.txt exists) with a Review between the gate
    /// and the judge. The gate appends to runs.txt, so a lane's worktree shows how many times it ran.
    private func flow(_ h: Harness, reviewAttempts: Int = 1, gateAttempts: Int = 0, withReview: Bool = true) -> Flow {
        var flow = h.flow()
        let i = flow.nodes.firstIndex { $0.id == "gate" }!
        flow.nodes[i].kind = .gate(ShellConfig(command: "echo run >> runs.txt; test -f ok.txt", fixAttempts: gateAttempts))
        guard withReview else { return flow }
        var agent = ReviewConfig.defaultAgent
        agent.prompt = "REVIEW-THIS\n{diff}"
        flow.nodes.append(Node(id: "review", title: "Code review",
                               kind: .review(ReviewConfig(agent: agent, fixAttempts: reviewAttempts)),
                               position: Point(x: 860, y: 185)))
        flow.wires.append(Wire(from: "gate", to: "review", input: "results"))
        flow.wires.append(Wire(from: "review", to: "judge", input: "review"))
        return flow
    }

    private func isImplement(_ r: AgentRequest, lane: String) -> Bool {
        r.prompt.contains("Fix this GitHub issue") && r.workingDirectory.lastPathComponent == lane
    }

    private func isReview(_ r: AgentRequest, lane: String) -> Bool {
        r.resumeSessionID == nil && r.prompt.contains("REVIEW-THIS") && r.workingDirectory.lastPathComponent == lane
    }

    private func reviewRequests(_ h: Harness, lane: String) -> [AgentRequest] {
        h.agent.requests.filter { isReview($0, lane: lane) }
    }

    /// Every lane's implement turn starts session `s<lane>`; lanes in `writesOK` also write ok.txt. A resume of
    /// that session does nothing unless `scriptResume` says so.
    private func scriptImplement(_ h: Harness, writesOK: Set<String> = ["a", "b"], bigLines: Int = 0) {
        for lane in ["a", "b", "c"] {
            let session = "s\(lane)"
            h.agent.script({ isImplement($0, lane: lane) }, effect: { r in
                if writesOK.contains(lane) {
                    try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
                }
                if bigLines > 0 {
                    let text = (1...bigLines).map { "line \($0)" }.joined(separator: "\n") + "\n"
                    try text.write(to: r.workingDirectory.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
                }
            }, events: [.started(sessionID: session), .finished(result(session))])
            h.agent.script({ $0.resumeSessionID == session }, events: [.started(sessionID: session), .finished(result(session, "fixed"))])
        }
    }

    /// The n-th resume (1-based) of lane `lane`'s implement session runs `steps[n - 1]` in the worktree and writes
    /// fix.txt, so the turn leaves something to commit.
    private func scriptResume(_ h: Harness, lane: String, _ steps: [Step]) {
        let session = "s\(lane)"
        let calls = OSAllocatedUnfairLock(initialState: 0)
        h.agent.script({ $0.resumeSessionID == session }, effect: { r in
            let n = calls.withLock { $0 += 1; return $0 }
            if n <= steps.count { try steps[n - 1](r.workingDirectory) }
            try "fix \(n)".write(to: r.workingDirectory.appendingPathComponent("fix.txt"), atomically: true, encoding: .utf8)
        }, events: [.started(sessionID: session), .finished(result(session, "fixed"))])
    }

    /// The reviews of lane `lane`, in order: the k-th fresh review answers `replies[k]` in session `r<lane><k+1>`.
    private func scriptReviews(_ h: Harness, lane: String, _ replies: [String], error: Bool = false,
                               effect: (@Sendable (AgentRequest) throws -> Void)? = nil) {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        for (k, reply) in replies.enumerated() {
            let session = "r\(lane)\(k + 1)"
            h.agent.script({ isReview($0, lane: lane) && calls.withLock { $0 } == k }, effect: { r in
                calls.withLock { $0 += 1 }
                try effect?(r)
            }, events: [.started(sessionID: session), .finished(result(session, reply, error: error))])
        }
    }

    private func launch(_ h: Harness, _ flow: Flow) async throws -> RunID {
        try await h.engine.launch(flow: flow, location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
    }

    private func finished(_ h: Harness, _ id: RunID) async throws -> Run {
        await h.engine.waitUntilSettled(id)
        return try #require(await h.engine.run(id))
    }

    private func lane(_ run: Run, _ id: String) throws -> Lane { try #require(run.lanes.first { $0.id == id }) }
    private func review(_ lane: String) -> NodeKey { NodeKey(node: "review", lane: lane) }
    private func gate(_ lane: String) -> NodeKey { NodeKey(node: "gate", lane: lane) }

    private func lineCount(_ run: Run, lane: String, file: String) throws -> Int {
        let worktree = try self.lane(run, lane).worktree
        let text = (try? String(contentsOf: worktree.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    private func judgePrompts(_ h: Harness) -> [String] {
        h.agent.requests.map(\.prompt).filter { $0.contains("judging candidate") }
    }

    // MARK: - Verdicts

    @Test func approvalMarksTheLane() async throws {
        let h = try Harness()
        scriptImplement(h)
        scriptReviews(h, lane: "a", ["Looks fine.\nVERDICT: approve"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        let run = try await finished(h, id)

        #expect(try lane(run, "a").reviewPassed == true)
        #expect(try lane(run, "b").reviewPassed == true)
        #expect(try lane(run, "c").reviewPassed == nil)
        #expect(run.nodes[review("a")]?.state == .succeeded)
        #expect(run.nodes[review("a")]?.output == "Looks fine.\nVERDICT: approve")
        let request = try #require(reviewRequests(h, lane: "a").first)
        #expect(request.allowedTools == ReviewConfig.defaultAgent.allowedTools)
        // The review's own model, not the candidate's: lane b's candidate model is opus.
        #expect(request.model == "sonnet")
        #expect(try #require(reviewRequests(h, lane: "b").first).model == "sonnet")
        #expect(request.prompt.contains("+++ b/ok.txt"))
        #expect(!request.prompt.contains("{diff}"))
        #expect(request.prompt.hasSuffix("\n\nPut all your findings in your final reply, and end it with a line that is exactly `VERDICT: approve` or `VERDICT: changes`."))
        #expect(request.workingDirectory == (try lane(run, "a")).worktree)
        // The judge hears about the review.
        #expect(judgePrompts(h).first?.contains("## a (sonnet) — tests passed, review approved") == true)
    }

    @Test func reviewDoesNotCommit() async throws {
        let h = try Harness()
        scriptImplement(h)
        // A reviewer that leaves a file behind anyway: it must not be committed on its behalf.
        scriptReviews(h, lane: "a", ["VERDICT: approve"], effect: { r in
            try "stray".write(to: r.workingDirectory.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        })
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        let run = try await finished(h, id)

        let branch = try lane(run, "a").branch
        let files = try h.repo.git(["ls-tree", "-r", "--name-only", branch])
        #expect(!files.contains("stray.txt"))
        let subjects = try h.repo.git(["log", "--format=%s", "\(run.branch)..\(branch)"]).split(separator: "\n")
        #expect(subjects.count == 1)
    }

    @Test func changesResumeTheAgentAndRerunGateAndReview() async throws {
        let h = try Harness()
        scriptImplement(h)
        scriptResume(h, lane: "a", [])
        scriptReviews(h, lane: "a", ["Found it: FINDING-ONE\nVERDICT: changes", "VERDICT: approve"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        let run = try await finished(h, id)

        let resumed = h.agent.requests.filter { $0.resumeSessionID == "sa" }
        #expect(resumed.count == 1)
        let prompt = try #require(resumed.first?.prompt)
        #expect(prompt.hasPrefix("A reviewer asked for changes to your work:"))
        #expect(prompt.contains("FINDING-ONE"))
        #expect(resumed.first?.workingDirectory == (try lane(run, "a")).worktree)
        #expect(try lineCount(run, lane: "a", file: "runs.txt") == 2)
        #expect(reviewRequests(h, lane: "a").count == 2)
        #expect(run.nodes[review("a")]?.sessionID == "ra2")
        #expect(try lane(run, "a").reviewPassed == true)
        #expect(run.nodes[review("a")]?.fixAttemptsUsed == 1)
        #expect(run.nodes[gate("a")]?.fixAttemptsUsed == 0)
        #expect(run.nodes[review("a")]?.log.contains("✕ changes requested, fix 1 of 1") == true)
        let branch = try lane(run, "a").branch
        let subjects = try h.repo.git(["log", "--format=%s", branch]).split(separator: "\n").map(String.init)
        #expect(subjects.contains("Fix attempt 1 of 1: Crash on launch (a)"))
        let body = try h.repo.git(["log", "-1", "--format=%B", branch])
        #expect(body.contains("Node: Implement"))
        #expect(body.contains("Review: Code review"))
        #expect(run.nodes[NodeKey(node: "implement", lane: "a")]?.pendingFix == nil)
    }

    @Test func changesRunOutReachesTheJudge() async throws {
        let h = try Harness()
        scriptImplement(h)
        scriptReviews(h, lane: "a", ["PROBLEM-ONE\nVERDICT: changes", "PROBLEM-TWO\nVERDICT: changes"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h, reviewAttempts: 1))
        let run = try await finished(h, id)

        #expect(try lane(run, "a").reviewPassed == false)
        #expect(run.nodes[review("a")]?.state == .succeeded)
        #expect(run.nodes[review("a")]?.fixAttemptsUsed == 1)
        #expect(h.agent.requests.filter { $0.resumeSessionID == "sa" }.count == 1)
        let prompts = judgePrompts(h)
        #expect(prompts.count == 1)
        let judge = try #require(prompts.first)
        #expect(judge.contains("## a (sonnet) — tests passed, review asked for changes"))
        #expect(judge.contains("PROBLEM-TWO"))
        #expect(judge.contains("## b (opus) — tests passed, review approved"))
    }

    @Test func zeroAttemptsMeansNoFix() async throws {
        let h = try Harness()
        scriptImplement(h)
        scriptReviews(h, lane: "a", ["VERDICT: changes"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h, reviewAttempts: 0))
        let run = try await finished(h, id)
        #expect(h.agent.requests.allSatisfy { $0.resumeSessionID == nil })
        #expect(try lane(run, "a").reviewPassed == false)
        #expect(run.nodes[review("a")]?.fixAttemptsUsed == 0)
        #expect(run.nodes[review("a")]?.state == .succeeded)
    }

    @Test(arguments: ["I could not decide.", "Hmm.\nVERDICT: maybe"])
    func missingOrUnknownVerdictIsNotApproved(reply: String) async throws {
        let h = try Harness()
        scriptImplement(h)
        scriptReviews(h, lane: "a", [reply])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h, reviewAttempts: 2))
        let run = try await finished(h, id)
        #expect(try lane(run, "a").reviewPassed == false)
        #expect(h.agent.requests.allSatisfy { $0.resumeSessionID == nil })
        #expect(run.nodes[review("a")]?.state == .succeeded)
        #expect(run.nodes[review("a")]?.fixAttemptsUsed == 0)
        #expect(run.nodes[review("a")]?.log.contains("⚠ no VERDICT line") == true)
    }

    @Test func verdictIsTheLastMatchingLine() {
        #expect(RunEngine.reviewVerdict(in: "I will end with\nVERDICT: approve\nbut actually no.\nVERDICT: changes") == .changes)
        #expect(RunEngine.reviewVerdict(in: "VERDICT: changes\nAfter a second look:\nVERDICT: approve") == .approve)
        #expect(RunEngine.reviewVerdict(in: "`VERDICT: approve`") == .approve)
        #expect(RunEngine.reviewVerdict(in: "**VERDICT: changes**") == .changes)
        #expect(RunEngine.reviewVerdict(in: "verdict: Approve") == .approve)
        #expect(RunEngine.reviewVerdict(in: "VERDICT: approve\nVERDICT: maybe") == nil)
        #expect(RunEngine.reviewVerdict(in: "I would say VERDICT: approve") == nil)
        #expect(RunEngine.reviewVerdict(in: "") == nil)
    }

    @Test func verdictIgnoresHeadingMarksAndClosingPunctuation() {
        #expect(RunEngine.reviewVerdict(in: "VERDICT: approve.") == .approve)
        #expect(RunEngine.reviewVerdict(in: "## VERDICT: approve") == .approve)
        #expect(RunEngine.reviewVerdict(in: "**VERDICT: changes!**") == .changes)
        #expect(RunEngine.reviewVerdict(in: "### `VERDICT: changes`.") == .changes)
        #expect(RunEngine.reviewVerdict(in: "VERDICT: maybe") == nil)
        #expect(RunEngine.reviewVerdict(in: "VERDICT: approve, but") == nil)
    }

    @Test func recommendationStaysExact() {
        let lanes = [Lane(id: "a", model: "m", branch: "b", worktree: URL(fileURLWithPath: "/w"))]
        #expect(RunEngine.recommendation(in: "RECOMMEND: a", lanes: lanes) == "a")
        #expect(RunEngine.recommendation(in: "RECOMMEND: a.", lanes: lanes) == nil)
        #expect(RunEngine.recommendation(in: "## RECOMMEND: a", lanes: lanes) == nil)
    }

    @Test func reviewFixMessageKeepsTheLastTwoHundredLines() {
        let findings = (1...250).map { "finding \($0)" }.joined(separator: "\n") + "\n\n"
        let message = RunEngine.reviewFixMessage(findings: findings)
        #expect(message.hasPrefix("A reviewer asked for changes to your work:\n\nfinding 51\n"))
        #expect(!message.contains("finding 50\n"))
        #expect(message.contains("finding 250\n\nMake the changes that are right. If you disagree with one, leave it and say why in your reply."))
    }

    // MARK: - Gate interplay

    @Test func failingGateSkipsTheReview() async throws {
        let h = try Harness()
        scriptImplement(h)
        scriptReviews(h, lane: "a", ["VERDICT: approve"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        let run = try await finished(h, id)
        #expect(reviewRequests(h, lane: "c").isEmpty)
        #expect(run.nodes[review("c")]?.state == .succeeded)
        #expect(run.nodes[review("c")]?.output == "Skipped: tests failed")
        #expect(try lane(run, "c").reviewPassed == nil)
        #expect(try lane(run, "c").gatePassed == false)
        #expect(judgePrompts(h).first?.contains("## c (haiku) — tests failed, +") == true)
    }

    @Test func fixThatBreaksTheTestsUsesTheGatesAttempts() async throws {
        let h = try Harness()
        scriptImplement(h)
        // The reviewer's fix removes ok.txt; the gate's own fix puts it back.
        scriptResume(h, lane: "a", [
            { try FileManager.default.removeItem(at: $0.appendingPathComponent("ok.txt")) },
            { try "ok".write(to: $0.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8) },
        ])
        scriptReviews(h, lane: "a", ["VERDICT: changes", "VERDICT: approve"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h, reviewAttempts: 1, gateAttempts: 1))
        let run = try await finished(h, id)

        let resumed = h.agent.requests.filter { $0.resumeSessionID == "sa" }
        try #require(resumed.count == 2)
        #expect(resumed[0].prompt.hasPrefix("A reviewer asked for changes"))
        #expect(resumed[1].prompt.contains("failed with exit code"))
        #expect(reviewRequests(h, lane: "a").count == 2)
        #expect(try lane(run, "a").gatePassed == true)
        #expect(try lane(run, "a").reviewPassed == true)
        #expect(run.nodes[gate("a")]?.fixAttemptsUsed == 1)
        #expect(run.nodes[review("a")]?.fixAttemptsUsed == 1)
        // The agent's fix turns are labelled by what asked for them.
        let branch = try lane(run, "a").branch
        let bodies = try h.repo.git(["log", "--format=%B", branch])
        #expect(bodies.contains("Review: Code review"))
        #expect(bodies.contains("Gate: echo run >> runs.txt; test -f ok.txt"))
    }

    @Test func gateBudgetIsNotRefilled() async throws {
        let h = try Harness()
        scriptImplement(h, writesOK: ["b"])
        // The gate's fix makes the tests pass; the reviewer's fix breaks them again.
        scriptResume(h, lane: "a", [
            { try "ok".write(to: $0.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8) },
            { try FileManager.default.removeItem(at: $0.appendingPathComponent("ok.txt")) },
        ])
        scriptReviews(h, lane: "a", ["VERDICT: changes", "VERDICT: approve"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h, reviewAttempts: 1, gateAttempts: 1))
        let run = try await finished(h, id)

        #expect(h.agent.requests.filter { $0.resumeSessionID == "sa" }.count == 2)  // no third turn
        #expect(try lane(run, "a").gatePassed == false)
        #expect(try lane(run, "a").reviewPassed == nil)
        #expect(run.nodes[gate("a")]?.fixAttemptsUsed == 1)
        #expect(reviewRequests(h, lane: "a").count == 1)
        #expect(run.nodes[review("a")]?.output == "Skipped: tests failed")
        #expect(try lineCount(run, lane: "a", file: "runs.txt") == 3)
    }

    // MARK: - Errors, questions, diffs

    @Test func reviewSessionErrorFailsOnlyThatLane() async throws {
        let h = try Harness()
        scriptImplement(h)
        scriptReviews(h, lane: "a", ["Something broke"], error: true)
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        let run = try await finished(h, id)
        #expect(run.nodes[review("a")]?.state == .failed("Something broke"))
        #expect(try lane(run, "a").reviewPassed == nil)
        #expect(run.nodes[review("b")]?.state == .succeeded)
        #expect(try lane(run, "b").reviewPassed == true)
        #expect(judgePrompts(h).first?.contains("## a (sonnet) — failed: Something broke") == true)
    }

    @Test func reviewQuestionWaitsThenReachesAVerdict() async throws {
        let h = try Harness()
        scriptImplement(h)
        scriptReviews(h, lane: "a", ["Hmm.\nQUESTION: Which file matters?"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        await waitUntil("the question") { await h.engine.run(id)?.nodes[review("a")]?.state == .needsYou(.question("Which file matters?")) }
        await h.engine.waitUntilSettled(id)
        let paused = try #require(await h.engine.run(id))
        #expect(try lane(paused, "a").reviewPassed == nil)
        #expect(paused.nodes[NodeKey(node: "judge")] == nil)

        h.agent.script({ $0.resumeSessionID == "ra1" && $0.prompt == "The main one" },
                       events: [.started(sessionID: "ra1"), .finished(result("ra1", "Good.\nVERDICT: approve"))])
        try await h.engine.answer(id, node: review("a"), reply: "The main one")
        let run = try await finished(h, id)
        #expect(try lane(run, "a").reviewPassed == true)
        #expect(run.nodes[review("a")]?.state == .succeeded)
        // The answer resumed the session as it was: no second instruction, no second fresh review.
        #expect(reviewRequests(h, lane: "a").count == 1)
        #expect(h.agent.requests.filter { $0.resumeSessionID == "ra1" }.map(\.prompt) == ["The main one"])
    }

    @Test func longDiffIsCutAndSaysSo() async throws {
        let h = try Harness()
        scriptImplement(h, bigLines: 500)
        scriptReviews(h, lane: "a", ["VERDICT: approve"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        let run = try await finished(h, id)
        let prompt = try #require(reviewRequests(h, lane: "a").first?.prompt)
        #expect(prompt.contains("(cut at 400 lines; read the rest with git diff \(run.branch))"))
        #expect(prompt.contains("+line 100"))
        #expect(!prompt.contains("+line 500"))
    }

    /// Lane a's diff is big.txt (6 header lines + n) and ok.txt (6 + 1 + the no-newline marker): 400 lines at n = 386.
    @Test(arguments: [(386, false), (387, true)])
    func theCutNoteAppearsOnlyWhenSomethingIsCut(bigLines: Int, cut: Bool) async throws {
        let h = try Harness()
        scriptImplement(h, bigLines: bigLines)
        scriptReviews(h, lane: "a", ["VERDICT: approve"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        let run = try await finished(h, id)
        let diff = try h.repo.git(["diff", run.branch, try lane(run, "a").branch])
        #expect(diff.split(whereSeparator: \.isNewline).count == bigLines + 14)
        let prompt = try #require(reviewRequests(h, lane: "a").first?.prompt)
        #expect(prompt.contains("(cut at 400 lines") == cut)
    }

    @Test func shortDiffHasNoCutNote() async throws {
        let h = try Harness()
        scriptImplement(h)
        scriptReviews(h, lane: "a", ["VERDICT: approve"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        _ = try await finished(h, id)
        #expect(try #require(reviewRequests(h, lane: "a").first?.prompt).contains("(cut at") == false)
    }

    // MARK: - Checks that did not finish

    private func summaryRun(gate: Bool = true, review: Bool = true, output: String? = nil, lane: Lane) -> Run {
        var flow = BuiltinFlows.fixGitHubIssue
        if !gate { flow.nodes.removeAll { $0.id == "gate" } }
        if review {
            flow.nodes.append(Node(id: "review", title: "Code review", kind: .review(ReviewConfig()), position: Point(x: 0, y: 0)))
        }
        var run = Run(id: RunID(rawValue: "R"), flow: flow, title: "t", repo: URL(fileURLWithPath: "/r"), baseBranch: "main",
                      branch: "mf/t", worktree: URL(fileURLWithPath: "/w"), lanes: [lane])
        if let output { run.nodes[NodeKey(node: "review", lane: lane.id)] = NodeRun(state: .succeeded, output: output) }
        return run
    }

    @Test(arguments: [
        (true, true, true as Bool?, true as Bool?, "tests passed, review approved"),
        (true, true, true, false, "tests passed, review asked for changes"),
        (true, true, true, nil, "tests passed, review not finished"),
        (true, true, nil, nil, "tests not finished, review not finished"),
        (true, true, false, nil, "tests failed"),
        (true, false, true, nil, "tests passed"),
        (true, false, nil, nil, "tests not finished"),
        (false, true, nil, nil, "no gate, review not finished"),
        (false, false, nil, nil, "no gate"),
    ] as [(Bool, Bool, Bool?, Bool?, String)])
    func checksSummaryTellsWhatDidNotFinish(gate: Bool, review: Bool, tests: Bool?, reviewed: Bool?, expected: String) {
        let lane = Lane(id: "a", model: "opus", branch: "b", worktree: URL(fileURLWithPath: "/w"), gatePassed: tests, reviewPassed: reviewed)
        let run = summaryRun(gate: gate, review: review, lane: lane)
        #expect(RunEngine.checksSummary(of: lane, in: run) == expected)
    }

    private func unfinishedRun(gate: Bool) -> (Run, Lane) {
        var flow = BuiltinFlows.fixGitHubIssue
        if !gate {
            // The gate moves after Pick: it runs once on the picked branch, not in a lane.
            flow.wires.removeAll { $0.to == "gate" || $0.from == "gate" }
            flow.wires.append(Wire(from: "implement", to: "judge", input: "code"))
            flow.wires.append(Wire(from: "pick", to: "gate", input: "after"))
        }
        let lane = Lane(id: "a", model: "opus", branch: "b", worktree: URL(fileURLWithPath: "/w"))
        let run = Run(id: RunID(rawValue: "R"), flow: flow, title: "t", repo: URL(fileURLWithPath: "/r"), baseBranch: "main",
                      branch: "mf/t", worktree: URL(fileURLWithPath: "/w"), lanes: [lane])
        return (run, lane)
    }

    @Test func aGateOutsideTheLanesNeverMakesTestsNotFinished() throws {
        let (run, lane) = unfinishedRun(gate: false)
        #expect(try run.flow.validate().laneScoped.contains("gate") == false)
        #expect(run.testsStatus(of: lane) == .none)
        #expect(RunEngine.checksSummary(of: lane, in: run) == "no gate")
    }

    @Test func aGateInsideTheLanesThatHasNotConcludedIsNotFinished() throws {
        let (run, lane) = unfinishedRun(gate: true)
        #expect(try run.flow.validate().laneScoped.contains("gate"))
        #expect(run.testsStatus(of: lane) == .notFinished)
        #expect(RunEngine.checksSummary(of: lane, in: run) == "tests not finished")
    }

    @Test func reviewFindingsAreTheLast40LinesAndOnlyWhenItAskedForChanges() {
        let output = (1...60).map { "finding \($0)" }.joined(separator: "\n") + "\n\n"
        var lane = Lane(id: "a", model: "opus", branch: "b", worktree: URL(fileURLWithPath: "/w"), gatePassed: true, reviewPassed: false)
        let run = summaryRun(output: output, lane: lane)
        let findings = run.reviewFindings(of: lane)
        #expect(findings?.hasPrefix("finding 21\n") == true)
        #expect(findings?.hasSuffix("finding 60") == true)
        lane.reviewPassed = true
        #expect(run.reviewFindings(of: lane) == nil)
        lane.reviewPassed = nil
        #expect(run.reviewFindings(of: lane) == nil)
    }

    @Test func aReviewThatErroredReadsAsNotFinishedInTheJudgeHeaderAndThePullRequest() async throws {
        let h = try Harness()
        h.hooks.stubGit("push")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: "https://github.com/acme/widgets/pull/12\n", stderr: ""))
        scriptImplement(h)
        scriptReviews(h, lane: "a", ["VERDICT: approve"])
        scriptReviews(h, lane: "b", ["Something broke"], error: true)
        var flow = flow(h)
        flow.nodes.append(Node(id: "openpr", title: "Open PR", kind: .openPR(OpenPRConfig(draft: true)), position: Point(x: 1200, y: 330)))
        flow.wires.append(Wire(from: "pick", to: "openpr", input: "approval"))
        let id = try await launch(h, flow)
        _ = try await finished(h, id)
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        let args = try #require(h.gh.calls.first { $0.arguments.starts(with: ["pr", "create"]) }).arguments
        #expect(args[args.firstIndex(of: "--body")! + 1] == "Closes #7\n\nCandidate b (opus), tests passed, review not finished, chosen in MetalFlow.")
    }

    // MARK: - Resuming

    /// Lane a is mid fix round: its agent is cut short before it saw the reviewer's findings, and the gate and
    /// review are cleared. Everything else has finished, so a resume only has lane a's round left.
    private func suspendMidRound(_ h: Harness, reviewState: NodeState? = nil, reviewSession: String? = nil,
                                 reply: String? = nil) async throws -> (RunID, RunEngine) {
        scriptImplement(h)
        scriptReviews(h, lane: "a", ["VERDICT: approve"])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        var run = try await finished(h, id)
        let implement = NodeKey(node: "implement", lane: "a")
        if let reply {
            run.nodes[implement]?.state = .interrupted
            run.nodes[implement]?.pendingReply = reply
            run.nodes[gate("a")] = nil
            run.nodes[review("a")] = nil
            if let i = run.lanes.firstIndex(where: { $0.id == "a" }) { run.lanes[i].gatePassed = nil; run.lanes[i].reviewPassed = nil }
        } else if let reviewState {
            run.nodes[review("a")] = NodeRun(state: reviewState, sessionID: reviewSession)
            if let i = run.lanes.firstIndex(where: { $0.id == "a" }) { run.lanes[i].reviewPassed = nil }
        }
        run.nodes[NodeKey(node: "judge")] = nil
        run.nodes[NodeKey(node: "pick")] = nil
        run.status = .needsYou
        run.recommendation = nil
        try h.store.save(run)

        let runner = RoutingRunner(gh: h.gh, hooks: h.hooks)
        let engine = RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
        _ = try await engine.restore()
        return (id, engine)
    }

    @Test func resumingKeepsAReplyTheAgentNeverReceived() async throws {
        let h = try Harness()
        let (id, engine) = try await suspendMidRound(h, reply: "FINDINGS: rename the thing")
        scriptReviews(h, lane: "a", ["VERDICT: approve"])
        let before = h.agent.requests.count
        try await engine.resumeInterrupted(id)
        await engine.waitUntilSettled(id)
        let resumed = h.agent.requests.dropFirst(before).filter { $0.resumeSessionID == "sa" }
        #expect(resumed.map(\.prompt) == ["FINDINGS: rename the thing"])
    }

    @Test func resumingAnInterruptedNodeWithNothingPendingSaysContinue() async throws {
        let h = try Harness()
        let (id, engine) = try await suspendMidRound(h, reply: "x")
        await engine.setDirect(id) { $0.nodes[NodeKey(node: "implement", lane: "a")]?.pendingReply = nil }
        let before = h.agent.requests.count
        try await engine.resumeInterrupted(id)
        await engine.waitUntilSettled(id)
        #expect(h.agent.requests.dropFirst(before).filter { $0.resumeSessionID == "sa" }.first?.prompt == "Continue where you left off.")
    }

    @Test func aRunSuspendedWhileTheReviewReranResumesWithAFreshReview() async throws {
        let h = try Harness()
        let (id, engine) = try await suspendMidRound(h, reviewState: .interrupted)
        scriptReviews(h, lane: "a", ["Fresh.\nVERDICT: approve"])
        let before = h.agent.requests.count
        try await engine.resumeInterrupted(id)
        await engine.waitUntilSettled(id)
        let new = Array(h.agent.requests.dropFirst(before))
        let reviews = new.filter { isReview($0, lane: "a") }
        #expect(reviews.count == 1)
        #expect(reviews.first?.prompt.contains("REVIEW-THIS") == true)
        #expect(new.filter { $0.resumeSessionID != nil && $0.workingDirectory.lastPathComponent == "a" }.isEmpty)
        let run = try #require(await engine.run(id))
        #expect(try lane(run, "a").reviewPassed == true)
    }

    // MARK: - Pull request, commits, retry, coding

    @Test(arguments: [
        ("VERDICT: approve", 1, "Candidate b (opus), tests passed, review approved, chosen in MetalFlow."),
        ("VERDICT: changes", 0, "Candidate b (opus), tests passed, review asked for changes, chosen in MetalFlow."),
        (nil, 0, "Candidate b (opus), tests passed, chosen in MetalFlow."),
    ] as [(String?, Int, String)])
    func pullRequestBodyMentionsTheReview(verdict: String?, attempts: Int, expected: String) async throws {
        let h = try Harness()
        h.hooks.stubGit("push")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: "https://github.com/acme/widgets/pull/12\n", stderr: ""))
        scriptImplement(h)
        if let verdict {
            scriptReviews(h, lane: "a", ["VERDICT: approve"])
            scriptReviews(h, lane: "b", [verdict])
        }
        var flow = flow(h, reviewAttempts: attempts, withReview: verdict != nil)
        flow.nodes.append(Node(id: "openpr", title: "Open PR", kind: .openPR(OpenPRConfig(draft: true)), position: Point(x: 1200, y: 330)))
        flow.wires.append(Wire(from: "pick", to: "openpr", input: "approval"))
        let id = try await launch(h, flow)
        _ = try await finished(h, id)
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        let args = try #require(h.gh.calls.first { $0.arguments.starts(with: ["pr", "create"]) }).arguments
        #expect(args[args.firstIndex(of: "--body")! + 1] == "Closes #7\n\n" + expected)
    }

    @Test func retryingAReviewClearsItsResult() async throws {
        let h = try Harness()
        scriptImplement(h)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // The first review approves; after the retry the review itself fails.
        h.agent.script({ self.isReview($0, lane: "a") }, effect: { _ in calls.withLock { $0 += 1 } },
                       events: [.started(sessionID: "ra1"), .finished(result("ra1", "VERDICT: approve"))])
        h.agent.script({ self.isReview($0, lane: "a") && calls.withLock { $0 } >= 1 },
                       events: [.started(sessionID: "ra2"), .finished(result("ra2", "Broke", error: true))])
        scriptReviews(h, lane: "b", ["VERDICT: approve"])
        let id = try await launch(h, flow(h))
        let first = try await finished(h, id)
        #expect(try lane(first, "a").reviewPassed == true)

        await h.engine.setDirect(id) { $0.nodes[NodeKey(node: "implement", lane: "a")]?.state = .failed("x") }
        try await h.engine.retry(id, node: NodeKey(node: "implement", lane: "a"))
        let run = try await finished(h, id)
        #expect(run.nodes[review("a")]?.state == .failed("Broke"))
        #expect(try lane(run, "a").reviewPassed == nil)
        #expect(try lane(run, "b").reviewPassed == true)
    }

    @Test func oldPendingFixDecodes() throws {
        let old = try JSONDecoder().decode(PendingFix.self, from: Data(#"{"attempt":1,"total":2,"command":"make"}"#.utf8))
        #expect(old == PendingFix(attempt: 1, total: 2, command: "make", label: "Gate"))
        #expect(old.label == "Gate")
        let review = PendingFix(attempt: 1, total: 1, command: "Code review", label: "Review")
        #expect(try JSONDecoder().decode(PendingFix.self, from: JSONEncoder().encode(review)) == review)
    }

    @Test func laneCommitMessageNamesTheReview() {
        let fix = PendingFix(attempt: 1, total: 2, command: "Code review", label: "Review")
        let message = RunEngine.laneCommitMessage(
            runTitle: "#7 Crash on launch", flowName: "Fix issue", lane: "b", nodeTitle: "Implement", fix: fix)
        #expect(message == "Fix attempt 1 of 2: Crash on launch (b)\n\nNode: Implement\nReview: Code review")
    }
}
