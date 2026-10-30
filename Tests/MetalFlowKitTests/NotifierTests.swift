import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct NotifierTests {
    func pick(_ title: String = "pick", id: RunID = RunID(), revision: Int = 0, status: RunStatus = .needsYou) -> Run {
        makeRun(title, status: status, revision: revision, id: id, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))])
    }

    func fixture(restored: [Run] = []) async throws -> (AppModel, FakeEngineClient, RecordingNotifier, TestWindow) {
        let client = FakeEngineClient(restored: restored, repos: [URL(fileURLWithPath: "/repo")])
        let notifier = RecordingNotifier()
        let model = AppModel(client: client, notifier: notifier)
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        await model.flushNotifications()
        return (model, client, notifier, window)
    }

    @Test func postsWhenRunNeedsYouAndClearsAfter() async throws {
        let (model, _, notifier, _) = try await fixture()
        let id = RunID()
        model.apply(makeRun("fix 68", status: .running, id: id))
        model.apply(pick("fix 68", id: id, revision: 1))
        await model.flushNotifications()
        #expect(notifier.posts == [.post(id: id.rawValue, title: "fix 68", body: "Judge recommends b — pick a candidate")])
        model.apply(makeRun("fix 68", status: .completed, revision: 2, id: id))
        await model.flushNotifications()
        #expect(notifier.removes == [id.rawValue])
        // A second update inside needs-you does not post again.
        let again = RunID()
        model.apply(pick("x", id: again))
        model.apply(pick("x", id: again, revision: 1))
        await model.flushNotifications()
        #expect(notifier.posts.count == 2)
    }

    @Test func noPostForOpenRun() async throws {
        let (model, _, notifier, _) = try await fixture()
        let id = RunID()
        model.apply(makeRun("open", status: .running, id: id))
        model.open(run: id)
        model.apply(pick("open", id: id, revision: 1))
        await model.flushNotifications()
        #expect(notifier.posts.isEmpty)
        #expect(notifier.badges.last == 1)
        // With the Studio showing, the detail is not open, so it posts.
        let other = RunID()
        model.apply(makeRun("other", status: .running, id: other))
        model.open(run: other)
        model.screen = .studio
        model.apply(pick("other", id: other, revision: 1))
        await model.flushNotifications()
        #expect(notifier.posts.count == 1)
    }

    @Test func openingDetailRemovesNotification() async throws {
        let (model, _, notifier, _) = try await fixture()
        let id = RunID()
        model.apply(makeRun("r", status: .running, id: id))
        model.apply(pick("r", id: id, revision: 1))
        model.selectedRun = id
        await model.flushNotifications()
        #expect(notifier.posts.count == 1)
        #expect(notifier.removes == [id.rawValue])
    }

    @Test func badgeTracksNeedsYouCount() async throws {
        let (model, _, notifier, _) = try await fixture()
        let a = RunID(), b = RunID()
        model.apply(pick("a", id: a))
        model.apply(pick("b", id: b))
        model.apply(makeRun("a", status: .merged("a"), revision: 1, id: a))
        model.apply(makeRun("b", status: .discarded, revision: 1, id: b))
        await model.flushNotifications()
        #expect(notifier.badges == [1, 2, 1, 0])
    }

    @Test func restoreDoesNotPost() async throws {
        let (_, _, notifier, _) = try await fixture(restored: [pick("a"), pick("b")])
        #expect(notifier.posts.isEmpty)
        #expect(notifier.badges == [2])
    }

    @Test func clickOpensRun() async throws {
        let (model, _, notifier, window) = try await fixture()
        var activations = 0
        model.activateApp = { activations += 1 }
        let id = RunID()
        model.apply(makeRun("clicked", status: .running, id: id))
        model.screen = .studio
        notifier.click(id.rawValue)
        await model.flushNotifications()
        // The click is consumed by a task; wait for its effect through the model.
        while model.selectedRun != id { await Task.yield() }
        try await window.runUntilIdle()
        #expect(model.screen == .dashboard)
        #expect(model.selectedRun == id)
        #expect(model.workingOn.contains(.run(id)))
        #expect(activations == 1)
    }

    @Test func postNeverActivates() async throws {
        let (model, _, notifier, _) = try await fixture()
        var activations = 0
        model.activateApp = { activations += 1 }
        let id = RunID()
        model.apply(makeRun("r", status: .running, id: id))
        model.apply(pick("r", id: id, revision: 1))
        model.apply(makeRun("r", status: .completed, revision: 2, id: id))
        await model.flushNotifications()
        #expect(notifier.posts.count == 1)
        #expect(activations == 0)
    }

    @Test func bodyTextPerReason() {
        func body(_ nodes: [NodeKey: NodeRun], status: RunStatus = .needsYou) -> String {
            AppModel.notificationBody(for: makeRun("r", status: status, nodes: nodes))
        }
        #expect(body([NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))])
            == "Judge recommends b — pick a candidate")
        #expect(body([NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: nil, allGatesFailed: false)))])
            == "Pick a candidate")
        #expect(body([NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: nil, allGatesFailed: true)))])
            == "Gate failed on every candidate")
        #expect(body([NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?\nsecond line")))])
            == "Plan asks: Which file?")
        let long = String(repeating: "x", count: 300)
        #expect(body([NodeKey(node: "plan"): NodeRun(state: .needsYou(.question(long)))])
            == "Plan asks: " + String(repeating: "x", count: 120))
        #expect(body([NodeKey(node: "plan"): NodeRun(state: .needsYou(.deniedTools(["Bash", "Edit"])))])
            == "Plan needs permission: Bash, Edit")
        #expect(body([NodeKey(node: "plan"): NodeRun(state: .interrupted)]) == "Interrupted — resume when ready")
        #expect(body([NodeKey(node: "gate", lane: "a"): NodeRun(state: .failed("nope"))], status: .failed("x"))
            == "swift test failed — retry when ready")
        // First in plan order wins.
        #expect(body([NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "a", allGatesFailed: false))),
                      NodeKey(node: "plan"): NodeRun(state: .interrupted)]) == "Interrupted — resume when ready")
    }
}
