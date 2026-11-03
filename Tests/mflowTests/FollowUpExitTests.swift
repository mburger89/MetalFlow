import Foundation
import Testing
import MetalFlowCore
@testable import mflow

@Suite struct FollowUpExitTests {
    private let key = NodeKey(node: "implement", lane: "a")

    private func run(_ state: NodeState) -> Run {
        var run = Run(id: RunID(rawValue: "ID1"), flow: BuiltinFlows.fixGitHubIssue, title: "Fix #7", repo: URL(fileURLWithPath: "/repo"),
                      baseBranch: "main", branch: "mflow/7", worktree: URL(fileURLWithPath: "/wt"), status: .needsYou)
        run.nodes[key] = NodeRun(state: state)
        return run
    }

    @Test func failedTargetGivesOneAndTheLine() {
        let outcome = followUpOutcome(code: 0, node: key, in: run(.failed("limit reached")))
        #expect(outcome.code == 1)
        #expect(outcome.line == "failed: implement@a: limit reached")
    }

    @Test func succeededTargetGivesZero() {
        let outcome = followUpOutcome(code: 0, node: key, in: run(.succeeded))
        #expect(outcome.code == 0 && outcome.line == nil)
    }

    @Test func anInterruptedExitStays() {
        let outcome = followUpOutcome(code: 130, node: key, in: run(.failed("limit reached")))
        #expect(outcome.code == 130 && outcome.line == nil)
    }

    @Test func aNonZeroExitStays() {
        let outcome = followUpOutcome(code: 1, node: key, in: run(.failed("limit reached")))
        #expect(outcome.code == 1 && outcome.line == nil)
    }
}
