import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct CanvasChromeTests {
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

    func focusFind(_ window: TestWindow) async throws {
        window.click(at: try center(window, "palette.find"))
        try await window.runUntilIdle()
    }

    func labels(_ draft: FlowDraft) -> [String] {
        draft.visiblePaletteGroups.flatMap(\.items).map(\.label)
    }

    // MARK: Find

    @Test func findFiltersPaletteIgnoringCase() async throws {
        let (_, draft, _) = try await fixture()
        #expect(draft.visiblePaletteGroups.map(\.title) == PaletteEntry.groups.map(\.title))
        draft.paletteFilter = "GATE"
        #expect(draft.visiblePaletteGroups.flatMap(\.items) == [.node(.gate)])
        #expect(draft.visiblePaletteGroups.count == 1, "groups with no match are left out")
        draft.paletteFilter = ""
        #expect(draft.visiblePaletteGroups.map(\.title) == PaletteEntry.groups.map(\.title))
    }

    @Test func findUsesSameMatchingAsTabSearch() async throws {
        let (_, draft, _) = try await fixture()
        for query in ["o", "PRO", "open", "note", "zzz", ""] {
            draft.paletteFilter = query
            draft.openNodeSearch()
            draft.setNodeSearchQuery(query)
            #expect(labels(draft) == draft.nodeSearchMatches.map(\.label), "query \(query)")
            draft.closeNodeSearch()
        }
    }

    @Test func findShowsEmptyState() async throws {
        let (_, draft, window) = try await fixture()
        #expect((try? window.element(identifier: "palette.empty")) == nil)
        draft.paletteFilter = "zzz"
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "palette.empty").value == "No matches")
        #expect((try? window.element(identifier: "palette.gate")) == nil)
    }

    @Test func returnInFindAddsFirstMatchAtCentre() async throws {
        let (_, draft, window) = try await fixture()
        try await focusFind(window)
        window.typeText("jud")
        try await window.runUntilIdle()
        #expect(draft.paletteFilter == "jud")
        let before = draft.flow
        let size = try #require(draft.canvasSize)
        let geometry = draft.geometry
        window.typeKey(.return)
        try await window.runUntilIdle()
        let added = draft.flow.nodes.filter { before.node($0.id) == nil }
        #expect(added.count == 1)
        let id = try #require(added.first).id
        #expect(draft.flow.node(id)?.title == "Judge")
        #expect(draft.selection == id)
        #expect(draft.paletteFilter == "")
        let want = geometry.toCanvas(ScreenPoint(x: size.width / 2, y: size.height / 2))
        let node = try #require(draft.flow.node(id))
        let r = geometry.nodeRect(node)
        #expect(abs(r.x + r.w / 2 - want.x) <= 0.5 && abs(r.y + r.h / 2 - want.y) <= 0.5, "\(r) vs \(want)")
    }

    @Test func returnInFindReleasesFocus() async throws {
        let (_, draft, window) = try await fixture()
        try await focusFind(window)
        #expect(try window.focusedElement?.identifier == "palette.find")
        window.typeText("jud")
        try await window.runUntilIdle()
        let before = draft.flow.nodes.count
        window.typeKey(.return)
        try await window.runUntilIdle()
        #expect(draft.flow.nodes.count == before + 1)
        #expect(try window.focusedElement?.identifier != "palette.find", "the canvas takes keys again")
    }

    @Test func returnWithNoMatchKeepsFocus() async throws {
        let (_, draft, window) = try await fixture()
        try await focusFind(window)
        window.typeText("zzz")
        try await window.runUntilIdle()
        let before = draft.flow
        window.typeKey(.return)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
        #expect(try window.focusedElement?.identifier == "palette.find")
    }

    @Test func returnWithNoMatchAddsNothing() async throws {
        let (_, draft, window) = try await fixture()
        try await focusFind(window)
        window.typeText("zzz")
        let before = draft.flow
        window.typeKey(.return)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
        #expect(draft.paletteFilter == "zzz")
    }

    @Test func escapeInFindClearsIt() async throws {
        let (_, draft, window) = try await fixture()
        try window.click(window.element(identifier: "node.plan"))
        try await window.runUntilIdle()
        #expect(draft.selection == "plan")
        try await focusFind(window)
        window.hover(at: try center(window, "node.gate"))
        window.typeText("gat")
        try await window.runUntilIdle()
        #expect(draft.paletteFilter == "gat")
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(draft.paletteFilter == "")
        #expect(try window.element(identifier: "palette.find").value == "")
        #expect(draft.selection == "plan", "Esc went to the field, not the canvas")
        #expect(draft.nodeSearch == nil)
    }

    @Test func returnOnAnEmptyFindAddsNothing() async throws {
        let (_, draft, window) = try await fixture()
        try await focusFind(window)
        let before = draft.flow
        window.typeKey(.return)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
        draft.addFirstPaletteMatch()
        draft.paletteFilter = "   "
        draft.addFirstPaletteMatch()
        #expect(draft.flow == before, "spaces are not a search")
        #expect(draft.paletteFilter == "   ")
    }

    @Test func aClickOnAFilteredRowClearsTheFilter() async throws {
        let (_, draft, _) = try await fixture()
        draft.paletteFilter = "gat"
        let at = ScreenPoint(x: Pixels(10), y: Pixels(10))
        let added = draft.endPaletteDrag(.node(.gate), from: at, at: at)
        #expect(added != nil)
        #expect(draft.paletteFilter == "")
    }

    @Test func aDropFromAFilteredRowClearsTheFilter() async throws {
        let (_, draft, _) = try await fixture()
        let frame = try #require(draft.canvasFrame)
        let start = ScreenPoint(x: Pixels(5), y: Pixels(5))
        let drop = ScreenPoint(x: frame.origin.x + frame.size.width / 2, y: frame.origin.y + frame.size.height / 2)
        draft.paletteFilter = "gat"
        #expect(draft.endPaletteDrag(.node(.gate), from: start, at: drop) != nil)
        #expect(draft.paletteFilter == "")
        // A drop off the canvas adds nothing and leaves the filter.
        draft.paletteFilter = "gat"
        let before = draft.flow
        #expect(draft.endPaletteDrag(.node(.gate), from: start, at: ScreenPoint(x: Pixels(-50), y: Pixels(-50))) == nil)
        #expect(draft.flow == before && draft.paletteFilter == "gat")
    }

    @Test func typingInFindStaysInTheField() async throws {
        let (_, draft, window) = try await fixture()
        try window.click(window.element(identifier: "node.plan"))
        try await window.runUntilIdle()
        #expect(draft.selection == "plan")
        try await focusFind(window)
        window.hover(at: try center(window, "node.gate"))
        let before = draft.flow
        window.typeText("n")
        window.typeKey(.delete)
        window.typeKey(.tab)
        try await window.runUntilIdle()
        #expect(draft.flow == before, "no note added and the node kept")
        #expect(draft.flow.node("plan") != nil)
        #expect(draft.nodeSearch == nil)
        #expect(draft.paletteFilter == "", "n was typed then deleted in the field")
    }

    @Test func filterIsNotAnEdit() async throws {
        let (_, draft, _) = try await fixture()
        draft.paletteFilter = "gate"
        #expect(!draft.isDirty)
        #expect(draft.undoStack.isEmpty)
    }

    // MARK: Zoom

    func percent(_ window: TestWindow) throws -> String? {
        try window.element(identifier: "canvas.zoom").value
    }

    @Test func zoomInStepsAboutCentre() async throws {
        let (_, draft, window) = try await fixture()
        draft.geometry = CanvasGeometry(pan: ScreenPoint(x: Pixels(30), y: Pixels(20)), zoom: 1)
        try await window.runUntilIdle()
        let size = try #require(draft.canvasSize)
        let centre = ScreenPoint(x: size.width / 2, y: size.height / 2)
        let at = draft.geometry.toCanvas(centre)
        try window.click(window.element(identifier: "canvas.zoomIn"))
        try await window.runUntilIdle()
        #expect(try percent(window) == "125%")
        let now = draft.geometry.toCanvas(centre)
        #expect(abs(now.x - at.x) < 0.01 && abs(now.y - at.y) < 0.01)
    }

    @Test func zoomOutStops() async throws {
        let (_, draft, window) = try await fixture()
        for _ in 0..<12 {
            try window.click(window.element(identifier: "canvas.zoomOut"))
            try await window.runUntilIdle()
        }
        #expect(try percent(window) == "25%")
        #expect(try !window.element(identifier: "canvas.zoomOut").isEnabled)
        #expect(try window.element(identifier: "canvas.zoomIn").isEnabled)
        for _ in 0..<20 {
            try window.click(window.element(identifier: "canvas.zoomIn"))
            try await window.runUntilIdle()
        }
        #expect(try percent(window) == "400%")
        #expect(try !window.element(identifier: "canvas.zoomIn").isEnabled)
        #expect(draft.geometry.zoom == 4)
    }

    @Test func zoomStopsRunFromTheMinimumToTheMaximum() {
        let stops = FlowDraft.zoomStops
        #expect(stops.first == CanvasGeometry.minZoom && stops.last == CanvasGeometry.maxZoom)
        #expect(stops == stops.sorted() && Set(stops).count == stops.count)
        #expect(stops.contains { abs($0 - 1) < 1e-9 })
        #expect(stops.dropFirst().dropLast().allSatisfy { stop in
            (-20...20).contains { abs(pow(1.25, Double($0)) - stop) < 1e-9 } })
    }

    @Test func zoomOutThenInRetracesTheSamePercentages() async throws {
        let (_, draft, window) = try await fixture()
        draft.geometry = CanvasGeometry(pan: ScreenPoint(x: Pixels(0), y: Pixels(0)), zoom: 1)
        try await window.runUntilIdle()
        func step(_ id: String) async throws -> String? {
            try window.click(window.element(identifier: id))
            try await window.runUntilIdle()
            return try percent(window)
        }
        var down: [String?] = [try percent(window)]
        while try window.element(identifier: "canvas.zoomOut").isEnabled { down.append(try await step("canvas.zoomOut")) }
        #expect(down == ["100%", "80%", "64%", "51%", "41%", "33%", "26%", "25%"])
        var up: [String?] = [try percent(window)]
        while try percent(window) != "100%" { up.append(try await step("canvas.zoomIn")) }
        #expect(up == down.reversed(), "each step back shows the percentage the step down came from")
        var top: [String?] = [try percent(window)]
        while try window.element(identifier: "canvas.zoomIn").isEnabled { top.append(try await step("canvas.zoomIn")) }
        #expect(top.last == "400%")
        var back: [String?] = [try percent(window)]
        while try percent(window) != "100%" { back.append(try await step("canvas.zoomOut")) }
        #expect(back == top.reversed())
        #expect(draft.geometry.zoom == 1)
    }

    @Test func offStopZoomSnapsToTheNextStop() async throws {
        let (_, draft, _) = try await fixture()
        func zoomed(_ z: Double, _ body: () -> Void) -> Double {
            draft.geometry = CanvasGeometry(pan: ScreenPoint(x: Pixels(0), y: Pixels(0)), zoom: z)
            body()
            return draft.geometry.zoom
        }
        #expect(abs(zoomed(1.1) { draft.zoomCanvasIn() } - 1.25) < 1e-9)
        #expect(abs(zoomed(1.1) { draft.zoomCanvasOut() } - 1) < 1e-9)
        #expect(abs(zoomed(0.3) { draft.zoomCanvasOut() } - pow(1.25, -6)) < 1e-9)
        #expect(abs(zoomed(0.3) { draft.zoomCanvasIn() } - pow(1.25, -5)) < 1e-9)
        #expect(abs(zoomed(3.9) { draft.zoomCanvasIn() } - CanvasGeometry.maxZoom) < 1e-9)
        #expect(abs(zoomed(3.9) { draft.zoomCanvasOut() } - pow(1.25, 6)) < 1e-9)
        // On a stop, within the tolerance, the step goes past it.
        #expect(abs(zoomed(1.0004) { draft.zoomCanvasIn() } - 1.25) < 1e-9)
        #expect(abs(zoomed(1.0004) { draft.zoomCanvasOut() } - 0.8) < 1e-9)
        // At the limits nothing moves.
        #expect(zoomed(CanvasGeometry.maxZoom) { draft.zoomCanvasIn() } == CanvasGeometry.maxZoom)
        #expect(zoomed(CanvasGeometry.minZoom) { draft.zoomCanvasOut() } == CanvasGeometry.minZoom)
    }

    @Test func zoomIsNotAnEdit() async throws {
        let (_, draft, window) = try await fixture()
        try window.click(window.element(identifier: "canvas.zoomIn"))
        try await window.runUntilIdle()
        #expect(!draft.isDirty)
        #expect(draft.undoStack.isEmpty)
    }

    @Test func zoomDoesNothingBeforeTheCanvasIsMeasured() {
        let draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, location: .unsaved)
        draft.zoomCanvasIn()
        draft.zoomCanvasOut()
        #expect(draft.geometry.zoom == 1)
    }
}
