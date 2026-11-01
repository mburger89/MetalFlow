import Foundation
import Testing
import MetalFlowCore
@testable import mflow

@Suite struct RunSummaryTests {
    private func run(status: RunStatus = .running, nodes: [NodeKey: NodeRun] = [:], lanes: [Lane] = [],
                     recommendation: LaneID? = nil) -> Run {
        Run(id: RunID(rawValue: "ID1"), flow: BuiltinFlows.fixGitHubIssue, title: "Fix #7", repo: URL(fileURLWithPath: "/repo"),
            baseBranch: "main", branch: "mflow/7", worktree: URL(fileURLWithPath: "/wt"), status: status,
            nodes: nodes, lanes: lanes, recommendation: recommendation)
    }

    @Test func headerOnlyForAnEmptyRun() {
        #expect(runSummary(run()) == [
            "ID1  running  Fix #7",
            "  repo /repo  base main  branch mflow/7",
            "nodes:",
        ])
    }

    @Test func nodesAreSortedByKeyDescription() {
        let nodes: [NodeKey: NodeRun] = [
            NodeKey(node: "plan"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "b"): NodeRun(state: .running),
            NodeKey(node: "implement", lane: "a"): NodeRun(state: .failed("bad")),
        ]
        let lines = runSummary(run(nodes: nodes))
        #expect(Array(lines[3...]) == ["  implement@a failed: bad", "  implement@b running", "  plan succeeded"])
    }

    @Test func needsYouLanesAndRecommendationAreListed() {
        let lane = Lane(id: "a", model: "opus", branch: "mflow/7-a", worktree: URL(fileURLWithPath: "/wt/a"),
                        gatePassed: true, added: 5, removed: 2)
        let nodes: [NodeKey: NodeRun] = [NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "a", allGatesFailed: false)))]
        let lines = runSummary(run(status: .needsYou, nodes: nodes, lanes: [lane], recommendation: "a"))
        #expect(lines.first == "ID1  needs you  Fix #7")
        #expect(lines.contains("  pick needs you (pick a winner, recommended a)"))
        #expect(lines.contains("needs you:"))
        #expect(lines.contains("  pick: pick a winner, recommended a"))
        #expect(lines.contains("lanes:"))
        #expect(lines.contains("  a  opus  gate passed  +5 -2  mflow/7-a"))
        #expect(lines.last == "recommendation: a")
    }

    @Test func noNeedsYouOrLaneSectionsWhenEmpty() {
        let lines = runSummary(run(nodes: [NodeKey(node: "plan"): NodeRun(state: .succeeded)]))
        #expect(!lines.contains("needs you:") && !lines.contains("lanes:"))
        #expect(!lines.contains { $0.hasPrefix("recommendation") })
    }
}
