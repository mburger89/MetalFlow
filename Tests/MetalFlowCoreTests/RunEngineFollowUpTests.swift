import Foundation
import Testing
import os
@testable import MetalFlowCore

@Suite struct RunEngineFollowUpTests {
    typealias Harness = RunEngineTests.Harness

    // MARK: - Helpers

    private func result(_ session: String, _ text: String = "done") -> AgentResult {
        AgentResult(sessionID: session, text: text, isError: false, deniedTools: [], costUSD: 0.25, turns: 1)
    }

    /// The harness flow (implement fan-out, a gate that passes once ok.txt exists) with a Review between the gate
    /// and the judge. The gate appends to runs.txt, so a lane's worktree shows how many times it ran.
    private func flow(_ h: Harness, gateAttempts: Int = 0) -> Flow {
        var flow = h.flow()
        let i = flow.nodes.firstIndex { $0.id == "gate" }!
        flow.nodes[i].kind = .gate(ShellConfig(command: "echo run >> runs.txt; test -f ok.txt", fixAttempts: gateAttempts))
        var agent = ReviewConfig.defaultAgent
        agent.prompt = "REVIEW-THIS\n{diff}"
        flow.nodes.append(Node(id: "review", title: "Code review",
                               kind: .review(ReviewConfig(agent: agent, fixAttempts: 0)),
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

    /// Every lane's implement turn starts session `s<lane>` (lanes a and b write ok.txt); every review approves;
    /// a resume of lane `followLane`'s session writes follow.txt, so the turn leaves something to commit, and
    /// waits for `hold` when given.
    private func script(_ h: Harness, followLane: String = "b", hold: AsyncStream<Void>? = nil,
                        holdImplement: String? = nil, implementHold: AsyncStream<Void>? = nil) {
        for lane in ["a", "b", "c"] {
            let session = "s\(lane)"
            h.agent.script({ isImplement($0, lane: lane) }, effect: { r in
                if lane != "c" {
                    try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
                }
            }, hold: lane == holdImplement ? implementHold : nil,
                           events: [.started(sessionID: session), .finished(result(session))])
            h.agent.script({ isReview($0, lane: lane) },
                           events: [.started(sessionID: "r\(lane)"), .finished(result("r\(lane)", "VERDICT: approve"))])
            h.agent.script({ $0.resumeSessionID == session }, effect: { r in
                if lane == followLane {
                    try "follow".write(to: r.workingDirectory.appendingPathComponent("follow.txt"), atomically: true, encoding: .utf8)
                }
            }, hold: lane == followLane ? hold : nil,
                           events: [.started(sessionID: session), .finished(result(session, "handled"))])
        }
    }

    private func launch(_ h: Harness, _ flow: Flow) async throws -> RunID {
        try await h.engine.launch(flow: flow, location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
    }

    private func finished(_ h: Harness, _ id: RunID) async throws -> Run {
        await h.engine.waitUntilSettled(id)
        return try #require(await h.engine.run(id))
    }

    /// A run waiting at the pick, with three candidates, their gates and reviews done.
    private func atThePick(_ h: Harness, gateAttempts: Int = 0) async throws -> (RunID, Run) {
        script(h)
        let id = try await launch(h, flow(h, gateAttempts: gateAttempts))
        let run = try await finished(h, id)
        try #require(run.status == .needsYou)
        return (id, run)
    }

    private func key(_ node: String, _ lane: String? = nil) -> NodeKey { NodeKey(node: NodeID(rawValue: node), lane: lane) }

    /// A node run without its dates, which the run store rounds when the engine reloads the run.
    private func summary(_ node: NodeRun?) -> [String] {
        guard let node else { return [] }
        return ["\(node.state)", node.output ?? "-", node.sessionID ?? "-", "\(node.costUSD)", "\(node.fixAttemptsUsed)",
                node.pendingReply ?? "-", node.log.joined(separator: "|")]
    }

    private func lineCount(_ run: Run, lane: String, file: String) throws -> Int {
        let worktree = try #require(run.lanes.first { $0.id == lane }).worktree
        let text = (try? String(contentsOf: worktree.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    private func followRequests(_ h: Harness, session: String = "sb") -> [AgentRequest] {
        h.agent.requests.filter { $0.resumeSessionID == session }
    }

    // MARK: - Behaviour

    @Test func resumesTheSameSessionWithTheMessage() async throws {
        let h = try Harness()
        let (id, run) = try await atThePick(h)
        #expect(run.nodes[key("implement", "b")]?.sessionID == "sb")
        try await h.engine.followUp(id, node: key("implement", "b"), message: "  also handle the empty case \n")
        let after = try await finished(h, id)

        let requests = followRequests(h)
        #expect(requests.count == 1)
        #expect(requests.first?.prompt == "also handle the empty case")
        #expect(requests.first?.workingDirectory.lastPathComponent == "b")
        #expect(after.nodes[key("implement", "b")]?.state == .succeeded)
        #expect(after.nodes[key("implement", "b")]?.sessionID == "sb")
        #expect(after.nodes[key("implement", "b")]?.pendingReply == nil)
        #expect(after.nodes[key("implement", "b")]?.pendingFollowUp == nil)
        #expect(after.nodes[key("implement", "b")]?.output == "handled")
        #expect(after.status == .needsYou)
    }

    @Test func gateAndReviewRerunAndTheJudgeAndPickComeBack() async throws {
        let h = try Harness()
        let (id, run) = try await atThePick(h)
        #expect(try lineCount(run, lane: "b", file: "runs.txt") == 1)
        let judgesBefore = h.agent.requests.filter { $0.prompt.contains("judging candidate") }.count
        let reviewsBefore = h.agent.requests.filter { isReview($0, lane: "b") }.count

        try await h.engine.followUp(id, node: key("implement", "b"), message: "again")
        let after = try await finished(h, id)

        #expect(try lineCount(after, lane: "b", file: "runs.txt") == 2)
        #expect(h.agent.requests.filter { isReview($0, lane: "b") }.count == reviewsBefore + 1)
        #expect(h.agent.requests.filter { $0.prompt.contains("judging candidate") }.count == judgesBefore + 1)
        #expect(after.lanes.first { $0.id == "b" }?.gatePassed == true)
        #expect(after.lanes.first { $0.id == "b" }?.reviewPassed == true)
        #expect(after.recommendation == "b")
        // Costs carry on through the reset.
        #expect(run.nodes[key("review", "b")]?.costUSD == 0.25)
        #expect(after.nodes[key("review", "b")]?.costUSD == 0.5)
        #expect(after.nodes[key("implement", "b")]?.costUSD == 0.5)
        #expect(after.nodes[key("pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
    }

    @Test func downstreamIsResetWhileTheAgentWorks() async throws {
        let h = try Harness()
        let (hold, release) = AsyncStream<Void>.makeStream()
        script(h, hold: hold)
        let id = try await launch(h, flow(h))
        let run = try await finished(h, id)
        try #require(run.status == .needsYou)
        let oldGate = try #require(run.nodes[key("gate", "b")])
        #expect(oldGate.output != nil)

        try await h.engine.followUp(id, node: key("implement", "b"), message: "again")
        // The call returned before the agent finished: look at what it left behind.
        await waitUntil("the follow-up turn to start") { await h.engine.run(id)?.nodes[key("implement", "b")]?.state == .running }
        let mid = try #require(await h.engine.run(id))
        #expect(mid.status == .running)
        for downstream in [key("gate", "b"), key("review", "b"), key("judge"), key("pick")] {
            let node = try #require(mid.nodes[downstream])
            #expect(node.state == .waiting)
            #expect(node.output == nil)
            #expect(node.sessionID == nil)
        }
        let lane = try #require(mid.lanes.first { $0.id == "b" })
        #expect(lane.gatePassed == nil && lane.reviewPassed == nil)
        #expect(mid.recommendation == nil)
        #expect(mid.nodes[key("implement", "b")]?.pendingReply == "again" || mid.nodes[key("implement", "b")]?.sessionID == "sb")
        release.yield()
        release.finish()
        let after = try await finished(h, id)
        #expect(after.status == .needsYou)
    }

    @Test func otherLanesAreUntouched() async throws {
        let h = try Harness()
        let (id, run) = try await atThePick(h)
        let before = ["a", "c"].flatMap { lane in ["implement", "gate", "review"].map { key($0, lane) } }
        let snapshot = before.map { run.nodes[$0] }
        let requestsBefore = h.agent.requests.count

        try await h.engine.followUp(id, node: key("implement", "b"), message: "again")
        let after = try await finished(h, id)

        for (node, old) in zip(before, snapshot) { #expect(summary(after.nodes[node]) == summary(old), "\(node)") }
        for lane in ["a", "c"] {
            #expect(after.lanes.first { $0.id == lane }?.gatePassed == run.lanes.first { $0.id == lane }?.gatePassed)
            #expect(after.lanes.first { $0.id == lane }?.reviewPassed == run.lanes.first { $0.id == lane }?.reviewPassed)
            #expect(try lineCount(after, lane: lane, file: "runs.txt") == 1)
        }
        // Only lane b's follow-up, its review, and the judge ran again.
        let newRequests = Array(h.agent.requests.dropFirst(requestsBefore))
        #expect(newRequests.allSatisfy { $0.workingDirectory.lastPathComponent == "b" || $0.prompt.contains("judging candidate") })
    }

    @Test func budgetsSurviveTheReset() async throws {
        let h = try Harness()
        // Lane c never produces ok.txt, so its gate spends its one fix attempt before the pick.
        let (id, run) = try await atThePick(h, gateAttempts: 1)
        #expect(run.nodes[key("gate", "c")]?.fixAttemptsUsed == 1)
        #expect(run.nodes[key("implement", "c")]?.costUSD == 0.5)
        let fixesBefore = followRequests(h, session: "sc").count
        #expect(fixesBefore == 1)

        try await h.engine.followUp(id, node: key("implement", "c"), message: "make ok.txt")
        let after = try await finished(h, id)

        // Used fixes are not refilled: the gate fails again and sends nobody back to work.
        #expect(after.nodes[key("gate", "c")]?.fixAttemptsUsed == 1)
        #expect(followRequests(h, session: "sc").count == fixesBefore + 1)
        #expect(after.nodes[key("implement", "c")]?.costUSD == 0.75)  // the cost carries on
        #expect(after.nodes[key("gate", "c")]?.state == .succeeded)
    }

    @Test func commitCarriesTheFollowUpLine() async throws {
        let h = try Harness()
        let (id, run) = try await atThePick(h)
        try await h.engine.followUp(id, node: key("implement", "b"), message: "also handle the empty case\nand the nil case")
        _ = try await finished(h, id)

        let branch = try #require(run.lanes.first { $0.id == "b" }).branch
        let body = try h.repo.git(["log", "-1", "--format=%B", branch])
        #expect(body.hasPrefix("Crash on launch (b)"))
        #expect(body.contains("Node: Implement"))
        #expect(body.contains("Follow-up: also handle the empty case\n"))
        #expect(!body.contains("nil case"))
        #expect(!body.contains("Fix attempt"))
        // A later ordinary turn is not labelled a follow-up.
        #expect(RunEngine.laneCommitMessage(runTitle: "#7 T", flowName: "F", lane: "a", nodeTitle: "N", fix: nil)
                == "T (a)\n\nNode: N")
    }

    // MARK: - Refusals

    @Test func emptyMessageThrows() async throws {
        let h = try Harness()
        let (id, _) = try await atThePick(h)
        for message in ["", "   \n\t"] {
            await #expect(throws: RunEngineError.emptyFollowUp) {
                try await h.engine.followUp(id, node: key("implement", "b"), message: message)
            }
        }
        #expect(await h.engine.run(id)?.status == .needsYou)
    }

    @Test func refusesNodesThatAreNotCandidateAgents() async throws {
        let h = try Harness()
        let (id, run) = try await atThePick(h)
        for node in [key("plan"), key("gate", "b"), key("review", "b"), key("judge"), key("pick"), key("implement"),
                     key("implement", "zz"), key("nope", "b")] {
            #expect(!RunEngine.canFollowUp(run, node: node), "\(node)")
            await #expect(throws: RunEngineError.notFollowable(node)) {
                try await h.engine.followUp(id, node: node, message: "hi")
            }
        }
        #expect(RunEngine.canFollowUp(run, node: key("implement", "b")))
        let unchanged = try #require(await h.engine.run(id))
        #expect(unchanged.status == run.status)
        #expect(unchanged.nodes.mapValues(summary) == run.nodes.mapValues(summary))
    }

    @Test func refusesAnAgentThatHasNotSucceededOrHasNoSession() async throws {
        let h = try Harness()
        let (_, run) = try await atThePick(h)
        let node = key("implement", "a")
        #expect(RunEngine.canFollowUp(run, node: node))
        for state in [NodeState.waiting, .running, .failed("x"), .interrupted, .needsYou(.question("?"))] {
            var changed = run
            changed.nodes[node]?.state = state
            #expect(!RunEngine.canFollowUp(changed, node: node), "\(state)")
        }
        var noSession = run
        noSession.nodes[node]?.sessionID = nil
        #expect(!RunEngine.canFollowUp(noSession, node: node))
        var notAtPick = run
        notAtPick.nodes[key("pick")]?.state = .waiting
        #expect(!RunEngine.canFollowUp(notAtPick, node: node))
        for status in [RunStatus.running, .completed, .failed("x"), .cancelled, .discarded, .merged("b")] {
            var other = run
            other.status = status
            #expect(!RunEngine.canFollowUp(other, node: node), "\(status)")
        }
    }

    @Test func refusesAfterAPick() async throws {
        let h = try Harness()
        let (id, _) = try await atThePick(h)
        _ = try await h.engine.pick(id, lane: "b")
        await #expect(throws: RunEngineError.notFollowable(key("implement", "a"))) {
            try await h.engine.followUp(id, node: key("implement", "a"), message: "hi")
        }
        #expect(followRequests(h, session: "sa").isEmpty)
    }

    @Test func refusesWhileAnotherLaneIsStillRunning() async throws {
        let h = try Harness()
        let (hold, release) = AsyncStream<Void>.makeStream()
        script(h, holdImplement: "c", implementHold: hold)
        let id = try await launch(h, flow(h))
        await waitUntil("lanes a and b to finish their agents") {
            let nodes = await h.engine.run(id)?.nodes
            return nodes?[key("implement", "a")]?.state == .succeeded && nodes?[key("implement", "b")]?.state == .succeeded
                && nodes?[key("implement", "c")]?.state == .running
        }
        let running = try #require(await h.engine.run(id))
        #expect(running.status == .running)
        #expect(!RunEngine.canFollowUp(running, node: key("implement", "a")))
        await #expect(throws: RunEngineError.notFollowable(key("implement", "a"))) {
            try await h.engine.followUp(id, node: key("implement", "a"), message: "hi")
        }
        #expect(followRequests(h, session: "sa").isEmpty)
        release.yield()
        release.finish()
        let done = try await finished(h, id)
        #expect(done.status == .needsYou)
        #expect(RunEngine.canFollowUp(done, node: key("implement", "a")))
    }

    @Test func unknownRunThrows() async throws {
        let h = try Harness()
        await #expect(throws: RunEngineError.unknownRun(RunID(rawValue: "nope"))) {
            try await h.engine.followUp(RunID(rawValue: "nope"), node: key("implement", "a"), message: "hi")
        }
    }
}
