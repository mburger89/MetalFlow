import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct ReviewFlowTests {
    private func node(_ id: String, _ kind: NodeKind) -> Node {
        Node(id: NodeID(rawValue: id), title: id, kind: kind, position: Point(x: 0, y: 0))
    }

    /// The built-in flow with a Review between its gate and its judge.
    private func reviewFlow() -> Flow {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.nodes.append(node("review", .review(ReviewConfig())))
        flow.wires.removeAll { $0.from == "gate" && $0.to == "judge" }
        flow.wires.append(Wire(from: "gate", to: "review", input: "code"))
        flow.wires.append(Wire(from: "review", to: "judge", input: "results"))
        return flow
    }

    private let message = "A Review has to sit after a step with several candidates and before the judge."

    @Test func reviewRoundTrips() throws {
        let kind = NodeKind.review(ReviewConfig(fixAttempts: 3))
        let data = try JSONEncoder().encode(kind)
        #expect(try JSONDecoder().decode(NodeKind.self, from: data) == kind)

        let agent = String(decoding: try JSONEncoder().encode(ReviewConfig.defaultAgent), as: UTF8.self)
        let old = Data(#"{"review":{"_0":{"agent":\#(agent)}}}"#.utf8)
        #expect(try JSONDecoder().decode(NodeKind.self, from: old) == .review(ReviewConfig(fixAttempts: 1)))
    }

    @Test func theDefaultAgentIsASonnetReadOnlyReviewer() {
        let agent = ReviewConfig().agent
        #expect(agent == ReviewConfig.defaultAgent)
        #expect(agent.model == "sonnet")
        #expect(agent.maxTurns == nil)
        #expect(agent.candidates.isEmpty)
        #expect(agent.allowedTools == ["Read", "Grep", "Glob", "Bash(git log:*)", "Bash(git diff:*)", "Bash(git show:*)", "Bash(git status:*)"])
        #expect(agent.prompt == "Review this change. Look for bugs, missing tests and anything that does not do what it should. Do not edit files. List only the problems worth fixing, each with its file and line.\n\n{diff}")
        #expect(ReviewConfig().fixAttempts == 1)
    }

    @Test func diffIsNotAnInput() {
        var config = ReviewConfig()
        config.agent.prompt = "{issue} {diff}"
        let flow = Flow(name: "f", nodes: [node("review", .review(config))], wires: [])
        #expect(flow.inputNames(of: "review") == ["issue"])
    }

    @Test func reviewInCandidatesIsValid() throws {
        let plan = try reviewFlow().validate()
        #expect(plan.laneScoped == ["implement", "gate", "review"])
    }

    @Test func reviewWithoutFanOutIsInvalid() {
        let flow = Flow(name: "f", nodes: [
            node("plan", .prompt(PromptConfig(model: "opus", prompt: "p", candidates: [], allowedTools: [], maxTurns: nil))),
            node("review", .review(ReviewConfig())),
        ], wires: [Wire(from: "plan", to: "review", input: "x")])
        #expect(throws: FlowError.reviewOutsideCandidates("review")) { try flow.validate() }
        #expect(FlowError.reviewOutsideCandidates("review").errorDescription == message)
        #expect(flow.message(for: .reviewOutsideCandidates("review")) == message)
    }

    @Test func reviewAfterJudgeIsInvalid() {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.nodes.append(node("review", .review(ReviewConfig())))
        flow.wires.append(Wire(from: "judge", to: "review", input: "x"))
        #expect(throws: FlowError.reviewOutsideCandidates("review")) { try flow.validate() }
    }

    @Test func laneDecodesWithoutReviewPassed() throws {
        let lane = Lane(id: "a", model: "m", branch: "b", worktree: URL(fileURLWithPath: "/w"))
        let json = String(decoding: try JSONEncoder().encode(lane), as: UTF8.self)
        #expect(!json.contains("reviewPassed"))
        #expect(try JSONDecoder().decode(Lane.self, from: Data(json.utf8)).reviewPassed == nil)

        var reviewed = lane
        reviewed.reviewPassed = true
        let data = try JSONEncoder().encode(reviewed)
        #expect(try JSONDecoder().decode(Lane.self, from: data).reviewPassed == true)
    }

    @Test func fixProgressCountsReviews() {
        var run = Run(flow: reviewFlow(), title: "t", repo: URL(fileURLWithPath: "/r"), baseBranch: "main",
                      branch: "b", worktree: URL(fileURLWithPath: "/w"))
        let key = NodeKey(node: "review", lane: "a")
        run.nodes[key] = NodeRun(state: .waiting, fixAttemptsUsed: 1)
        #expect(run.fixProgress(key) == Run.FixProgress(used: 1, of: 1))
    }
}
