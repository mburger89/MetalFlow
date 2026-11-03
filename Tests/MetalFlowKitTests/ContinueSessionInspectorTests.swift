import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct ContinueSessionInspectorTests {
    let repo = URL(fileURLWithPath: "/repo")
    static let picker = "inspector.continuesSession"

    func fixture() async throws -> (AppModel, TestWindow) {
        let client = FakeEngineClient(restored: [], repos: [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model, size: metalFlowWindowSize)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.screen = .studio
        try await window.runUntilIdle()
        return (model, window)
    }

    func select(_ id: NodeID, _ draft: FlowDraft, _ window: TestWindow) async throws {
        draft.selection = id
        try await window.runUntilIdle()
    }

    /// The built-in flow plus a plain Prompt after Plan; Implement fans out, so only this one can continue Plan.
    func addFollow(_ draft: FlowDraft) {
        draft.edit("follow") { flow in
            flow.nodes.append(Node(id: "follow", title: "Follow", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "go on", candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 9, y: 9)))
            flow.wires.append(Wire(from: "plan", to: "follow", input: "plan"))
        }
    }

    func continues(_ draft: FlowDraft, _ id: NodeID) -> NodeID? { draft.promptConfig(id)?.continuesSessionOf }

    func menuTitles(_ window: TestWindow) throws -> [String] {
        try window.click(window.element(identifier: Self.picker))
        return try #require(window.presentedMenu).items.map(\.title)
    }

    @Test func pickerShownForPromptAndJudgeNotReview() async throws {
        let (model, window) = try await fixture()
        let draft = try #require(model.draft)
        draft.edit("review") { flow in
            flow.nodes.append(Node(id: "rev", title: "Rev", kind: .review(ReviewConfig(
                agent: PromptConfig(model: "sonnet", prompt: "r", candidates: [], allowedTools: [], maxTurns: nil), fixAttempts: 1)),
                position: Point(x: 9, y: 9)))
        }
        for id: NodeID in ["plan", "implement", "judge"] {
            try await select(id, draft, window)
            _ = try window.element(identifier: Self.picker)
        }
        try await select("rev", draft, window)
        #expect((try? window.element(identifier: Self.picker)) == nil)
        try await select("gate", draft, window)
        #expect((try? window.element(identifier: Self.picker)) == nil)
    }

    @Test func listsNewSessionThenSources() async throws {
        let (model, window) = try await fixture()
        let draft = try #require(model.draft)
        addFollow(draft)
        try await select("plan", draft, window)
        #expect(try menuTitles(window) == ["New session"])
        try window.chooseMenuItem("New session")
        try await select("follow", draft, window)
        #expect(try menuTitles(window) == ["New session", "Plan"])
        #expect(try #require(window.presentedMenu).items.first?.isOn == true)
    }

    @Test func choosingSetsTheFieldAsOneUndoStep() async throws {
        let (model, window) = try await fixture()
        let draft = try #require(model.draft)
        addFollow(draft)
        try await select("follow", draft, window)
        let before = draft.flow
        let steps = draft.undoStack.count
        _ = try menuTitles(window)
        try window.chooseMenuItem("Plan")
        try await window.runUntilIdle()
        #expect(continues(draft, "follow") == "plan")
        #expect(draft.undoStack.count == steps + 1)
        draft.undo()
        #expect(draft.flow == before)

        draft.redo()
        _ = try menuTitles(window)
        try window.chooseMenuItem("New session")
        try await window.runUntilIdle()
        #expect(continues(draft, "follow") == nil)
        #expect(draft.undoStack.count == steps + 2)
    }

    @Test func invalidCurrentValueStaysVisible() async throws {
        let (model, window) = try await fixture()
        let draft = try #require(model.draft)
        addFollow(draft)
        draft.setContinuesSession(of: "follow", from: "plan")
        draft.edit("unwire") { $0.wires.removeAll { $0.from == "plan" && $0.to == "follow" } }
        try await select("follow", draft, window)
        #expect(try menuTitles(window) == ["New session", "Plan"])
        let items = try #require(window.presentedMenu).items
        #expect(items.last?.isOn == true)
        try window.chooseMenuItem("Plan")
        try await window.runUntilIdle()
        let banner = try window.element(identifier: "studio.validation").value
        #expect(banner == "Follow can only continue the session of a Prompt that runs before it.")
    }

    @Test func deletingTheSourceClearsItInOneUndoStep() async throws {
        let (model, _) = try await fixture()
        let draft = try #require(model.draft)
        addFollow(draft)
        draft.setContinuesSession(of: "follow", from: "plan")
        let before = draft.flow
        let steps = draft.undoStack.count
        draft.deleteNode("plan")
        #expect(continues(draft, "follow") == nil)
        #expect(draft.flow.node("plan") == nil)
        #expect(draft.undoStack.count == steps + 1)
        draft.undo()
        #expect(draft.flow == before)
        #expect(continues(draft, "follow") == "plan")

        draft.canvasSelection.nodes = ["plan"]
        draft.deleteSelection()
        #expect(continues(draft, "follow") == nil)
        draft.undo()
        #expect(draft.flow == before)

        draft.canvasSelection.nodes = ["plan", "gate"]
        draft.deleteSelection()
        #expect(continues(draft, "follow") == nil)
        draft.undo()
        #expect(draft.flow == before)
    }

    @Test func judgeCanContinueANonLanePrompt() async throws {
        let (model, window) = try await fixture()
        let draft = try #require(model.draft)
        try await select("judge", draft, window)
        #expect(try menuTitles(window) == ["New session", "Plan"])
        try window.chooseMenuItem("Plan")
        try await window.runUntilIdle()
        #expect(continues(draft, "judge") == "plan")
        #expect(draft.plan != nil)
    }
}
