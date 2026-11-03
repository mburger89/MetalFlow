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
        let run = seeded()
        let client = FakeEngineClient(restored: [run], repos: [URL(fileURLWithPath: "/repo")])
        await client.setElsewhere([run.id])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.runningElsewhere.insert(run.id)
        model.open(run: run.id)
        try await window.runUntilIdle()
        #expect(run.canFollowUp(implementA), "the engine rule alone would offer it")
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

    @Test func blockedFollowUpShowsTheNoticeAndKeepsTheDraft() async throws {
        let run = seeded()
        let (model, client, window) = try await fixture(run)
        let message = "Answer the question on \"Implement\" first, then send this."
        await client.setFailure(RunEngineError.followUpBlocked(message))
        try await press("detail.node.judge.followUp", in: window)
        let id = field(run, judge)
        try window.click(window.element(identifier: "\(id).field"))
        window.typeText("Explain")
        try await window.runUntilIdle()
        try await press("\(id).send", in: window)
        #expect(model.notice?.text == message)
        #expect(model.followUpDrafts[AppModel.draftKey(run.id, judge)] == "Explain")
        #expect(model.followingUp.contains(AppModel.draftKey(run.id, judge)), "the box stays open")
        _ = try window.element(identifier: "\(id).field")
    }

    @Test func returnSendsAFollowUp() async throws {
        let run = seeded()
        let (model, client, window) = try await fixture(run)
        try await press("detail.node.implement@a.followUp", in: window)
        let id = field(run, implementA)
        try window.click(window.element(identifier: "\(id).field"))
        window.typeText("Add tests")
        window.typeKey(.return)
        try await window.runUntilIdle()
        #expect(await client.calls.filter { $0.hasPrefix("followUp") } == ["followUp(implement@a, Add tests)"])
        #expect(model.followUpDrafts[AppModel.draftKey(run.id, implementA)] == nil)
    }

    @Test func returnOnBlankSendsNothing() async throws {
        let run = seeded()
        let (_, client, window) = try await fixture(run)
        try await press("detail.node.implement@a.followUp", in: window)
        let id = field(run, implementA)
        try window.click(window.element(identifier: "\(id).field"))
        window.typeKey(.return)
        window.typeText("   ")
        window.typeKey(.return)
        try await window.runUntilIdle()
        #expect(await !client.calls.contains { $0.hasPrefix("followUp") })
    }

    @Test func returnWhileSendingSendsNothing() async throws {
        let run = seeded()
        let (model, client, window) = try await fixture(run)
        let key = AppModel.draftKey(run.id, implementA)
        let id = field(run, implementA)
        await client.holdFollowUps()
        try await press("detail.node.implement@a.followUp", in: window)
        try window.click(window.element(identifier: "\(id).field"))
        window.typeText("first")
        window.typeKey(.return)
        try await window.runUntil { model.followUpSending.contains(key) }
        window.typeText(" second")
        window.typeKey(.return)
        try await window.runUntilIdle()
        await client.releaseFollowUps()
        try await window.runUntilIdle()
        #expect(await client.calls.filter { $0.hasPrefix("followUp") } == ["followUp(implement@a, first)"])
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

    @Test func textTypedWhileSendingSurvives() async throws {
        let run = seeded()
        let (model, client, window) = try await fixture(run)
        let key = AppModel.draftKey(run.id, implementA)
        await client.holdFollowUps()
        model.toggleFollowUp(run: run.id, node: implementA)
        model.followUpDrafts[key] = "first"
        let task = Task { await model.sendFollowUp(run: run.id, node: implementA) }
        try await window.runUntil { model.followUpSending.contains(key) }
        model.followUpDrafts[key] = "second"
        await client.releaseFollowUps()
        #expect(await task.value)
        #expect(model.followUpDrafts[key] == "second")
        #expect(!model.followingUp.contains(key))
        #expect(await client.calls.filter { $0.hasPrefix("followUp") } == ["followUp(implement@a, first)"])
    }

    @Test func unchangedDraftIsClearedAfterSending() async throws {
        let run = seeded()
        let (model, client, window) = try await fixture(run)
        let key = AppModel.draftKey(run.id, implementA)
        await client.holdFollowUps()
        model.followUpDrafts[key] = "only"
        let task = Task { await model.sendFollowUp(run: run.id, node: implementA) }
        try await window.runUntil { model.followUpSending.contains(key) }
        await client.releaseFollowUps()
        #expect(await task.value)
        #expect(model.followUpDrafts[key] == nil)
    }

    @Test func aSecondSendWhileInFlightDoesNothing() async throws {
        let run = seeded()
        let (model, client, window) = try await fixture(run)
        let key = AppModel.draftKey(run.id, implementA)
        let id = field(run, implementA)
        await client.holdFollowUps()
        model.toggleFollowUp(run: run.id, node: implementA)
        model.followUpDrafts[key] = "go"
        try await window.runUntilIdle()
        let task = Task { await model.sendFollowUp(run: run.id, node: implementA) }
        try await window.runUntil { model.followUpSending.contains(key) }
        try await window.runUntilIdle()
        #expect(try !window.element(identifier: "\(id).send").isEnabled)
        let second = Task { await model.sendFollowUp(run: run.id, node: implementA) }
        await client.releaseFollowUps()
        #expect(await task.value)
        #expect(await !second.value)
        #expect(await client.calls.filter { $0.hasPrefix("followUp") }.count == 1)
        #expect(model.followUpSending.isEmpty)
    }

    @Test func anOpenBoxClosesWhenTheStepStopsBeingFollowable() async throws {
        let run = seeded()
        let (model, _, window) = try await fixture(run)
        let key = AppModel.draftKey(run.id, implementA)
        model.toggleFollowUp(run: run.id, node: implementA)
        model.followUpDrafts[key] = "keep"
        var running = run
        running.status = .running
        running.revision += 1
        model.apply(running)
        #expect(!model.followingUp.contains(key))
        var back = run
        back.revision += 2
        model.apply(back)
        try await window.runUntilIdle()
        #expect(!model.followingUp.contains(key), "it does not reopen by itself")
        #expect((try? window.element(identifier: "\(field(run, implementA)).field")) == nil)
        #expect(model.followUpDrafts[key] == "keep")
    }
}
