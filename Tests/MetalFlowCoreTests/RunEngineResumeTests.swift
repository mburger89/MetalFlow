import Foundation
import Testing
@testable import MetalFlowCore

/// Restoring runs that were killed mid-flight, and what an answer or resume may restart.
@Suite struct RunEngineResumeTests {
    typealias Harness = RunEngineTests.Harness

    /// A second engine over the same store, as a fresh `mflow` process would have.
    private func secondEngine(_ h: Harness) -> RunEngine {
        let runner = RoutingRunner(gh: h.gh)
        return RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
    }

    private func settled(_ engine: RunEngine, _ id: RunID) async -> Run {
        for await run in engine.updates where run.id == id && run.status != .running { return run }
        fatalError("updates ended")
    }

    /// Runs a full flow to the pick, then returns the settled run so tests can rewrite its saved state.
    private func completedRun(_ h: Harness) async throws -> Run {
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        let run = await h.settled(id)
        await h.engine.waitForPass(id)
        return run
    }

    @Test func interruptedLaneIsNotRestartedByAnotherAnswer() async throws {
        let h = try Harness()
        var run = try await completedRun(h)
        let a = NodeKey(node: "implement", lane: "a"), b = NodeKey(node: "implement", lane: "b")
        run.nodes[a]?.state = .interrupted
        run.nodes[b]?.state = .needsYou(.question("Keep the API?"))
        run.nodes[b]?.sessionID = "sb"
        for key in run.nodes.keys where key.lane == "a" && key != a { run.nodes[key] = nil }
        for key in run.nodes.keys where key.lane == "b" && key != b { run.nodes[key] = nil }
        for key in ["judge", "pick"] { run.nodes[NodeKey(node: NodeID(rawValue: key))] = nil }
        run.recommendation = nil
        run.status = .needsYou
        try h.store.save(run)

        h.agent.script({ $0.resumeSessionID == "sb" }, events: [
            .finished(AgentResult(sessionID: "sb", text: "done", isError: false, deniedTools: [], costUSD: 0, turns: 1))])
        let engine = secondEngine(h)
        _ = try await engine.restore()
        let before = h.agent.requests.count
        try await engine.answer(run.id, node: b, reply: "yes")
        let after = await settled(engine, run.id)

        let newRequests = Array(h.agent.requests.dropFirst(before))
        #expect(newRequests.count == 1)
        #expect(newRequests.allSatisfy { $0.workingDirectory.lastPathComponent != "a" })
        #expect(after.nodes[a]?.state == .interrupted)
        #expect(after.nodes[NodeKey(node: "gate", lane: "b")]?.state == .succeeded)
        #expect(after.nodes[NodeKey(node: "judge")] == nil)
        #expect(after.status == .needsYou)
    }

    @Test func runKilledBetweenNodesResumesAndReachesPick() async throws {
        let h = try Harness()
        var run = try await completedRun(h)
        // Saved mid-fan-out: only lane a recorded, no node running. Lane b's worktree and branch exist
        // (recorded nowhere); lane c's branch exists without its worktree.
        let laneC = try #require(run.lanes.first { $0.id == "c" })
        try h.repo.git(["worktree", "remove", "--force", laneC.worktree.path])
        run.lanes = run.lanes.filter { $0.id == "a" }
        for key in run.nodes.keys where key.lane == "b" || key.lane == "c" { run.nodes[key] = nil }
        for key in ["judge", "pick"] { run.nodes[NodeKey(node: NodeID(rawValue: key))] = nil }
        run.recommendation = nil
        run.status = .running
        try h.store.save(run)

        let engine = secondEngine(h)
        let restored = try await engine.restore()
        #expect(restored.first?.status == .needsYou)
        try await engine.resumeInterrupted(run.id)
        let after = await settled(engine, run.id)

        #expect(after.status == .needsYou)
        #expect(after.lanes.map(\.id) == ["a", "b", "c"])
        #expect(after.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
        #expect(after.nodes[NodeKey(node: "gate", lane: "c")]?.state == .succeeded)
    }

    @Test func resumeWithNothingToDoStillThrows() async throws {
        let h = try Harness()
        let run = try await completedRun(h)
        let engine = secondEngine(h)
        _ = try await engine.restore()
        #expect(run.status == .needsYou)
        await #expect(throws: RunEngineError.nothingToResume) {
            try await engine.resumeInterrupted(run.id)
        }
    }
}
