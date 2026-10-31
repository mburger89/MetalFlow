import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunOrderTests {
    private func run(_ nodes: [NodeKey: NodeRun]) -> Run {
        Run(id: RunID(), flow: BuiltinFlows.fixGitHubIssue, title: "t", repo: URL(fileURLWithPath: "/r"),
            baseBranch: "main", branch: "b", worktree: URL(fileURLWithPath: "/w"), nodes: nodes)
    }

    @Test func orderedNodeKeysFollowPlanThenLane() {
        let flowOrder = BuiltinFlows.fixGitHubIssue.nodes.map(\.id)
        let later = flowOrder[flowOrder.count - 1], first = flowOrder[0]
        let r = run([NodeKey(node: later): NodeRun(), NodeKey(node: first, lane: "b"): NodeRun(),
                     NodeKey(node: first, lane: "a"): NodeRun(), NodeKey(node: "nope"): NodeRun()])
        #expect(r.orderedNodeKeys == [NodeKey(node: first, lane: "a"), NodeKey(node: first, lane: "b"),
                                      NodeKey(node: later), NodeKey(node: "nope")])
    }

    @Test func hasFailedNodeSeesLanes() {
        #expect(!run([NodeKey(node: "plan"): NodeRun()]).hasFailedNode)
        var failed = NodeRun()
        failed.state = .failed("x")
        #expect(run([NodeKey(node: "implement", lane: "c"): failed]).hasFailedNode)
        #expect(NodeState.failed("y").isFailed && !NodeState.running.isFailed)
    }
}
