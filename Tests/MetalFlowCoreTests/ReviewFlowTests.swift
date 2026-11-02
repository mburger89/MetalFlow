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

    private let gateMessage = "A Review has to come after every gate, with no agent step between them."

    @Test func reviewWithoutAGateIsValid() throws {
        var flow = reviewFlow()
        flow.nodes.removeAll { $0.id == "gate" }
        flow.wires.removeAll { $0.from == "gate" || $0.to == "gate" }
        flow.wires.append(Wire(from: "implement", to: "review", input: "code"))
        #expect(throws: Never.self) { try flow.validate() }
    }

    @Test func twoReviewsAreInvalid() {
        var flow = reviewFlow()
        flow.nodes.append(node("review2", .review(ReviewConfig())))
        flow.wires.append(Wire(from: "review", to: "review2", input: "x"))
        #expect(throws: FlowError.multipleReviews("review2")) { try flow.validate() }
        #expect(FlowError.multipleReviews("review2").errorDescription == "A flow can have only one Review.")
    }

    @Test func reviewSiblingToTheGateIsInvalid() {
        var flow = reviewFlow()
        flow.wires.removeAll { $0.from == "gate" && $0.to == "review" }
        flow.wires.append(Wire(from: "implement", to: "review", input: "code"))
        flow.wires.append(Wire(from: "gate", to: "judge", input: "gateResults"))
        #expect(throws: FlowError.reviewBeforeGate("review")) { try flow.validate() }
        #expect(FlowError.reviewBeforeGate("review").errorDescription == gateMessage)
    }

    @Test func reviewBeforeTheGateIsInvalid() {
        var flow = reviewFlow()
        flow.wires.removeAll { $0.from == "implement" && $0.to == "gate" }
        flow.wires.removeAll { $0.from == "gate" && $0.to == "review" }
        flow.wires.append(Wire(from: "implement", to: "review", input: "code"))
        flow.wires.append(Wire(from: "review", to: "gate", input: "code"))
        flow.wires.append(Wire(from: "gate", to: "judge", input: "gate"))
        #expect(throws: FlowError.reviewBeforeGate("review")) { try flow.validate() }
    }

    @Test func agentBetweenTheGateAndTheReviewIsInvalid() {
        var flow = reviewFlow()
        flow.nodes.append(node("polish", .prompt(PromptConfig(model: "sonnet", prompt: "polish {code}", candidates: [], allowedTools: [], maxTurns: nil))))
        flow.wires.removeAll { $0.from == "gate" && $0.to == "review" }
        flow.wires.append(Wire(from: "gate", to: "polish", input: "code"))
        flow.wires.append(Wire(from: "polish", to: "review", input: "code"))
        #expect(throws: FlowError.reviewBeforeGate("review")) { try flow.validate() }
    }

    private func prompt(_ id: String) -> Node {
        node(id, .prompt(PromptConfig(model: "sonnet", prompt: "\(id) {code}", candidates: [], allowedTools: [], maxTurns: nil)))
    }

    @Test func anAgentThatFeedsTheReviewButNotTheGateIsInvalid() {
        var flow = reviewFlow()
        flow.nodes.append(prompt("docs"))
        flow.wires.append(Wire(from: "implement", to: "docs", input: "code"))
        flow.wires.append(Wire(from: "docs", to: "review", input: "docs"))
        #expect(throws: FlowError.reviewBeforeGate("review")) { try flow.validate() }
    }

    @Test func anAgentThatFeedsTheReviewButNotTheGateIsFineWithoutAGate() throws {
        var flow = reviewFlow()
        flow.nodes.removeAll { $0.id == "gate" }
        flow.wires.removeAll { $0.from == "gate" || $0.to == "gate" }
        flow.wires.append(Wire(from: "implement", to: "review", input: "code"))
        flow.nodes.append(prompt("docs"))
        flow.wires.append(Wire(from: "implement", to: "docs", input: "code"))
        flow.wires.append(Wire(from: "docs", to: "review", input: "docs"))
        #expect(throws: Never.self) { try flow.validate() }
    }

    @Test func anAgentAfterTheReviewIsInvalid() {
        var flow = reviewFlow()
        flow.nodes.append(prompt("polish"))
        flow.wires.removeAll { $0.from == "review" && $0.to == "judge" }
        flow.wires.append(Wire(from: "review", to: "polish", input: "code"))
        flow.wires.append(Wire(from: "polish", to: "judge", input: "review"))
        #expect(throws: FlowError.agentAfterReview("polish")) { try flow.validate() }
        #expect(FlowError.agentAfterReview("polish").errorDescription == "No agent step can come after a Review.")
    }

    @Test func shellBetweenTheGateAndTheReviewIsValid() throws {
        var flow = reviewFlow()
        flow.nodes.append(node("fmt", .shell(ShellConfig(command: "echo {code}"))))
        flow.wires.removeAll { $0.from == "gate" && $0.to == "review" }
        flow.wires.append(Wire(from: "gate", to: "fmt", input: "code"))
        flow.wires.append(Wire(from: "fmt", to: "review", input: "code"))
        #expect(throws: Never.self) { try flow.validate() }
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
