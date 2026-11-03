import Foundation
import Testing
import os
@testable import MetalFlowCore

@Suite struct RunEngineFixLoopTests {
    typealias Harness = RunEngineTests.Harness

    // MARK: - Helpers

    private func result(_ session: String, _ text: String = "done") -> AgentResult {
        AgentResult(sessionID: session, text: text, isError: false, deniedTools: [], costUSD: 0.25, turns: 1)
    }

    /// The built-in shape (implement fan-out, then a gate that passes once ok.txt exists), with `attempts` fixes.
    /// The gate appends to runs.txt, so a lane's worktree shows how many times it ran.
    private func flow(_ h: Harness, attempts: Int) -> Flow {
        var flow = h.flow()
        let i = flow.nodes.firstIndex { $0.id == "gate" }!
        flow.nodes[i].kind = .gate(ShellConfig(command: "echo GATE-OUTPUT; echo run >> runs.txt; test -f ok.txt", fixAttempts: attempts))
        return flow
    }

    private func isImplement(_ r: AgentRequest, lane: String) -> Bool {
        r.prompt.contains("Fix this GitHub issue") && r.workingDirectory.lastPathComponent == lane
    }

    /// Lane `lane` starts session `session` without producing ok.txt; the n-th resume (1-based) of that session
    /// writes ok.txt when `n >= fixesOn`.
    private func scriptLane(_ h: Harness, _ lane: String, session: String, fixesOn: Int?,
                            resumeEvents: [AgentEvent]? = nil) -> OSAllocatedUnfairLock<Int> {
        let resumes = OSAllocatedUnfairLock(initialState: 0)
        h.agent.script({ isImplement($0, lane: lane) },
                       events: [.started(sessionID: session), .finished(result(session))])
        h.agent.script({ $0.resumeSessionID == session }, effect: { r in
            let n = resumes.withLock { $0 += 1; return $0 }
            if let fixesOn, n >= fixesOn {
                try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
            }
        }, events: resumeEvents ?? [.started(sessionID: session), .finished(result(session, "fixed"))])
        return resumes
    }

