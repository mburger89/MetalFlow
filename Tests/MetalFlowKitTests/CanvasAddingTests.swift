import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct CanvasAddingTests {
    let repo = URL(fileURLWithPath: "/repo")

    func fixture() async throws -> (AppModel, FlowDraft, TestWindow) {
        let client = FakeEngineClient(restored: [], repos: [repo], gitRepoPaths: [])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model, size: metalFlowWindowSize)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.screen = .studio
        try await window.runUntilIdle()
        return (model, try #require(model.draft), window)
    }

    func center(_ window: TestWindow, _ id: String) throws -> ScreenPoint {
        let f = try window.element(identifier: id).frame
        return ScreenPoint(x: f.origin.x + f.size.width / 2, y: f.origin.y + f.size.height / 2)
    }

    func offset(_ p: ScreenPoint, _ dx: Float, _ dy: Float) -> ScreenPoint {
        ScreenPoint(x: p.x + Pixels(dx), y: p.y + Pixels(dy))
    }

    /// A view with zoom 0.5 and a non-zero pan.
    func zoomedOut(_ draft: FlowDraft, _ window: TestWindow) async throws {
        draft.geometry = CanvasGeometry(pan: ScreenPoint(x: Pixels(30), y: Pixels(20)), zoom: 0.5)
        try await window.runUntilIdle()
    }

    /// The centre of `id`'s card in canvas units.
    func nodeCentre(_ draft: FlowDraft, _ id: NodeID) throws -> CanvasPoint {
        let node = try #require(draft.flow.node(id))
        let r = draft.geometry.nodeRect(node)
        return CanvasPoint(x: r.x + r.w / 2, y: r.y + r.h / 2)
    }

    func expectCentre(_ draft: FlowDraft, _ id: NodeID, at point: ScreenPoint) throws {
        let want = draft.geometry.toCanvas(point)
        let got = try nodeCentre(draft, id)
        #expect(abs(got.x - want.x) <= 0.5 && abs(got.y - want.y) <= 0.5, "centre \(got) is not \(want)")
    }

    func newNode(_ draft: FlowDraft, before: Flow) throws -> NodeID {
        let added = draft.flow.nodes.filter { before.node($0.id) == nil }
        #expect(added.count == 1)
        return try #require(added.first).id
    }

    func openPane(_ draft: FlowDraft, _ window: TestWindow, at point: ScreenPoint? = nil) async throws {
        window.hover(at: try point ?? center(window, "node.gate"))
        window.typeKey(.tab)
        try await window.runUntilIdle()
    }

    // MARK: Dragging from the palette

    @Test func dropCentresTheNodeUnderPanAndZoom() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let canvas = try window.element(identifier: "canvas").frame
        #expect(draft.canvasFrame == canvas, "the frame comes from the canvas's own geometry")
        #expect(canvas.origin.x > 0 && canvas.origin.y > 0)
        let before = draft.flow
        let drop = ScreenPoint(x: canvas.origin.x + 300, y: canvas.origin.y + 200)
        window.drag(from: try center(window, "palette.shell"), to: drop)
        try await window.runUntilIdle()
        let id = try newNode(draft, before: before)
        #expect(draft.flow.node(id)?.title == "Shell")
        try expectCentre(draft, id, at: ScreenPoint(x: Pixels(300), y: Pixels(200)))
    }

    @Test func dropOutsideTheCanvasAddsNothing() async throws {
        let (_, draft, window) = try await fixture()
        let before = draft.flow
        window.drag(from: try center(window, "palette.shell"), to: try center(window, "studio.name"))
        try await window.runUntilIdle()
        #expect(draft.flow == before)
        #expect(draft.paletteDrag == nil)
        // And model-level, just outside the canvas's left edge.
        let frame = try #require(draft.canvasFrame)
        let far = ScreenPoint(x: frame.origin.x, y: frame.origin.y + 50)
        #expect(draft.endPaletteDrag(.shell, from: offset(far, -100, 0), at: offset(far, -1, 0)) == nil)
        #expect(draft.flow == before)
    }

    @Test func aShortDragIsAClickAndAddsAtTheCentre() async throws {
        let (_, draft, window) = try await fixture()
        let before = draft.flow
        let row = try center(window, "palette.shell")
        window.drag(from: row, to: offset(row, 2, 0))
        try await window.runUntilIdle()
        let id = try newNode(draft, before: before)
        let size = try #require(draft.canvasSize)
        try expectCentre(draft, id, at: ScreenPoint(x: size.width / 2, y: size.height / 2))
        #expect(draft.paletteDrag == nil)
        // Below the threshold nothing is drawn under the pointer.
        draft.movePaletteDrag(.gate, from: row, to: offset(row, 3, 0))
        #expect(draft.paletteDrag == nil)
        draft.movePaletteDrag(.gate, from: row, to: offset(row, 5, 0))
        #expect(draft.paletteDrag == PaletteDrag(kind: .gate, windowPoint: offset(row, 5, 0)))
        // Once dragging, coming back within the threshold keeps it a drag.
        draft.movePaletteDrag(.gate, from: row, to: offset(row, 1, 0))
        #expect(draft.paletteDrag != nil)
    }

    @Test func dropIsOneUndoAndSelectsTheNode() async throws {
        let (_, draft, window) = try await fixture()
        let before = draft.flow
        let canvas = try #require(draft.canvasFrame)
        window.drag(from: try center(window, "palette.gate"),
                    to: ScreenPoint(x: canvas.origin.x + 100, y: canvas.origin.y + 100))
        try await window.runUntilIdle()
        let id = try newNode(draft, before: before)
        #expect(draft.selection == id)
        #expect(draft.undoStack.count == 1)
        draft.undo()
        #expect(draft.flow == before)
        #expect(draft.canvasSelection.isEmpty, "the stale selection is dropped")
    }

    @Test func cancelledDragAddsNothing() async throws {
        let (_, draft, window) = try await fixture()
        let before = draft.flow
        let frame = try #require(draft.canvasFrame)
        let start = ScreenPoint(x: frame.origin.x - 50, y: frame.origin.y + 50)
        draft.movePaletteDrag(.shell, from: start, to: offset(frame.origin, 100, 100))
        #expect(draft.paletteDrag?.kind == .shell)
        try await window.runUntilIdle()
        let label = try window.element(identifier: "palette.drag").frame
        #expect(label.contains(offset(frame.origin, 100, 100)), "the label is drawn under the pointer")
        draft.cancelPaletteDrag()
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "palette.drag")) == nil)
        #expect(draft.paletteDrag == nil)
        #expect(draft.flow == before)
        #expect(draft.undoStack.isEmpty)
    }

    // MARK: Tab

    @Test func tabOpensThePaneAtThePointer() async throws {
        let (_, draft, window) = try await fixture()
        let point = try center(window, "node.gate")
        try await openPane(draft, window, at: point)
        let frame = try #require(draft.canvasFrame)
        let search = try #require(draft.nodeSearch)
        #expect(search.windowPoint == point)
        #expect(search.dropPoint == ScreenPoint(x: point.x - frame.origin.x, y: point.y - frame.origin.y))
        #expect(search.query == "" && search.highlighted == 0)
        _ = try window.element(identifier: "nodeSearch")
        _ = try window.element(identifier: "nodeSearch.field")
        #expect(try window.focusedElement?.identifier == "nodeSearch.field")
        for kind in PaletteKind.groups.flatMap(\.items).prefix(NodeSearchPane.rows) {
            _ = try window.element(identifier: "nodeSearch.\(kind.idPrefix)")
        }
    }

    @Test func openingWithoutAPointerUsesTheCanvasCentre() async throws {
        let (_, draft, _) = try await fixture()
        let frame = try #require(draft.canvasFrame)
        draft.pointerInWindow = nil
        draft.openNodeSearch()
        let search = try #require(draft.nodeSearch)
        #expect(search.dropPoint == ScreenPoint(x: frame.size.width / 2, y: frame.size.height / 2))
        #expect(search.windowPoint == ScreenPoint(x: frame.origin.x + frame.size.width / 2,
                                                  y: frame.origin.y + frame.size.height / 2))
    }

    @Test func tabWithAFocusedFieldDoesNotOpenThePane() async throws {
        let (_, draft, window) = try await fixture()
        try window.click(window.element(identifier: "node.plan"))
        try await window.runUntilIdle()
        let field = try window.element(identifier: "inspector.title")
        window.click(at: ScreenPoint(x: field.frame.origin.x + field.frame.size.width - 4,
                                     y: field.frame.origin.y + field.frame.size.height / 2))
        window.hover(at: try center(window, "node.gate"))
        let nodes = draft.flow.nodes.count
        window.typeKey(.tab)
        window.typeText("n")
        try await window.runUntilIdle()
        #expect(draft.nodeSearch == nil)
        #expect(draft.flow.nodes.count == nodes)
    }

    @Test func tabWithThePointerElsewhereAndNoCanvasFocusIsIgnored() async throws {
        let (_, draft, window) = try await fixture()
        window.hover(at: try center(window, "palette.shell"))
        window.typeKey(.tab)
        try await window.runUntilIdle()
        #expect(draft.nodeSearch == nil)
    }

    // MARK: The pane

    @Test func queryFiltersCaseInsensitivelyAndResetsTheHighlight() async throws {
        let (_, draft, _) = try await fixture()
        draft.openNodeSearch()
        draft.moveNodeSearch(by: 3)
        #expect(draft.nodeSearch?.highlighted == 3)
        draft.setNodeSearchQuery("PRO")
        #expect(draft.nodeSearchMatches == [.prompt])
        #expect(draft.nodeSearch?.highlighted == 0)
        draft.setNodeSearchQuery("o")
        let all = PaletteKind.groups.flatMap(\.items)
        #expect(draft.nodeSearchMatches == all.filter { $0.label.lowercased().contains("o") })
        draft.moveNodeSearch(by: 1)
        draft.setNodeSearchQuery("OPEN")
        #expect(draft.nodeSearchMatches == [.openPR])
        #expect(draft.nodeSearch?.highlighted == 0)
    }

    @Test func arrowsClampAtTheEnds() async throws {
        let (_, draft, _) = try await fixture()
        draft.openNodeSearch()
        draft.moveNodeSearch(by: -1)
        #expect(draft.nodeSearch?.highlighted == 0)
        for _ in 0..<50 { draft.moveNodeSearch(by: 1) }
        #expect(draft.nodeSearch?.highlighted == draft.nodeSearchMatches.count - 1)
        draft.setNodeSearchQuery("zzz")
        draft.moveNodeSearch(by: 1)
        #expect(draft.nodeSearch?.highlighted == 0)
    }

    @Test func returnAddsTheHighlightedNodeAtTheOpeningPoint() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let canvas = try #require(draft.canvasFrame)
        let point = ScreenPoint(x: canvas.origin.x + 250, y: canvas.origin.y + 180)
        try await openPane(draft, window, at: point)
        let before = draft.flow
        window.typeKey(.downArrow)
        window.typeKey(.downArrow)
        try await window.runUntilIdle()
        #expect(draft.nodeSearch?.highlighted == 2)
        window.typeKey(.return)
        try await window.runUntilIdle()
        let id = try newNode(draft, before: before)
        #expect(draft.flow.node(id)?.title == PaletteKind.groups.flatMap(\.items)[2].label)
        try expectCentre(draft, id, at: ScreenPoint(x: Pixels(250), y: Pixels(180)))
        #expect(draft.selection == id)
        #expect(draft.nodeSearch == nil)
        #expect(draft.undoStack.count == 1)
    }

    @Test func typingFiltersThenReturnAdds() async throws {
        let (_, draft, window) = try await fixture()
        try await openPane(draft, window)
        let before = draft.flow
        window.typeText("JUD")
        window.typeKey(.return)
        try await window.runUntilIdle()
        let id = try newNode(draft, before: before)
        #expect(draft.flow.node(id)?.title == "Judge")
    }

    @Test func returnWithNoMatchesDoesNothing() async throws {
        let (_, draft, _) = try await fixture()
        let before = draft.flow
        draft.openNodeSearch()
        draft.setNodeSearchQuery("zzz")
        #expect(draft.confirmNodeSearch() == nil)
        #expect(draft.flow == before)
        #expect(draft.nodeSearch != nil)
    }

    @Test func escapeClosesAndAddsNothing() async throws {
        let (_, draft, window) = try await fixture()
        try await openPane(draft, window)
        let before = draft.flow
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(draft.nodeSearch == nil)
        #expect(draft.flow == before)
    }

    @Test func clickingARowAdds() async throws {
        let (_, draft, window) = try await fixture()
        try await openPane(draft, window)
        let before = draft.flow
        try window.click(window.element(identifier: "nodeSearch.shell"))
        try await window.runUntilIdle()
        let id = try newNode(draft, before: before)
        #expect(draft.flow.node(id)?.title == "Shell")
        #expect(draft.nodeSearch == nil)
    }

    @Test func everyPaletteKindIsSearchable() async throws {
        let (_, draft, _) = try await fixture()
        draft.openNodeSearch()
        let all = PaletteKind.groups.flatMap(\.items)
        #expect(draft.nodeSearchMatches == all)
        for kind in all {
            draft.setNodeSearchQuery(kind.label)
            #expect(draft.nodeSearchMatches.contains(kind), "\(kind.label) is not searchable")
        }
    }
}
