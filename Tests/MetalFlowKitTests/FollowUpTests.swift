import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct FollowUpTests {
    let implementA = NodeKey(node: "implement", lane: "a")
    let judge = NodeKey(node: "judge")
    let plan = NodeKey(node: "plan")
    let gateA = NodeKey(node: "gate", lane: "a")

    func finished() -> NodeRun { NodeRun(state: .succeeded, output: "done", sessionID: "s1") }

    /// A fan-out run waiting at the pick, with finished steps before and after the split.
    func seeded(status: RunStatus = .needsYou) -> Run {
        makeRun("follow", status: status, nodes: [
            plan: finished(), implementA: finished(), judge: finished(),
            gateA: finished(),
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "a", allGatesFailed: false)))])
    }

    func fixture(_ run: Run) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: [run], repos: [URL(fileURLWithPath: "/repo")])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.open(run: run.id)
        try await window.runUntilIdle()
        return (model, client, window)
    }

    func press(_ id: String, in window: TestWindow) async throws {
        try window.click(window.element(identifier: id))
        try await window.runUntilIdle()
    }

    func field(_ run: Run, _ key: NodeKey) -> String { "followUp.\(run.id.rawValue).\(key)" }

    @Test func offeredOnAFinishedPrompt() async throws {
        let run = seeded()
        let (_, _, window) = try await fixture(run)
        _ = try window.element(identifier: "detail.node.implement@a.followUp")
        _ = try window.element(identifier: "detail.node.judge.followUp")
        #expect((try? window.element(identifier: "\(field(run, implementA)).field")) == nil, "closed until pressed")
    }

    @Test func notOfferedOnGate() async throws {
        let (_, _, window) = try await fixture(seeded())
        #expect((try? window.element(identifier: "detail.node.gate@a.followUp")) == nil)
    }

    @Test func notOfferedOnceMerged() async throws {
        var run = seeded(status: .running)
        run.status = .merged("a")
        let (_, _, window) = try await fixture(run)
        #expect((try? window.element(identifier: "detail.node.implement@a.followUp")) == nil)
    }

    @Test func followUpNotOfferedBeforeCandidatesSplit() async throws {
        let (_, _, window) = try await fixture(seeded())
        #expect((try? window.element(identifier: "detail.node.plan.followUp")) == nil)
        _ = try window.element(identifier: "detail.node.implement@a.followUp")
    }

    @Test func notOfferedWhileRunningElsewhere() async throws {
        var run = seeded(status: .running)
        run.status = .running
        let client = FakeEngineClient(restored: [run], repos: [URL(fileURLWithPath: "/repo")])
        await client.setElsewhere([run.id])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.open(run: run.id)
        try await window.runUntilIdle()
        #expect(model.runningElsewhere.contains(run.id))
        #expect((try? window.element(identifier: "detail.node.implement@a.followUp")) == nil)
    }

    @Test func notOfferedWhileRunningHere() async throws {
        var run = seeded()
        run.status = .running
        let (_, _, window) = try await fixture(run)
        #expect((try? window.element(identifier: "detail.node.implement@a.followUp")) == nil)
    }

    @Test func pressingShowsFieldAndHint() async throws {
        let run = seeded()
        let (model, _, window) = try await fixture(run)
        try await press("detail.node.implement@a.followUp", in: window)
        let id = field(run, implementA)
        _ = try window.element(identifier: "\(id).field")
        #expect(try window.element(identifier: "\(id).hint").value == "The steps after this one run again.")
        #expect(model.followingUp.contains(AppModel.draftKey(run.id, implementA)))
        try await press("detail.node.implement@a.followUp", in: window)
        #expect((try? window.element(identifier: "\(id).field")) == nil, "pressing again closes")
    }

    @Test func sendDisabledWhenEmpty() async throws {
        let run = seeded()
        let (_, client, window) = try await fixture(run)
        try await press("detail.node.implement@a.followUp", in: window)
        let id = field(run, implementA)
        #expect(try !window.element(identifier: "\(id).send").isEnabled)
        try window.click(window.element(identifier: "\(id).field"))
        window.typeText("   ")
        try await window.runUntilIdle()
        #expect(try !window.element(identifier: "\(id).send").isEnabled)
        #expect(await !client.calls.contains { $0.hasPrefix("followUp") })
    }

    @Test func sendGoesToTheEngineAndClosesTheBox() async throws {
        let run = seeded()
        let (model, client, window) = try await fixture(run)
        try await press("detail.node.implement@a.followUp", in: window)
        let id = field(run, implementA)
        try window.click(window.element(identifier: "\(id).field"))
        window.typeText("  Add tests \n")
        try await window.runUntilIdle()
        try await press("\(id).send", in: window)
        #expect(await client.calls.filter { $0.hasPrefix("followUp") } == ["followUp(implement@a, Add tests)"])
        #expect(model.followUpDrafts[AppModel.draftKey(run.id, implementA)] == nil)
        #expect(!model.followingUp.contains(AppModel.draftKey(run.id, implementA)))
        #expect((try? window.element(identifier: "\(id).field")) == nil)
        #expect(model.notice == nil)
    }

    @Test func refusalKeepsTheText() async throws {
        let run = seeded()
        let (model, client, window) = try await fixture(run)
        await client.setFailure(FakeFailure())
        try await press("detail.node.implement@a.followUp", in: window)
        let id = field(run, implementA)
        try window.click(window.element(identifier: "\(id).field"))
        window.typeText("Add tests")
        try await window.runUntilIdle()
        try await press("\(id).send", in: window)
        #expect(model.notice?.text == "engine said no")
        #expect(model.followUpDrafts[AppModel.draftKey(run.id, implementA)] == "Add tests")
        #expect(model.followingUp.contains(AppModel.draftKey(run.id, implementA)), "the box stays open")
        _ = try window.element(identifier: "\(id).field")
    }

    @Test func closingKeepsTheDraft() async throws {
        let run = seeded()
        let (model, _, window) = try await fixture(run)
        try await press("detail.node.implement@a.followUp", in: window)
        let id = field(run, implementA)
        try window.click(window.element(identifier: "\(id).field"))
        window.typeText("later")
        try await window.runUntilIdle()
        try await press("detail.node.implement@a.followUp", in: window)
        #expect((try? window.element(identifier: "\(id).field")) == nil)
        #expect(model.followUpDrafts[AppModel.draftKey(run.id, implementA)] == "later")
        try await press("detail.node.implement@a.followUp", in: window)
        #expect(try window.element(identifier: "\(id).field").value == "later")
    }
}