    private func launch(_ h: Harness, _ flow: Flow) async throws -> RunID {
        try await h.engine.launch(flow: flow, location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
    }

    private func finished(_ h: Harness, _ id: RunID) async throws -> Run {
        await h.engine.waitUntilSettled(id)
        return try #require(await h.engine.run(id))
    }

    private func lineCount(_ run: Run, lane: String, file: String) throws -> Int {
        let lane = try #require(run.lanes.first { $0.id == lane })
        let text = (try? String(contentsOf: lane.worktree.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    private func gate(_ lane: String?) -> NodeKey { NodeKey(node: "gate", lane: lane) }
    private func implement(_ lane: String?) -> NodeKey { NodeKey(node: "implement", lane: lane) }

    // MARK: - Behaviour

    @Test func failingGateResumesTheAgentAndPasses() async throws {
        let h = try Harness()
        let resumes = scriptLane(h, "c", session: "sc", fixesOn: 1)
        let id = try await launch(h, flow(h, attempts: 1))
        let run = try await finished(h, id)

        let resumed = h.agent.requests.filter { $0.resumeSessionID == "sc" }
        #expect(resumed.count == 1 && resumes.withLock { $0 } == 1)
        let prompt = try #require(resumed.first?.prompt)
        #expect(prompt.contains("echo GATE-OUTPUT; echo run >> runs.txt; test -f ok.txt"))
        #expect(prompt.contains("GATE-OUTPUT"))
        #expect(resumed.first?.workingDirectory.lastPathComponent == "c")
        #expect(run.lanes.map(\.gatePassed) == [true, true, true])
        #expect(try lineCount(run, lane: "c", file: "runs.txt") == 2)
        #expect(run.nodes[gate("c")]?.fixAttemptsUsed == 1)
        #expect(run.nodes[gate("c")]?.state == .succeeded)
        #expect(run.nodes[gate("c")]?.log.contains { $0.contains("fix 1 of 1") } == true)
        #expect(run.nodes[implement("c")]?.state == .succeeded)
        #expect(run.nodes[implement("c")]?.costUSD == 0.5)  // 0.25 + 0.25, never reset
        #expect(h.agent.requests.filter { $0.prompt.contains("judging candidate") }.count == 1)
        #expect(run.status == .needsYou)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
        // The fix is committed in the lane.
        let subjects = try h.repo.git(["log", "--format=%s", run.lanes[2].branch]).split(separator: "\n").map(String.init)
        #expect(subjects.contains("Fix attempt 1 of 1: Crash on launch (c)"))
        let body = try h.repo.git(["log", "-1", "--format=%B", run.lanes[2].branch])
        #expect(body.contains("Node: Implement"))
        #expect(body.contains("Gate: echo GATE-OUTPUT; echo run >> runs.txt; test -f ok.txt"))
        #expect(run.nodes[implement("c")]?.pendingFix == nil)
    }

    @Test func fixAttemptsRunOut() async throws {
        let h = try Harness()
        _ = scriptLane(h, "c", session: "sc", fixesOn: nil)
        let id = try await launch(h, flow(h, attempts: 2))
        let run = try await finished(h, id)

        #expect(h.agent.requests.filter { $0.resumeSessionID == "sc" }.count == 2)
        #expect(try lineCount(run, lane: "c", file: "runs.txt") == 3)
        #expect(run.lanes.map(\.gatePassed) == [true, true, false])
        #expect(run.nodes[gate("c")]?.fixAttemptsUsed == 2)
        #expect(run.nodes[gate("c")]?.state == .succeeded)
        let judges = h.agent.requests.filter { $0.prompt.contains("judging candidate") }
        #expect(judges.count == 1)
        #expect(judges.first?.prompt.contains("## c (haiku) — tests failed") == true)
        #expect(run.status == .needsYou)
    }

    @Test func fixOnTheLastAttemptPasses() async throws {
        let h = try Harness()
        _ = scriptLane(h, "c", session: "sc", fixesOn: 2)
        let id = try await launch(h, flow(h, attempts: 2))
        let run = try await finished(h, id)
        #expect(h.agent.requests.filter { $0.resumeSessionID == "sc" }.count == 2)
        #expect(run.lanes.map(\.gatePassed) == [true, true, true])
        #expect(run.nodes[gate("c")]?.fixAttemptsUsed == 2)
    }

    @Test func zeroAttemptsBehavesAsBefore() async throws {
        let h = try Harness()
        _ = scriptLane(h, "c", session: "sc", fixesOn: 1)
        let id = try await launch(h, flow(h, attempts: 0))
        let run = try await finished(h, id)
        #expect(h.agent.requests.allSatisfy { $0.resumeSessionID == nil })
        #expect(run.lanes.map(\.gatePassed) == [true, true, false])
        #expect(run.nodes[gate("c")]?.fixAttemptsUsed == 0)
        #expect(try lineCount(run, lane: "c", file: "runs.txt") == 1)
    }

    @Test func allCandidatesFailedStillWarnsOnPick() async throws {
        let h = try Harness()
        for lane in ["a", "b", "c"] { _ = scriptLane(h, lane, session: "s\(lane)", fixesOn: nil) }
        let id = try await launch(h, flow(h, attempts: 1))
        let run = try await finished(h, id)
        #expect(run.lanes.map(\.gatePassed) == [false, false, false])
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: true)))
    }

    @Test func eachLaneKeepsItsOwnCountAndTheJudgeWaitsForAll() async throws {
        let h = try Harness()
        _ = scriptLane(h, "b", session: "sb", fixesOn: 1)
        _ = scriptLane(h, "c", session: "sc", fixesOn: 2)
        let id = try await launch(h, flow(h, attempts: 2))
        let run = try await finished(h, id)
        #expect(run.nodes[gate("a")]?.fixAttemptsUsed == 0)
        #expect(run.nodes[gate("b")]?.fixAttemptsUsed == 1)
        #expect(run.nodes[gate("c")]?.fixAttemptsUsed == 2)
        #expect(run.lanes.map(\.gatePassed) == [true, true, true])
        let requests = h.agent.requests
        let judgeIndex = try #require(requests.firstIndex { $0.prompt.contains("judging candidate") })
        #expect(requests.filter { $0.prompt.contains("judging candidate") }.count == 1)
        let lastResume = try #require(requests.lastIndex { $0.resumeSessionID != nil })
        #expect(judgeIndex > lastResume)
        let judgePrompt = requests[judgeIndex].prompt
        #expect(!judgePrompt.contains("tests failed"))
    }

    @Test func questionDuringAFixPausesThenContinues() async throws {
        let h = try Harness()
        h.agent.script({ isImplement($0, lane: "c") }, events: [.started(sessionID: "sc"), .finished(result("sc"))])
        // The first resume (the fix) asks a question; the answer is scripted below once the run has paused.
        h.agent.script({ $0.resumeSessionID == "sc" },
                       events: [.started(sessionID: "sc"), .finished(result("sc", "hmm\nQUESTION: Which file?"))])
        let id = try await launch(h, flow(h, attempts: 2))
        await waitUntil("the question") { await h.engine.run(id)?.nodes[implement("c")]?.state == .needsYou(.question("Which file?")) }
        await h.engine.waitUntilSettled(id)
        let paused = try #require(await h.engine.run(id))
        #expect(paused.status == .needsYou)
        #expect(paused.nodes[gate("c")]?.state == .waiting)
        #expect(paused.nodes[gate("c")]?.fixAttemptsUsed == 1)
        #expect(paused.nodes[NodeKey(node: "judge")] == nil)

        h.agent.script({ $0.resumeSessionID == "sc" && $0.prompt == "The main one" }, effect: { r in
            try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        }, events: [.started(sessionID: "sc"), .finished(result("sc", "fixed"))])
        try await h.engine.answer(id, node: implement("c"), reply: "The main one")
        let run = try await finished(h, id)
        #expect(run.nodes[gate("c")]?.fixAttemptsUsed == 1)
        #expect(run.nodes[gate("c")]?.state == .succeeded)
        #expect(run.lanes.map(\.gatePassed) == [true, true, true])
        #expect(h.agent.requests.filter { $0.prompt.contains("judging candidate") }.count == 1)
        // The answer's commit is ordinary work, not labelled as a fix.
        let subjects = try h.repo.git(["log", "--format=%s", run.lanes[2].branch]).split(separator: "\n").map(String.init)
        #expect(subjects.contains("Crash on launch (c)"))
        // (The fix turn itself, which asked the question, committed the gate's runs.txt: exactly one fix label.)
        #expect(subjects.filter { $0.hasPrefix("Fix attempt") } == ["Fix attempt 1 of 2: Crash on launch (c)"])
        #expect(run.nodes[implement("c")]?.pendingFix == nil)
    }

    @Test func nodesBetweenTheAgentAndTheGateRunAgainOnEachFix() async throws {
        let h = try Harness()
        h.agent.script({ isImplement($0, lane: "a") }, events: [.started(sessionID: "sa"), .finished(result("sa"))])
        h.agent.script({ $0.resumeSessionID == "sa" }, effect: { r in
            try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        }, events: [.started(sessionID: "sa"), .finished(result("sa", "fixed"))])
        let flow = Flow(name: "between", nodes: [
            Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .exposed(default: nil))), position: Point(x: 0, y: 1)),
            Node(id: "implement", title: "Implement", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "Fix this GitHub issue", candidates: ["sonnet", "opus"],
                allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0)),
            Node(id: "fmt", title: "Format", kind: .shell(ShellConfig(command: "echo {code} > /dev/null; echo run >> fmt.txt")), position: Point(x: 1, y: 0)),
            Node(id: "gate", title: "Gate", kind: .gate(ShellConfig(command: "echo {fmt} > /dev/null; test -f ok.txt", fixAttempts: 1)), position: Point(x: 2, y: 0)),
        ], wires: [
            Wire(from: "implement", to: "fmt", input: "code"),
            Wire(from: "fmt", to: "gate", input: "fmt"),
        ])
        let id = try await launch(h, flow)
        let run = try await finished(h, id)
        #expect(run.status == .completed)
        #expect(run.nodes[gate("a")]?.fixAttemptsUsed == 1)
        #expect(run.nodes[NodeKey(node: "fmt", lane: "a")]?.state == .succeeded)
        #expect(try lineCount(run, lane: "a", file: "fmt.txt") == 2)
        #expect(run.lanes.map(\.gatePassed) == [true, true])
    }

    @Test func noUpstreamAgentSessionMeansNoFix() async throws {
        let h = try Harness()
        // No `.started` event: the agents have no session to resume.
        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") },
                       events: [.finished(result("", "done"))])
        let id = try await launch(h, flow(h, attempts: 2))
        let run = try await finished(h, id)
        #expect(h.agent.requests.allSatisfy { $0.resumeSessionID == nil })
        #expect(run.lanes.map(\.gatePassed) == [false, false, false])
        #expect(run.nodes[gate("a")]?.fixAttemptsUsed == 0)
        #expect(run.nodes[gate("a")]?.state == .succeeded)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: true)))
    }

    @Test func gateWithNoPromptUpstreamFails() async throws {
        let h = try Harness()
        let flow = Flow(name: "plain", nodes: [
            Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 0, y: 0)),
            Node(id: "gate", title: "Gate", kind: .gate(ShellConfig(command: "exit 3", fixAttempts: 2)), position: Point(x: 1, y: 0)),
        ], wires: [Wire(from: "repo", to: "gate", input: "repo")])
        let id = try await h.engine.launch(flow: flow, location: h.repoLocation, values: ["repo": h.repo.url.path])
        let run = try await finished(h, id)
        #expect(run.status == .failed("Gate failed: exit 3"))
        #expect(run.nodes[NodeKey(node: "gate")]?.state == .failed("Gate failed: exit 3"))
        #expect(run.nodes[NodeKey(node: "gate")]?.log.contains { $0.contains("exit 3") } == true)
        #expect(run.nodes[NodeKey(node: "gate")]?.fixAttemptsUsed == 0)
        #expect(h.agent.requests.isEmpty)
    }

    @Test func nonLaneGateResumesItsAgent() async throws {
        let h = try Harness()
        let resumes = OSAllocatedUnfairLock(initialState: 0)
        h.agent.script({ $0.prompt.contains("Write the code") },
                       events: [.started(sessionID: "sw"), .finished(result("sw"))])
        h.agent.script({ $0.resumeSessionID == "sw" }, effect: { r in
            resumes.withLock { $0 += 1 }
            try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        }, events: [.started(sessionID: "sw"), .finished(result("sw", "fixed"))])
        let flow = Flow(name: "single", nodes: [
            Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 0, y: 0)),
            Node(id: "code", title: "Code", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "Write the code in {repo}", candidates: [],
                allowedTools: [], maxTurns: nil)), position: Point(x: 1, y: 0)),
            Node(id: "gate", title: "Gate", kind: .gate(ShellConfig(command: "test -f ok.txt", fixAttempts: 1)), position: Point(x: 2, y: 0)),
        ], wires: [Wire(from: "repo", to: "code", input: "repo"), Wire(from: "code", to: "gate", input: "code")])
        let id = try await h.engine.launch(flow: flow, location: h.repoLocation, values: ["repo": h.repo.url.path])
        let run = try await finished(h, id)
        #expect(run.status == .completed)
        #expect(resumes.withLock { $0 } == 1)
        #expect(run.nodes[NodeKey(node: "gate")]?.fixAttemptsUsed == 1)
        #expect(run.nodes[NodeKey(node: "gate")]?.output?.hasPrefix("exit 0") == true)
    }

    @Test func retryingTheGateResetsItsCount() async throws {
        let h = try Harness()
        _ = scriptLane(h, "c", session: "sc", fixesOn: nil)
        let id = try await launch(h, flow(h, attempts: 1))
        let first = try await finished(h, id)
        #expect(first.nodes[gate("c")]?.fixAttemptsUsed == 1)
        #expect(h.agent.requests.filter { $0.resumeSessionID == "sc" }.count == 1)

        await h.engine.setDirect(id) { $0.nodes[NodeKey(node: "gate", lane: "c")]?.state = .failed("x") }
        try await h.engine.retry(id, node: gate("c"))
        let run = try await finished(h, id)
        // Without the reset the used count (1) would equal the limit and no second fix would be tried.
        #expect(h.agent.requests.filter { $0.resumeSessionID == "sc" }.count == 2)
        #expect(run.nodes[gate("c")]?.fixAttemptsUsed == 1)
    }

    @Test func retryingTheAgentResetsItsDownstreamGate() async throws {
        let h = try Harness()
        _ = scriptLane(h, "c", session: "sc", fixesOn: nil)
        let id = try await launch(h, flow(h, attempts: 1))
        _ = try await finished(h, id)
        await h.engine.setDirect(id) { $0.nodes[NodeKey(node: "implement", lane: "c")]?.state = .failed("x") }
        try await h.engine.retry(id, node: implement("c"))
        let run = try await finished(h, id)
        // The retried agent starts fresh (its session is kept, no pending reply), then the gate gets a full allowance.
        #expect(run.nodes[gate("c")]?.fixAttemptsUsed == 1)
        #expect(h.agent.requests.filter { $0.resumeSessionID == "sc" }.count == 2)
    }

    private var failedFix: [AgentEvent] {
        [.started(sessionID: "x"), .finished(AgentResult(sessionID: "x", text: "boom", isError: true, deniedTools: [], costUSD: 0, turns: 1))]
    }

    @Test func failedFixSessionFailsOnlyThatLane() async throws {
        let h = try Harness()
        _ = scriptLane(h, "a", session: "sa", fixesOn: nil, resumeEvents: failedFix)
        let id = try await launch(h, flow(h, attempts: 1))
        let run = try await finished(h, id)
        #expect(run.nodes[implement("a")]?.state == .failed("boom"))
        #expect(run.nodes[gate("a")]?.state == .waiting)
        let judges = h.agent.requests.filter { $0.prompt.contains("judging candidate") }
        #expect(judges.count == 1)
        #expect(judges.first?.prompt.contains("## a (sonnet) — failed: boom") == true)
        #expect(run.status == .needsYou)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
    }

    @Test func everyFixSessionFailingFailsTheRunLikeAllCandidatesFailed() async throws {
        let h = try Harness()
        for lane in ["a", "b", "c"] { _ = scriptLane(h, lane, session: "s\(lane)", fixesOn: nil, resumeEvents: failedFix) }
        let id = try await launch(h, flow(h, attempts: 1))
        let run = try await finished(h, id)
        #expect(run.status == .failed("all candidates failed"))
        #expect(h.agent.requests.filter { $0.prompt.contains("judging candidate") }.isEmpty)
    }

    @Test func retriedAgentThatFailsAgainDoesNotStrandTheJudge() async throws {
        let h = try Harness()
        _ = scriptLane(h, "a", session: "sa", fixesOn: nil, resumeEvents: failedFix)
        let id = try await launch(h, flow(h, attempts: 1))
        _ = try await finished(h, id)
        // Retrying resets the gate to waiting behind the agent. The fix message was never answered, so the retry sends
        // it again on the session the failed turn reported; the agent fails again.
        h.agent.script({ $0.resumeSessionID == "x" }, events: failedFix)
        try await h.engine.retry(id, node: implement("a"))
        let run = try await finished(h, id)
        let again = try #require(h.agent.requests.last { $0.resumeSessionID == "x" })
        #expect(again.prompt.contains("failed with exit code"))
        #expect(run.nodes[implement("a")]?.state == .failed("boom"))
        #expect(run.nodes[gate("a")]?.state == .waiting)
        #expect(h.agent.requests.filter { $0.prompt.contains("judging candidate") }.count == 2)
        #expect(run.status == .needsYou)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
    }

    @Test func cancellingDuringAFixLeavesTheRunCancelled() async throws {
        let h = try Harness()
        let (hold, cont) = AsyncStream<Void>.makeStream()
        defer { cont.finish() }
        h.agent.script({ isImplement($0, lane: "c") }, events: [.started(sessionID: "sc"), .finished(result("sc"))])
        h.agent.script({ $0.resumeSessionID == "sc" }, hold: hold,
                       events: [.started(sessionID: "sc"), .finished(result("sc", "fixed"))])
        let id = try await launch(h, flow(h, attempts: 2))
        await waitUntil("the fix to start") { h.agent.requests.contains { $0.resumeSessionID == "sc" } }
        await h.engine.cancel(id)
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        #expect(run.status == .cancelled)
        #expect(h.agent.requests.filter { $0.resumeSessionID == "sc" }.count == 1)
        #expect(run.nodes[gate("c")]?.state == .waiting)
        #expect(try lineCount(run, lane: "c", file: "runs.txt") == 1)
        #expect(h.agent.requests.filter { $0.prompt.contains("judging candidate") }.isEmpty)
    }

    // MARK: - Pieces

    private func sampleRun() -> Run {
        let flow = Flow(name: "f", nodes: [
            Node(id: "plan", title: "Plan", kind: .prompt(PromptConfig(model: "opus", prompt: "p", candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0)),
            Node(id: "impl", title: "Impl", kind: .prompt(PromptConfig(model: "sonnet", prompt: "i {plan}", candidates: ["sonnet", "opus"], allowedTools: [], maxTurns: nil)), position: Point(x: 1, y: 0)),
            Node(id: "fmt", title: "Fmt", kind: .shell(ShellConfig(command: "f {code}")), position: Point(x: 2, y: 0)),
            Node(id: "review", title: "Review", kind: .judge(PromptConfig(model: "opus", prompt: "r {fmt}", candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 3, y: 0)),
            Node(id: "gate", title: "Gate", kind: .gate(ShellConfig(command: "g {a} {b}", fixAttempts: 1)), position: Point(x: 4, y: 0)),
        ], wires: [
            Wire(from: "plan", to: "impl", input: "plan"),
            Wire(from: "impl", to: "fmt", input: "code"),
            Wire(from: "fmt", to: "gate", input: "a"),
            Wire(from: "impl", to: "gate", input: "b"),
        ])
        var run = Run(flow: flow, title: "t", repo: URL(fileURLWithPath: "/r"), baseBranch: "main", branch: "b", worktree: URL(fileURLWithPath: "/w"))
        run.nodes[NodeKey(node: "plan")] = NodeRun(state: .succeeded, sessionID: "plan-session")
        run.nodes[NodeKey(node: "impl", lane: "a")] = NodeRun(state: .succeeded, sessionID: "ia")
        run.nodes[NodeKey(node: "impl", lane: "b")] = NodeRun(state: .succeeded)
        return run
    }

    @Test func fixingAgentIsTheNearestPromptWithASessionInTheGatesScope() {
        let run = sampleRun()
        let scoped: Set<NodeID> = ["impl", "fmt", "gate"]
        #expect(RunEngine.fixingAgent(for: NodeKey(node: "gate", lane: "a"), in: run, laneScoped: scoped) == NodeKey(node: "impl", lane: "a"))
        // Lane b's agent has no session; the plan agent is outside the lane's scope, so there is no one to resume.
        #expect(RunEngine.fixingAgent(for: NodeKey(node: "gate", lane: "b"), in: run, laneScoped: scoped) == nil)
    }

    @Test func fixingAgentSkipsJudgesAndFindsPlainNodes() {
        var run = sampleRun()
        // A judge feeding the gate does not count, even with a session.
        run.flow.wires.append(Wire(from: "review", to: "gate", input: "c"))
        run.nodes[NodeKey(node: "review")] = NodeRun(state: .succeeded, sessionID: "judge-session")
        // impl has no plain-key session here, so the search goes on to the plan agent.
        #expect(RunEngine.fixingAgent(for: NodeKey(node: "gate"), in: run, laneScoped: []) == NodeKey(node: "plan"))
    }

    @Test func nodesBetweenAreDownstreamOfTheAgentAndUpstreamOfTheGate() {
        let run = sampleRun()
        #expect(RunEngine.nodesBetween(agent: "impl", gate: "gate", flow: run.flow) == ["fmt"])
        #expect(RunEngine.nodesBetween(agent: "plan", gate: "gate", flow: run.flow) == ["impl", "fmt"])
        #expect(RunEngine.nodesBetween(agent: "fmt", gate: "gate", flow: run.flow).isEmpty)
    }

    @Test func fixMessageNamesTheCommandAndKeepsTheOutput() {
        let text = RunEngine.fixMessage(command: "swift test", exitCode: 1, output: "line1\nFAILED: testFoo")
        #expect(text.contains("swift test"))
        #expect(text.contains("line1\nFAILED: testFoo"))
        #expect(text.contains("exit"))
        #expect(!text.contains("Fix this GitHub issue"))
        #expect(!text.contains("judging candidate"))
    }

    // MARK: - Coding

    @Test func shellConfigDecodesWithoutFixAttempts() throws {
        let old = try JSONDecoder().decode(ShellConfig.self, from: Data(#"{"command":"make"}"#.utf8))
        #expect(old == ShellConfig(command: "make") && old.fixAttempts == 0)
        let data = try JSONEncoder().encode(ShellConfig(command: "make", fixAttempts: 2))
        #expect(try JSONDecoder().decode(ShellConfig.self, from: data).fixAttempts == 2)
    }

    @Test func flowFileRoundTripsFixAttemptsAndOldFilesLoad() throws {
        var flow = BuiltinFlows.fixGitHubIssue
        let i = flow.nodes.firstIndex { $0.id == "gate" }!
        flow.nodes[i].kind = .gate(ShellConfig(command: "make", fixAttempts: 3))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("f.flow")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FlowFile.save(flow, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"formatVersion\" : 1"))
        #expect(try FlowFile.load(from: url) == flow)

        let oldJSON = #"{"formatVersion":1,"flow":{"name":"x","wires":[],"nodes":[{"id":"g","title":"G","kind":{"gate":{"_0":{"command":"make"}}},"position":{"x":1,"y":2}}]}}"#
        try Data(oldJSON.utf8).write(to: url)
        let loaded = try FlowFile.load(from: url)
        #expect(loaded.node("g")?.kind == .gate(ShellConfig(command: "make")))
    }

    @Test func builtinFlowGivesItsGateTwoFixAttempts() {
        guard case .gate(let config)? = BuiltinFlows.fixGitHubIssue.node("gate")?.kind else { Issue.record("no gate"); return }
        #expect(config.fixAttempts == 2)
    }

    @Test func nodeRunDecodesWithoutFixAttemptsUsed() throws {
        var run = NodeRun(state: .succeeded, output: "x")
        run.fixAttemptsUsed = 2
        let data = try JSONEncoder().encode(run)
        #expect(try JSONDecoder().decode(NodeRun.self, from: data).fixAttemptsUsed == 2)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["fixAttemptsUsed"] = nil
        let old = try JSONDecoder().decode(NodeRun.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.fixAttemptsUsed == 0 && old.output == "x" && old.state == .succeeded)
    }

    @Test func nodeRunDecodesWithoutPendingFix() throws {
        var run = NodeRun(state: .succeeded, output: "x")
        let plain = try JSONEncoder().encode(run)
        let plainObject = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(plainObject["pendingFix"] == nil)  // omitted when nil
        run.pendingFix = PendingFix(attempt: 2, total: 3, command: "make")
        let data = try JSONEncoder().encode(run)
        #expect(try JSONDecoder().decode(NodeRun.self, from: data) == run)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["pendingFix"] = nil
        let old = try JSONDecoder().decode(NodeRun.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.pendingFix == nil && old.output == "x")
    }

    @Test func laneCommitMessageNamesTheIssueAndLabelsFixes() {
        let normal = RunEngine.laneCommitMessage(
            runTitle: "#7 Crash on launch", flowName: "Fix issue", lane: "a", nodeTitle: "Implement", fix: nil)
        #expect(normal == "Crash on launch (a)\n\nNode: Implement")
        let fix = PendingFix(attempt: 1, total: 2, command: "make test")
        let fixed = RunEngine.laneCommitMessage(
            runTitle: "#7 Crash on launch", flowName: "Fix issue", lane: "b", nodeTitle: "Implement", fix: fix)
        #expect(fixed == "Fix attempt 1 of 2: Crash on launch (b)\n\nNode: Implement\nGate: make test")
    }

    @Test func laneCommitMessageFallsBackToTheFlowName() {
        let message = RunEngine.laneCommitMessage(
            runTitle: "", flowName: "Fix issue", lane: "a", nodeTitle: "Implement", fix: nil)
        #expect(message.hasPrefix("Fix issue (a)\n"))
    }

    @Test func savedRunWithoutFixAttemptsUsedLoads() throws {
        var run = sampleRun()
        run.nodes[NodeKey(node: "gate", lane: "a")] = NodeRun(state: .succeeded, fixAttemptsUsed: 1)
        let data = try JSONEncoder().encode(run)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var nodes = try #require(object["nodes"] as? [String: [String: Any]])
        for key in nodes.keys { nodes[key]?["fixAttemptsUsed"] = nil }
        object["nodes"] = nodes
        let old = try JSONDecoder().decode(Run.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.nodes[NodeKey(node: "gate", lane: "a")]?.fixAttemptsUsed == 0)
        #expect(old.nodes.count == run.nodes.count)
    }

    @Test func fixProgressReportsUsedOfAllowed() {
        var run = sampleRun()
        let key = NodeKey(node: "gate", lane: "a")
        run.nodes[key] = NodeRun(state: .waiting, fixAttemptsUsed: 1)
        #expect(run.fixProgress(key)?.used == 1 && run.fixProgress(key)?.of == 1)
        run.nodes[key]?.fixAttemptsUsed = 0
        #expect(run.fixProgress(key) == nil)
        run.nodes[NodeKey(node: "impl", lane: "a")]?.fixAttemptsUsed = 1
        #expect(run.fixProgress(NodeKey(node: "impl", lane: "a")) == nil)
    }
}
