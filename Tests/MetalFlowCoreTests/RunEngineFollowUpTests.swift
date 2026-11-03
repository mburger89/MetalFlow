import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunEngineFollowUpTests {
    typealias Harness = RunEngineTests.Harness

    private let implementA = NodeKey(node: "implement", lane: "a")
    private let implementB = NodeKey(node: "implement", lane: "b")
    private let judge = NodeKey(node: "judge")

    /// What a refused follow-up must leave alone. Dates are left out: a run reloaded from disk loses sub-second precision.
    private static func shape(_ run: Run) -> [NodeKey: [String]] {
        run.nodes.mapValues { ["\($0.state)", $0.output ?? "", $0.pendingReply ?? "", $0.sessionID ?? ""] }
    }

    private func finished(_ session: String, _ text: String) -> [AgentEvent] {
        [.started(sessionID: session), .finished(AgentResult(
            sessionID: session, text: text, isError: false, deniedTools: [], costUSD: 0, turns: 1))]
    }

    /// Launches the fix-issue flow and waits until it stops at the pick.
    private func atPick(_ h: Harness) async throws -> RunID {
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        return id
    }

    private func waitFor(_ h: Harness, _ id: RunID, _ done: (Run) -> Bool) async -> Run {
        for await r in h.engine.updates where r.id == id && done(r) { return r }
        fatalError("updates ended")
    }

    @Test func resumesTheSameSessionWithTheMessage() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let session = try #require(await h.engine.run(id)?.nodes[implementA]?.sessionID)
        h.agent.script({ $0.prompt == "Also add tests" }, events: finished(session, "added"))
        let before = h.agent.requests.count
        try await h.engine.followUp(id, node: implementA, message: "  Also add tests \n")
        _ = await waitFor(h, id) { $0.status == .needsYou && $0.nodes[NodeKey(node: "pick")]?.state != .waiting
            && h.agent.requests.count > before }
        await h.engine.waitForPass(id)
        let sent = h.agent.requests.dropFirst(before).filter { $0.workingDirectory.lastPathComponent == "a"
            && $0.resumeSessionID != nil }
        #expect(sent.count == 1)
        #expect(sent.first?.resumeSessionID == session)
        #expect(sent.first?.prompt == "Also add tests")
        #expect(await h.engine.run(id)?.nodes[implementA]?.pendingReply == nil)
    }

    @Test func rerunsLaterStepsOfThatCandidateOnly() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let before = try #require(await h.engine.run(id))
        let outputB = try #require(before.nodes[implementB]?.output)
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        h.agent.script({ $0.prompt == "Tweak it" }, hold: hold, events: finished("s", "tweaked"))
        try await h.engine.followUp(id, node: implementA, message: "Tweak it")
        let held = await waitFor(h, id) { $0.nodes[self.implementA]?.state == .running }

        #expect(held.recommendation == nil)
        #expect(held.nodes[NodeKey(node: "gate", lane: "a")]?.state == .waiting)
        #expect(held.nodes[judge]?.state == .waiting)
        #expect(held.nodes[NodeKey(node: "pick")]?.state == .waiting)
        #expect(held.lanes.first { $0.id == "a" }?.gatePassed == nil)
        #expect(held.nodes[implementB]?.output == outputB)
        #expect(held.nodes[NodeKey(node: "gate", lane: "b")]?.state == .succeeded)
        #expect(held.lanes.first { $0.id == "b" }?.gatePassed == true)

        release.finish()
        let run = await waitFor(h, id) { $0.status == .needsYou && $0.recommendation == "b" }
        #expect(run.nodes[NodeKey(node: "gate", lane: "a")]?.state == .succeeded)
        #expect(run.lanes.first { $0.id == "a" }?.gatePassed == true)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
        #expect(h.agent.requests.filter { $0.prompt.contains("judging candidate") }.count == 2)
        // Lane b's implement ran once only.
        #expect(h.agent.requests.filter { $0.prompt.contains("Fix this GitHub issue")
            && $0.workingDirectory.lastPathComponent == "b" }.count == 1)
    }

    @Test func commitsTheFollowUpsChanges() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let laneA = try #require(await h.engine.run(id)?.lanes.first { $0.id == "a" })
        let commitsBefore = try h.repo.git(["rev-list", "--count", laneA.branch])
        h.agent.script({ $0.prompt == "Add a file" }, effect: { r in
            try "x".write(to: r.workingDirectory.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        }, events: finished("s", "added"))
        try await h.engine.followUp(id, node: implementA, message: "Add a file")
        _ = await waitFor(h, id) { $0.status == .needsYou && $0.recommendation == "b" }
        await h.engine.waitForPass(id)
        let after = try h.repo.git(["rev-list", "--count", laneA.branch])
        #expect(Int(after) == Int(commitsBefore).map { $0 + 1 })
        let files = try h.repo.git(["ls-tree", "-r", "--name-only", laneA.branch])
        #expect(files.contains("extra.txt"))
    }

    @Test func judgeFollowUpWithoutARecommendationLeavesNone() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        #expect(await h.engine.run(id)?.recommendation == "b")
        h.agent.script({ $0.prompt == "Explain more" }, events: finished("s", "More words, no pick."))
        try await h.engine.followUp(id, node: judge, message: "Explain more")
        let run = await waitFor(h, id) { $0.status == .needsYou && $0.nodes[judge]?.state == .succeeded }
        await h.engine.waitForPass(id)
        #expect(run.recommendation == nil)
        guard case .needsYou(.pickWinner)? = await h.engine.run(id)?.nodes[NodeKey(node: "pick")]?.state else {
            Issue.record("the run did not reach the pick"); return
        }
        #expect(await h.engine.run(id)?.status == .needsYou)
    }

    @Test(arguments: [RunStatus.merged("b"), .discarded, .cancelled, .prOpened("b", url: "https://x/pull/1")])
    func refusedWhile(_ status: RunStatus) async throws {
        let h = try Harness()
        let id = try await atPick(h)
        await h.engine.setDirect(id) { $0.status = status }
        let run = try #require(await h.engine.run(id))
        #expect(!run.canFollowUp(implementA))
        await #expect(throws: RunEngineError.notFollowable(implementA)) {
            try await h.engine.followUp(id, node: implementA, message: "hi")
        }
        let after = try #require(await h.engine.run(id))
        #expect(after.status == status && Self.shape(after) == Self.shape(run) && after.recommendation == run.recommendation)
    }

    @Test func refusedWhileRunning() async throws {
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let h = try Harness(planHold: hold)
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        _ = await waitFor(h, id) { $0.nodes[NodeKey(node: "plan")]?.state == .running }
        let plan = NodeKey(node: "plan")
        await h.engine.setDirect(id) { $0.nodes[plan]?.state = .succeeded; $0.nodes[plan]?.sessionID = "s" }
        let run = try #require(await h.engine.run(id))
        #expect(run.status == .running)
        #expect(!run.canFollowUp(plan))
        await #expect(throws: RunEngineError.notFollowable(plan)) {
            try await h.engine.followUp(id, node: plan, message: "hi")
        }
    }

    @Test func refusedForNodesThatCannot() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == "c" },
                       events: [.finished(AgentResult(sessionID: "sc", text: "boom", isError: true, deniedTools: [],
                                                      costUSD: 0, turns: 1))])
        let id = try await atPick(h)
        let failed = NodeKey(node: "implement", lane: "c")
        #expect(await h.engine.run(id)?.nodes[failed]?.state == .failed("boom"))
        let gate = NodeKey(node: "gate", lane: "a")
        let noSession = NodeKey(node: "plan")
        await h.engine.setDirect(id) { $0.nodes[noSession]?.sessionID = nil }
        for key in [gate, failed, noSession, NodeKey(node: "nope"), NodeKey(node: "pick")] {
            #expect(await h.engine.run(id)?.canFollowUp(key) == false)
            await #expect(throws: RunEngineError.notFollowable(key)) {
                try await h.engine.followUp(id, node: key, message: "hi")
            }
        }
        #expect(RunEngineError.notFollowable(gate).errorDescription
            == "Only a finished Prompt or Judge step of an open run can take a follow-up.")
    }

    @Test func refusesAReviewStep() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        #expect(await h.engine.run(id)?.canFollowUp(implementA) == true)
        await h.engine.setDirect(id) { run in
            if let i = run.flow.nodes.firstIndex(where: { $0.id == "implement" }) {
                run.flow.nodes[i].kind = .review(ReviewConfig())
            }
        }
        #expect(await h.engine.run(id)?.canFollowUp(implementA) == false)
        await #expect(throws: RunEngineError.notFollowable(implementA)) {
            try await h.engine.followUp(id, node: implementA, message: "hi")
        }
    }

    @Test func refusesAnEmptyMessage() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let run = try #require(await h.engine.run(id))
        await #expect(throws: RunEngineError.notFollowable(implementA)) {
            try await h.engine.followUp(id, node: implementA, message: " \n\t ")
        }
        let after = try #require(await h.engine.run(id))
        #expect(after.status == run.status && Self.shape(after) == Self.shape(run))
        #expect(after.nodes[implementA]?.pendingReply == nil)
    }

    @Test func survivesQuitting() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        h.agent.script({ $0.prompt == "Do more" }, events: finished("s", "did more"))
        // Follow up and suspend in one actor turn: the pass never gets to start the turn.
        try await h.engine.followUpThenSuspend(id, node: implementA, message: "Do more")
        await h.engine.waitForPass(id)
        let suspended = try #require(await h.engine.run(id))
        #expect(suspended.nodes[implementA]?.pendingReply == "Do more")
        let before = h.agent.requests.count

        let runner = RoutingRunner(gh: h.gh)
        let engine = RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
        _ = try await engine.restore()
        try await engine.resumeInterrupted(id)
        for await r in engine.updates where r.id == id && r.status == .needsYou && r.recommendation == "b" { break }
        let sent = h.agent.requests.dropFirst(before)
        #expect(sent.contains { $0.prompt == "Do more" && $0.resumeSessionID != nil })
        #expect(!sent.contains { $0.prompt == "Continue where you left off." })
    }
}

extension RunEngine {
    /// Test seam: `followUp` then `suspend` in one actor turn, before the new pass can begin.
    func followUpThenSuspend(_ id: RunID, node: NodeKey, message: String) throws {
        try followUp(id, node: node, message: message)
        suspend(id)
    }
}
