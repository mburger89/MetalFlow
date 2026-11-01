import Foundation
import Testing
import MetalFlowCore
@testable import mflow

@Suite struct GateFixTextTests {
    private func run(_ nodes: [NodeKey: NodeRun]) -> Run {
        Run(id: RunID(rawValue: "ID1"), flow: BuiltinFlows.fixGitHubIssue, title: "Fix #7", repo: URL(fileURLWithPath: "/repo"),
            baseBranch: "main", branch: "mflow/7", worktree: URL(fileURLWithPath: "/wt"), nodes: nodes)
    }

    @Test func summaryShowsFixAttemptsOnTheGate() {
        let nodes: [NodeKey: NodeRun] = [
            NodeKey(node: "gate", lane: "a"): NodeRun(state: .running, fixAttemptsUsed: 1),
            NodeKey(node: "gate", lane: "b"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "a"): NodeRun(state: .succeeded),
        ]
        let lines = runSummary(run(nodes))
        #expect(lines.contains("  gate@a running (fix 1 of 2)"))
        #expect(lines.contains("  gate@b succeeded"))
        #expect(lines.contains("  implement@a succeeded"))
    }

    @Test func nodeTextIgnoresNodesThatAreNotGatesAndUnusedAttempts() {
        let r = run([NodeKey(node: "implement", lane: "a"): NodeRun(state: .waiting, fixAttemptsUsed: 1),
                     NodeKey(node: "gate", lane: "c"): NodeRun(state: .waiting)])
        #expect(nodeText(NodeKey(node: "implement", lane: "a"), in: r) == "waiting")
        #expect(nodeText(NodeKey(node: "gate", lane: "c"), in: r) == "waiting")
        #expect(nodeText(NodeKey(node: "gate", lane: "z"), in: r) == "waiting")
    }
}
