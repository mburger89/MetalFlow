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

    @Test func lanesShowTheReviewAfterTheGateAndOmitItWhenNil() {
        func lane(_ id: LaneID, _ review: Bool?) -> Lane {
            Lane(id: id, model: "opus", branch: "mflow/7-\(id)", worktree: URL(fileURLWithPath: "/wt/\(id)"),
                 gatePassed: true, reviewPassed: review, added: 5, removed: 2)
        }
        let lines = runSummary(run(lanes: [lane("a", true), lane("b", false), lane("c", nil)]))
        #expect(lines.contains("  a  opus  gate passed  review approved  +5 -2  mflow/7-a"))
        #expect(lines.contains("  b  opus  gate passed  review asked for changes  +5 -2  mflow/7-b"))
        #expect(lines.contains("  c  opus  gate passed  +5 -2  mflow/7-c"))
    }

    private func reviewRun(gate: Bool = true, review: Bool = true, lane: Lane, findings: String? = nil) -> Run {
        var flow = BuiltinFlows.fixGitHubIssue
        if !gate { flow.nodes.removeAll { $0.id == "gate" } }
        if review { flow.nodes.append(Node(id: "review", title: "Review", kind: .review(ReviewConfig()), position: Point(x: 0, y: 0))) }
        var run = run(lanes: [lane])
        run.flow = flow
        if let findings { run.nodes[NodeKey(node: "review", lane: lane.id)] = NodeRun(state: .succeeded, output: findings) }
        return run
    }

    @Test func lanesSayWhenAReviewDidNotFinish() {
        func lane(_ gate: Bool?) -> Lane {
            Lane(id: "a", model: "opus", branch: "mflow/7-a", worktree: URL(fileURLWithPath: "/wt/a"), gatePassed: gate, added: 5, removed: 2)
        }
        #expect(runSummary(reviewRun(lane: lane(true))).contains("  a  opus  gate passed  review not finished  +5 -2  mflow/7-a"))
        #expect(runSummary(reviewRun(lane: lane(nil))).contains("  a  opus  gate pending  review not finished  +5 -2  mflow/7-a"))
        #expect(runSummary(reviewRun(lane: lane(false))).contains("  a  opus  gate failed  +5 -2  mflow/7-a"))
        #expect(runSummary(reviewRun(review: false, lane: lane(true))).contains("  a  opus  gate passed  +5 -2  mflow/7-a"))
    }

    @Test func lanesShowTheLast40LinesOfTheFindingsUnderTheLane() {
        let lane = Lane(id: "a", model: "opus", branch: "mflow/7-a", worktree: URL(fileURLWithPath: "/wt/a"),
                        gatePassed: true, reviewPassed: false, added: 5, removed: 2)
        let findings = (1...50).map { "finding \($0)" }.joined(separator: "\n")
        let lines = runSummary(reviewRun(lane: lane, findings: findings))
        let at = lines.firstIndex(of: "  a  opus  gate passed  review asked for changes  +5 -2  mflow/7-a")
        #expect(at != nil)
        let after = Array(lines.dropFirst((at ?? 0) + 1))
        #expect(after.first == "    finding 11")
        #expect(after.last == "    finding 50")
        #expect(after.count == 40)
    }
}
