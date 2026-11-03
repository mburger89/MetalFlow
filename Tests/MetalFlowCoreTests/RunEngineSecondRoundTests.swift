import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunEngineSecondRoundTests {
    typealias Harness = RunEngineTests.Harness

    private let implementA = NodeKey(node: "implement", lane: "a")
    private let judge = NodeKey(node: "judge")
    private let pick = NodeKey(node: "pick")

    private func finished(_ session: String, _ text: String, isError: Bool = false) -> [AgentEvent] {
        [.started(sessionID: session), .finished(AgentResult(
            sessionID: session, text: text, isError: isError, deniedTools: [], costUSD: 0, turns: 1))]
    }

    private func atPick(_ h: Harness, flow: Flow? = nil) async throws -> RunID {
        let id = try await h.engine.launch(flow: flow ?? h.flow(), location: .builtin,
                                           values: ["issue": "7", "repo": h.repo.url.path])
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        return id
    }

    @discardableResult
    private func waitFor(_ h: Harness, _ id: RunID, _ what: String, _ done: (Run) -> Bool) async -> Run {
        await waitUntil(what) { await h.engine.run(id).map(done) ?? false }
        return await h.engine.run(id)!
    }

    @Test func anOpenPRPickAfterAFailedFollowUpStillOpensThePR() async throws {
        let pr = RunEngineOpenPRTests()
        let h = try Harness()
        pr.stubSuccess(h)
        let id = try await pr.launchToPick(h, pr.prFlow(h))
        h.agent.script({ $0.prompt == "Explain" }, events: finished("s", "limit", isError: true))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        await waitFor(h, id, "the pick offered again") { $0.status == .needsYou && $0.nodes[self.judge]?.state.isFailed == true
            && $0.nodes[self.pick]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)) }
        await h.engine.waitForPass(id)
        let run = try await pr.pick(h, id)
        #expect(run.status == .prOpened("b", url: RunEngineOpenPRTests.prURL))
        #expect(run.nodes[RunEngineOpenPRTests.node]?.state == .succeeded)
    }

    @Test func aNewerReplyIsNotOverwrittenByAFailedTurn() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        h.agent.script({ $0.prompt == "Tweak" }, hold: hold, events: finished("s", "limit", isError: true))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        await waitFor(h, id, "the turn to start") { $0.nodes[self.implementA]?.replyInFlight == "Tweak" }
        await h.engine.setDirect(id) { $0.nodes[self.implementA]?.pendingReply = "newer" }
        release.finish()
        let run = await waitFor(h, id, "the turn to fail") { $0.nodes[self.implementA]?.state.isFailed == true }
        #expect(run.nodes[implementA]?.pendingReply == "newer")
        #expect(run.nodes[implementA]?.replyInFlight == nil)
    }

    @Test func aSecondStartedDoesNotWipeTheMessage() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        h.agent.script({ $0.prompt == "Tweak" }, events: [.started(sessionID: "s")] + finished("s", "limit", isError: true))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        let run = await waitFor(h, id, "the turn to fail") { $0.nodes[self.implementA]?.state.isFailed == true }
        #expect(run.nodes[implementA]?.pendingReply == "Tweak")
    }

    @Test func reloadShowsADeadProcessesRunAsCutShort() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let runner = RoutingRunner(gh: h.gh)
        let other = RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
        _ = try await other.restore()
        // A process saved the run as running and died: nobody holds its lock.
        var saved = try #require(h.store.load(id))
        saved.status = .running
        saved.nodes[implementA]?.state = .running
        saved.revision += 5
        try h.store.save(saved)
        let reloaded = try #require(await other.reload(id))
        #expect(reloaded.status == .needsYou)
        #expect(reloaded.nodes[implementA]?.state == .interrupted)
        #expect(reloaded.revision == saved.revision)
    }
}
