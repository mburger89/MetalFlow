import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunEngineRetryTests {
    typealias Harness = RunEngineTests.Harness

    private func failLaneC(_ h: Harness) {
        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == "c" },
                       events: [.finished(AgentResult(
                        sessionID: "sc", text: "boom", isError: true, deniedTools: [], costUSD: 0, turns: 1))])
    }

    @Test func retryFailedLaneReRunsIt() async throws {
        let h = try Harness()
        failLaneC(h)
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        let first = await h.settled(id)
        let key = NodeKey(node: "implement", lane: "c")
        #expect(first.nodes[key]?.state == .failed("boom"))
        #expect(first.nodes[NodeKey(node: "judge")]?.state == .succeeded)

        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == "c" },
                       events: [.started(sessionID: "sc2"), .finished(AgentResult(
                        sessionID: "sc2", text: "fixed", isError: false, deniedTools: [], costUSD: 0, turns: 1))])
        try await h.engine.retry(id, node: key)
        let run = await h.settled(id)

        #expect(run.nodes[key]?.state == .succeeded)
        #expect(run.nodes[NodeKey(node: "gate", lane: "c")]?.state == .succeeded)
        #expect(run.nodes[NodeKey(node: "judge")]?.state == .succeeded)
        let judges = h.agent.requests.filter { $0.prompt.contains("judging candidate") }
        #expect(judges.count == 2)
        let last = try #require(judges.last?.prompt)
        for lane in ["## a (", "## b (", "## c ("] { #expect(last.contains(lane)) }
        #expect(!last.contains("failed: boom"))
        #expect(run.status == .needsYou)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
    }

    @Test func retryRejectsNonFailedNode() async throws {
        let h = try Harness()
        failLaneC(h)
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        _ = await h.settled(id)
        let ok = NodeKey(node: "implement", lane: "a")
        await #expect(throws: RunEngineError.notRetryable(ok)) { try await h.engine.retry(id, node: ok) }
        let missing = NodeKey(node: "nope")
        await #expect(throws: RunEngineError.notRetryable(missing)) { try await h.engine.retry(id, node: missing) }
        #expect(RunEngineError.notRetryable(ok).errorDescription?.isEmpty == false)
    }
}
