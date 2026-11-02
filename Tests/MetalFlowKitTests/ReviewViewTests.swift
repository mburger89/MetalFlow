import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct ReviewViewTests {
    let repo = URL(fileURLWithPath: "/repo")

    func studio() async throws -> (AppModel, TestWindow) {
        let client = FakeEngineClient(restored: [], repos: [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model, size: metalFlowWindowSize)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.screen = .studio
        try await window.runUntilIdle()
        return (model, window)
    }

    func press(_ id: String, in window: TestWindow) async throws {
        try window.click(window.element(identifier: id))
        try await window.runUntilIdle()
    }

    func config(_ draft: FlowDraft, _ id: NodeID = "review1") -> ReviewConfig? {
        if case .review(let c)? = draft.flow.node(id)?.kind { return c }
        return nil
    }

    func detail(_ lanes: [Lane]) async throws -> TestWindow {
        var run = makeRun("review", status: .needsYou, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: nil, allGatesFailed: false)))])
        run.lanes = lanes
        let client = FakeEngineClient(restored: [run], repos: [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.open(run: run.id)
        try await window.runUntilIdle()
        return window
    }

    func lane(_ id: LaneID, review: Bool?) -> Lane {
        Lane(id: id, model: "sonnet", branch: "mf/x-\(id)", worktree: URL(fileURLWithPath: "/wt/\(id)"), gatePassed: true, reviewPassed: review)
    }

    // MARK: Palette and inspector

    @Test func paletteAddsAReviewWithDefaults() async throws {
        let (model, window) = try await studio()
        let draft = try #require(model.draft)
        try await press("palette.review", in: window)
        let added = try #require(draft.flow.node("review1"))
        #expect(added.title == "Review")
        #expect(added.kind == .review(ReviewConfig()))
    }

    @Test func inspectorShowsPromptAndFixAttemptsButNoCandidates() async throws {
        let (model, window) = try await studio()
        let draft = try #require(model.draft)
        try await press("palette.review", in: window)
        for id in ["inspector.model", "inspector.prompt", "inspector.tools", "inspector.maxTurns", "inspector.review.fixAttempts"] {
            _ = try window.element(identifier: id)
        }
        #expect((try? window.element(identifier: "inspector.candidates")) == nil)
        #expect(try window.element(identifier: "inspector.review.fixHint").value == "Sends the requested changes back to the agent up to this many times.")
        #expect(try window.element(identifier: "inspector.review.diffHint").value == "{diff} is filled in with the candidate's changes.")

        draft.editPrompt("review1", "prompt") { $0.prompt = "Look hard. {diff}" }
        #expect(config(draft)?.agent.prompt == "Look hard. {diff}")
    }

    @Test func pickerEditsFixAttemptsAndUndoes() async throws {
        let (model, window) = try await studio()
        let draft = try #require(model.draft)
        try await press("palette.review", in: window)
        #expect(config(draft)?.fixAttempts == 1)
        let before = draft.flow

        try window.click(window.element(identifier: "inspector.review.fixAttempts"))
        try window.chooseMenuItem("4")
        try await window.runUntilIdle()
        #expect(config(draft)?.fixAttempts == 4)
        #expect(config(draft)?.agent == ReviewConfig.defaultAgent)

        window.typeKey("z", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
    }

    @Test func fixAttemptsPickerSitsOnItsLabelsLeftEdge() async throws {
        let (_, window) = try await studio()
        try await press("palette.review", in: window)
        let left = { (id: String) in try window.element(identifier: id).frame.origin.x.value }
        #expect(try left("inspector.review.fixAttempts") == left("inspector.fixAttempts.label"))
    }

    @Test func aDefaultReviewBetweenAGateAndAJudgeValidates() throws {
        var flow = BuiltinFlows.fixGitHubIssue
        let draft = FlowDraft(flow: flow, location: .unsaved)
        let id = draft.addNode(.review)
        flow = draft.flow
        flow.wires.removeAll { $0.from == "gate" && $0.to == "judge" }
        flow.wires.append(Wire(from: "gate", to: id, input: "code"))
        flow.wires.append(Wire(from: id, to: "judge", input: "results"))
        _ = try flow.validate()
    }

    @Test func aReviewCardIsLabelledAndColouredLikeAGate() {
        let node = Node(id: "r", title: "Review", kind: .review(ReviewConfig()), position: Point(x: 0, y: 0))
        #expect(node.kindLabel == "REVIEW")
        #expect(node.summary == "sonnet")
        #expect(node.kindColor == BuiltinFlows.fixGitHubIssue.node("gate")?.kindColor)
        #expect(node.acceptsInputs)
    }

    // MARK: Run detail

    @Test func candidateCardsShowTheReview() async throws {
        let window = try await detail([lane("a", review: true), lane("b", review: false), lane("c", review: nil)])
        #expect(try window.element(identifier: "cand.a.review").value == "Review approved")
        #expect(try window.element(identifier: "cand.b.review").value == "Review asked for changes")
        #expect((try? window.element(identifier: "cand.c.review")) == nil)
    }

    // MARK: Activity

    @Test func activityReportsTheReviewVerdict() {
        let before = makeRun("r")
        var after = before
        after.lanes = [lane("a", review: true), lane("b", review: false), lane("c", review: nil)]
        var old = before
        old.lanes = [lane("a", review: nil), lane("b", review: nil), lane("c", review: nil)]
        let items = deriveActivity(old: old, new: after, now: Date())
        #expect(items.map(\.text) == ["review approved candidate a", "review asked for changes on candidate b"])
        #expect(items.map(\.kind) == [.ok, .warn])
        #expect(deriveActivity(old: after, new: after, now: Date()).isEmpty, "an unchanged verdict is not repeated")
    }
}
