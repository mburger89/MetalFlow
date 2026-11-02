import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct CanvasSelectionTests {
    let repo = URL(fileURLWithPath: "/repo")

    func fixture(runs: [Run] = []) async throws -> (AppModel, FlowDraft, TestWindow) {
        let client = FakeEngineClient(restored: runs, repos: [repo], gitRepoPaths: [])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model, size: metalFlowWindowSize)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.screen = .studio
        try await window.runUntilIdle()
        return (model, try #require(model.draft), window)
    }

    /// The window position of a canvas point.
    func screen(_ window: TestWindow, _ draft: FlowDraft, _ p: CanvasPoint) throws -> ScreenPoint {
        let origin = try window.element(identifier: "canvas").frame.origin
        let s = draft.geometry.toScreen(p)
        return ScreenPoint(x: origin.x + s.x, y: origin.y + s.y)
    }

    func click(_ id: String, _ modifiers: EventModifiers = [], in window: TestWindow) async throws {
        try window.click(window.element(identifier: id), modifierFlags: modifiers)
        try await window.runUntilIdle()
    }

    func drag(_ window: TestWindow, _ draft: FlowDraft, from: CanvasPoint, to: CanvasPoint,
              _ modifiers: EventModifiers = []) async throws {
        window.drag(from: try screen(window, draft, from), to: try screen(window, draft, to), modifierFlags: modifiers)
        try await window.runUntilIdle()
    }

    func center(_ window: TestWindow, _ id: String) throws -> ScreenPoint {
        let f = try window.element(identifier: id).frame
        return ScreenPoint(x: f.origin.x + f.size.width / 2, y: f.origin.y + f.size.height / 2)
    }

    /// A view with zoom 0.5 and a non-zero pan.
    func zoomedOut(_ draft: FlowDraft, _ window: TestWindow) async throws {
        draft.geometry = CanvasGeometry(pan: ScreenPoint(x: Pixels(30), y: Pixels(20)), zoom: 0.5)
        try await window.runUntilIdle()
    }

    // MARK: Clicks

    @Test func plainClickReplaces() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.gate", in: window)
        #expect(draft.canvasSelection.nodes == ["gate"])
    }

    @Test func shiftClickAdds() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.gate", .shift, in: window)
        #expect(draft.canvasSelection.nodes == ["plan", "gate"])
        try await click("node.gate", .shift, in: window)
        #expect(draft.canvasSelection.nodes == ["plan", "gate"], "shift never removes")
    }

    @Test func commandClickToggles() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.gate", .command, in: window)
        #expect(draft.canvasSelection.nodes == ["plan", "gate"])
        try await click("node.plan", .command, in: window)
        #expect(draft.canvasSelection.nodes == ["gate"])
    }

    @Test func commandWinsOverShift() async throws {
        #expect(SelectionMode([.command, .shift]) == .toggle)
        #expect(SelectionMode(.shift) == .add)
        #expect(SelectionMode([]) == .replace)
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.plan", [.command, .shift], in: window)
        #expect(draft.canvasSelection.isEmpty)
    }

    @Test func clickOnEmptyCanvasClearsWithoutModifiers() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.gate", .shift, in: window)
        try window.click(at: screen(window, draft, CanvasPoint(x: 400, y: 700)))
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.isEmpty)
    }

    @Test func shiftClickOnEmptyCanvasKeepsSelection() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.gate", .shift, in: window)
        let empty = try screen(window, draft, CanvasPoint(x: 400, y: 700))
        window.click(at: empty, modifierFlags: .shift)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.nodes == ["plan", "gate"])
        window.click(at: empty, modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.nodes == ["plan", "gate"])
    }

    @Test func aWireClickClearsNodesAndAShiftClickOnAWireDoesNotAddIt() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.issue", in: window)
        try await click("node.gate", .shift, in: window)
        let a = draft.geometry.outPort(try #require(draft.flow.node("plan")))
        let b = draft.geometry.inPort(try #require(draft.flow.node("implement")))
        let mid = try screen(window, draft, CanvasPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        window.click(at: mid, modifierFlags: .shift)
        try await window.runUntilIdle()
        let wire = Wire(from: "plan", to: "implement", input: "plan")
        #expect(draft.canvasSelection == CanvasSelection(nodes: [], wire: wire))
        #expect(draft.selection == nil)
        #expect(draft.selectedWire == wire)
    }

    // MARK: Boxes

    @Test func plainDragOnEmptyCanvasDrawsABoxAndDoesNotPan() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        try await click("node.issue", in: window)
        let before = draft.geometry
        let from = try screen(window, draft, CanvasPoint(x: 250, y: 120))
        let to = try screen(window, draft, CanvasPoint(x: 720, y: 340))
        window.drag(from: from, to: to)
        try await window.runUntilIdle()
        #expect(draft.geometry == before, "a plain drag no longer pans")
        #expect(draft.canvasSelection.nodes == ["plan", "implement"], "the box replaces, and any overlap selects")
        #expect(draft.selectionBox == nil, "the box is gone after the drag")
        #expect(draft.undoStack.isEmpty)
    }

    @Test func theBoxShowsWhileDragging() async throws {
        let (_, draft, _) = try await fixture()
        draft.geometry = CanvasGeometry()
        let start = ScreenPoint(x: Pixels(300), y: Pixels(500))
        draft.primaryDragChanged(.init(startLocation: start, location: ScreenPoint(x: Pixels(350), y: Pixels(530))))
        #expect(draft.selectionBox == CanvasRect(x: 300, y: 500, w: 50, h: 30))
        draft.primaryDragChanged(.init(startLocation: start, location: ScreenPoint(x: Pixels(290), y: Pixels(494))))
        #expect(draft.selectionBox == CanvasRect(x: 290, y: 494, w: 10, h: 6), "a box dragged up and left is normalised")
        draft.primaryDragEnded(.init(startLocation: start, location: ScreenPoint(x: Pixels(290), y: Pixels(494))))
        #expect(draft.selectionBox == nil)
    }

    @Test func shiftBoxAddsCommandBoxToggles() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        try await click("node.plan", in: window)
        try await drag(window, draft, from: CanvasPoint(x: 480, y: 160), to: CanvasPoint(x: 800, y: 340), .shift)
        #expect(draft.canvasSelection.nodes == ["plan", "implement", "gate"])
        try await drag(window, draft, from: CanvasPoint(x: 480, y: 160), to: CanvasPoint(x: 800, y: 340), .command)
        #expect(draft.canvasSelection.nodes == ["plan"], "toggling the boxed nodes out leaves the rest")
    }

    @Test func geometryFindsNodesThatOverlapABox() throws {
        let g = CanvasGeometry()
        let flow = BuiltinFlows.fixGitHubIssue
        #expect(Set(g.nodes(in: CanvasRect(x: 460, y: 200, w: 10, h: 10), flow: flow)) == ["plan"])
        #expect(Set(g.nodes(in: CanvasRect(x: 440, y: 200, w: 100, h: 10), flow: flow)) == ["plan", "implement"])
        #expect(g.nodes(in: CanvasRect(x: 0, y: 700, w: 5, h: 5), flow: flow).isEmpty)
    }

    // MARK: Dragging nodes

    @Test func draggingASelectedNodeMovesAllSelectedAsOneUndo() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.implement", .shift, in: window)
        let before = draft.flow
        let from = try center(window, "node.plan")
        window.drag(from: from, to: ScreenPoint(x: from.x + 60, y: from.y + 40))
        try await window.runUntilIdle()
        let z = draft.geometry.zoom
        for id: NodeID in ["plan", "implement"] {
            let moved = try #require(draft.flow.node(id)), was = try #require(before.node(id))
            #expect(abs(moved.position.x - was.position.x - 60 / z) < 1.5)
            #expect(abs(moved.position.y - was.position.y - 40 / z) < 1.5)
        }
        #expect(draft.flow.node("gate") == before.node("gate"))
        #expect(draft.canvasSelection.nodes == ["plan", "implement"])
        #expect(draft.undoStack.count == 1)
        draft.undo()
        #expect(draft.flow == before)
    }

    @Test func draggingAnUnselectedNodeSelectsOnlyIt() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.issue", .shift, in: window)
        let from = try center(window, "node.gate")
        window.drag(from: from, to: ScreenPoint(x: from.x + 30, y: from.y + 30))
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.nodes == ["gate"])
        #expect(draft.flow.node("plan") == BuiltinFlows.fixGitHubIssue.node("plan"), "the old selection stayed put")
        #expect(draft.undoStack.count == 1)
    }

    @Test func shiftDraggingAnUnselectedNodeAddsIt() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        let from = try center(window, "node.gate")
        window.drag(from: from, to: ScreenPoint(x: from.x + 30, y: from.y + 30), modifierFlags: .shift)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.nodes == ["plan", "gate"])
        #expect(draft.flow.node("plan") != BuiltinFlows.fixGitHubIssue.node("plan"), "both moved")
        #expect(draft.flow.node("gate") != BuiltinFlows.fixGitHubIssue.node("gate"))
        #expect(draft.undoStack.count == 1)
    }

    // MARK: Delete, undo, keys

    @Test func deleteRemovesAllSelectedAndTheirWiresAsOneUndo() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.implement", .shift, in: window)
        window.typeKey(.delete)
        try await window.runUntilIdle()
        #expect(draft.flow.node("plan") == nil && draft.flow.node("implement") == nil)
        #expect(!draft.flow.wires.contains { ["plan", "implement"].contains($0.from) || ["plan", "implement"].contains($0.to) })
        #expect(draft.flow.nodes.count == BuiltinFlows.fixGitHubIssue.nodes.count - 2)
        #expect(draft.canvasSelection.isEmpty)
        #expect(draft.undoStack.count == 1)
        window.typeKey("z", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
    }

    @Test func undoDropsStaleSelection() async throws {
        let (_, draft, window) = try await fixture()
        let added = draft.addNode(.shell)
        draft.canvasSelection = CanvasSelection(nodes: [added, "plan"])
        draft.undo()
        #expect(draft.flow.node(added) == nil)
        #expect(draft.canvasSelection.nodes == ["plan"])
        _ = window
    }

    @Test func selectAllSelectsEveryNode() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        window.typeKey("a", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.nodes == Set(draft.flow.nodes.map(\.id)))
        #expect(draft.selection == nil)
    }

    @Test func escapeClearsSelection() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.gate", .shift, in: window)
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.isEmpty)
    }

    @Test func keysReachTheCanvasWithNothingFocusedAndThePointerOverIt() async throws {
        let (_, draft, window) = try await fixture()
        draft.selection = "plan"
        try await window.runUntilIdle()
        window.hover(at: try center(window, "node.gate"))
        window.typeKey("a", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.nodes.count == draft.flow.nodes.count)
    }

    @Test func selectionBridgeIsNilWithTwoSelected() async throws {
        let (_, draft, _) = try await fixture()
        draft.selection = "plan"
        #expect(draft.selection == "plan")
        draft.canvasSelection.nodes.insert("gate")
        #expect(draft.selection == nil)
        #expect(draft.selectedWire == nil)
        draft.selection = "judge"
        #expect(draft.canvasSelection == CanvasSelection(nodes: ["judge"]))
        draft.selectedWire = Wire(from: "judge", to: "pick", input: "recommendation")
        #expect(draft.canvasSelection.nodes.isEmpty && draft.selection == nil)
    }

    // MARK: Wires and the overlay

    @Test func wiresTouchingAnySelectedNodeHighlight() throws {
        let flow = BuiltinFlows.fixGitHubIssue
        let g = CanvasGeometry()
        let touching = flow.wires.filter { ["plan", "gate"].contains($0.from) || ["plan", "gate"].contains($0.to) }
        var onlyTouching = flow, rest = flow
        onlyTouching.wires = touching
        rest.wires = flow.wires.filter { !touching.contains($0) }
        let paths = WireLayer.paths(flow: flow, geometry: g, selection: ["plan", "gate"], selectedWire: nil)
        #expect(touching.count == 5)
        #expect(paths.selected == WireLayer.paths(flow: onlyTouching, geometry: g, selection: [], selectedWire: nil).all)
        #expect(paths.all == WireLayer.paths(flow: rest, geometry: g, selection: [], selectedWire: nil).all)
    }

    @Test func overlayIsUnchangedWithTwoNodesSelected() async throws {
        let run = laneRun()
        let (model, draft, window) = try await fixture(runs: [run])
        model.studioRun = run.id
        try await window.runUntilIdle()
        let ids = ["plan", "implement", "gate", "pick"]
        let before = try ids.map { try window.element(identifier: "node.\($0).status").value }
        draft.canvasSelection = CanvasSelection(nodes: ["plan", "gate"])
        try await window.runUntilIdle()
        #expect(try ids.map { try window.element(identifier: "node.\($0).status").value } == before)
        _ = try window.element(identifier: "cand.a")
    }

    // MARK: Inspector

    @Test func inspectorShowsCountAndDeleteForTwoNodes() async throws {
        let (_, draft, window) = try await fixture()
        try await click("node.plan", in: window)
        try await click("node.gate", .shift, in: window)
        #expect(try window.element(identifier: "inspector.selectionCount").value == "2 selected")
        #expect((try? window.element(identifier: "inspector.title")) == nil)
        try await click("inspector.deleteSelection", in: window)
        #expect(draft.flow.node("plan") == nil && draft.flow.node("gate") == nil)
        #expect(draft.undoStack.count == 1)
        _ = try window.element(identifier: "inspector.empty")
    }

    @Test func inspectorShowsSettingsForOneNode() async throws {
        let (_, _, window) = try await fixture()
        try await click("node.plan", in: window)
        #expect(try window.element(identifier: "inspector.title").value == "Plan")
        #expect((try? window.element(identifier: "inspector.selectionCount")) == nil)
    }

    func laneRun() -> Run {
        var run = makeRun("#7 lanes", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "a"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "b"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "c"): NodeRun(state: .succeeded),
            NodeKey(node: "gate", lane: "a"): NodeRun(state: .succeeded),
            NodeKey(node: "gate", lane: "b"): NodeRun(state: .running),
            NodeKey(node: "gate", lane: "c"): NodeRun(state: .failed("tests")),
        ])
        run.lanes = [
            Lane(id: "a", model: "sonnet", branch: "mf/x-a", worktree: URL(fileURLWithPath: "/wt/a"), gatePassed: true),
            Lane(id: "b", model: "opus", branch: "mf/x-b", worktree: URL(fileURLWithPath: "/wt/b"), gatePassed: nil),
            Lane(id: "c", model: "haiku", branch: "mf/x-c", worktree: URL(fileURLWithPath: "/wt/c"), gatePassed: false),
        ]
        return run
    }
}
