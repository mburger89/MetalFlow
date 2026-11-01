import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct GateFixAttemptsTests {
    let repo = URL(fileURLWithPath: "/repo")

    func fixture(runs: [Run] = []) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: runs, repos: [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model, size: metalFlowWindowSize)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.screen = .studio
        try await window.runUntilIdle()
        return (model, client, window)
    }

    func press(_ id: String, in window: TestWindow) async throws {
        try window.click(window.element(identifier: id))
        try await window.runUntilIdle()
    }

    func fixAttempts(_ draft: FlowDraft) -> Int? {
        if case .gate(let c)? = draft.flow.node("gate")?.kind { return c.fixAttempts }
        return nil
    }

    // MARK: Inspector

    @Test func inspectorEditsFixAttemptsAndUndoes() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.gate", in: window)
        _ = try window.element(identifier: "inspector.gate.fixAttempts")
        #expect(fixAttempts(draft) == 2, "the built-in gate allows two fixes")
        let before = draft.flow

        try window.click(window.element(identifier: "inspector.gate.fixAttempts"))
        try window.chooseMenuItem("4")
        try await window.runUntilIdle()
        #expect(fixAttempts(draft) == 4)
        #expect(draft.undoStack.count == 1)
        if case .gate(let c)? = draft.flow.node("gate")?.kind { #expect(c.command == "swift test") }

        window.typeKey("z", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
    }

    @Test func shellNodesHaveNoFixAttemptsControl() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        draft.edit("shell") { flow in
            flow.nodes.append(Node(id: "sh", title: "Sh", kind: .shell(ShellConfig(command: "echo")), position: Point(x: 5, y: 5)))
        }
        draft.selection = "sh"
        try await window.runUntilIdle()
        _ = try window.element(identifier: "inspector.command")
        #expect((try? window.element(identifier: "inspector.gate.fixAttempts")) == nil)
        // The command still edits on a shell node.
        draft.editShell("sh") { $0.command = "ls" }
        #expect(draft.flow.node("sh")?.kind == .shell(ShellConfig(command: "ls")))
    }

    @Test func hintShowsOnlyWithoutAPromptUpstream() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.gate", in: window)
        #expect((try? window.element(identifier: "inspector.gate.fixHint")) == nil, "implement feeds the gate")
        #expect(draft.hasPromptUpstream(of: "gate"))

        draft.edit("unwire") { $0.wires.removeAll { $0.to == "gate" } }
        try await window.runUntilIdle()
        #expect(!draft.hasPromptUpstream(of: "gate"))
        #expect(try window.element(identifier: "inspector.gate.fixHint").value == "Needs a Prompt node feeding this gate.")
    }

    @Test func aPromptFurtherUpstreamCounts() {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.nodes.append(Node(id: "fmt", title: "Fmt", kind: .shell(ShellConfig(command: "x")), position: Point(x: 1, y: 1)))
        flow.wires.removeAll { $0.to == "gate" }
        flow.wires.append(Wire(from: "implement", to: "fmt", input: "code"))
        flow.wires.append(Wire(from: "fmt", to: "gate", input: "fmt"))
        let draft = FlowDraft(flow: flow, location: .unsaved)
        #expect(draft.hasPromptUpstream(of: "gate"))
        #expect(!draft.hasPromptUpstream(of: "plan"), "plan is fed by the issue and repo only")
    }

    // MARK: Status text

    @Test func stateStyleReadsFixAttempts() {
        let fix = Run.FixProgress(used: 1, of: 2)
        #expect(NodeStateStyle(.waiting, fix: fix).text == "Waiting: Fix 1 of 2")
        #expect(NodeStateStyle(.running, fix: fix).detail == "Fix 1 of 2")
        #expect(NodeStateStyle(.failed("boom"), fix: fix).detail == "boom", "a failure message wins")
        #expect(NodeStateStyle(.running).text == "Running")
    }

    @Test func runDetailRowShowsFixCount() async throws {
        let run = makeRun("fixing", status: .running, nodes: [
            NodeKey(node: "gate", lane: "a"): NodeRun(state: .running, fixAttemptsUsed: 1),
            NodeKey(node: "gate", lane: "b"): NodeRun(state: .succeeded)])
        let client = FakeEngineClient(restored: [run], repos: [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.open(run: run.id)
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "detail.node.gate@a.state").value == "Running: Fix 1 of 2")
        #expect(try window.element(identifier: "detail.node.gate@b.state").value == "Done")
    }

    @Test func plainCanvasOverlayShowsFixCountAndLaneOverlayDoesNot() {
        let gate = BuiltinFlows.fixGitHubIssue.node("gate")!
        var run = makeRun("o", status: .running, nodes: [
            NodeKey(node: "gate"): NodeRun(state: .waiting, fixAttemptsUsed: 1),
            NodeKey(node: "gate", lane: "a"): NodeRun(state: .waiting, fixAttemptsUsed: 1)])
        run.lanes = [Lane(id: "a", model: "sonnet", branch: "b", worktree: URL(fileURLWithPath: "/wt/a"))]
        #expect(NodeOverlay.make(node: gate, run: run, laneScoped: false).text == "Waiting: Fix 1 of 2")
        #expect(NodeOverlay.make(node: gate, run: run, laneScoped: true).text == "A ·")
    }
}
