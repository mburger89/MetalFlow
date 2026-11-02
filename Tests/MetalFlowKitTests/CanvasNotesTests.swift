import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct CanvasNotesTests {
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

    /// The window position of a canvas point.
    func screen(_ window: TestWindow, _ draft: FlowDraft, _ p: CanvasPoint) throws -> ScreenPoint {
        let origin = try window.element(identifier: "canvas").frame.origin
        let s = draft.geometry.toScreen(p)
        return ScreenPoint(x: origin.x + s.x, y: origin.y + s.y)
    }

    func drag(_ window: TestWindow, _ draft: FlowDraft, from: CanvasPoint, by delta: (Float, Float),
              _ modifiers: EventModifiers = []) async throws {
        let a = try screen(window, draft, from)
        window.drag(from: a, to: ScreenPoint(x: a.x + Pixels(delta.0), y: a.y + Pixels(delta.1)), modifierFlags: modifiers)
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

    /// A frame around `ids`, committed and unselected.
    func frameAround(_ draft: FlowDraft, _ ids: Set<NodeID>) -> NoteID {
        draft.canvasSelection = CanvasSelection(nodes: ids)
        let id = draft.addNote()
        draft.commitNoteEdit()
        draft.clearSelection()
        return id
    }

    /// A sticky with its top-left corner at `origin`.
    @discardableResult
    func sticky(_ draft: FlowDraft, at origin: CanvasPoint, text: String = "") -> NoteID {
        let id = NoteID(rawValue: "sticky\(draft.flow.notes.count + 1)")
        draft.edit("sticky \(id.rawValue)") {
            $0.notes.append(FlowNote(id: id, text: text, origin: origin, width: 200, height: 120, surrounds: false))
        }
        return id
    }

    func note(_ draft: FlowDraft, _ id: NoteID) throws -> FlowNote {
        try #require(draft.flow.notes.first { $0.id == id })
    }

    func openEditor(_ draft: FlowDraft, _ window: TestWindow, _ id: NoteID) async throws {
        draft.beginEditingNote(id)
        try await window.runUntilIdle()
    }

    // MARK: N

    @Test func nWithNothingSelectedAddsAStickyAtThePointerAndOpensIt() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        window.hover(at: try screen(window, draft, CanvasPoint(x: 400, y: 600)))
        window.typeKey("n")
        try await window.runUntilIdle()
        let added = try #require(draft.flow.notes.first)
        #expect(draft.flow.notes.count == 1)
        #expect(added.id == "note1" && !added.surrounds && added.text == "")
        #expect(added.width == 200 && added.height == 120)
        #expect(abs(added.origin.x + 100 - 400) <= 1 && abs(added.origin.y + 60 - 600) <= 1, "centred on the pointer")
        #expect(draft.editingNote == "note1")
        #expect(draft.canvasSelection == CanvasSelection(notes: ["note1"]))
        #expect(draft.undoStack.count == 1)
        _ = try window.element(identifier: "note.note1")
        #expect(try window.focusedElement?.identifier == "note.editor")
    }

    @Test func nWithNodesSelectedAddsAFrameAroundThem() async throws {
        let (_, draft, window) = try await fixture()
        draft.canvasSelection = CanvasSelection(nodes: ["plan", "implement"])
        window.hover(at: try screen(window, draft, CanvasPoint(x: 400, y: 700)))
        window.typeKey("n")
        try await window.runUntilIdle()
        let frame = try note(draft, "note1")
        #expect(frame.surrounds)
        // plan (264, 140) 200x140 and implement (504, 185) 200x140: bounds 264...704 by 140...325.
        #expect(frame.origin == Point(x: 240, y: 94))
        #expect(frame.width == 440 + 48 && frame.height == 185 + 48 + 22)
        #expect(draft.members(of: frame) == ["plan", "implement"])
        #expect(draft.editingNote == "note1")
        #expect(draft.canvasSelection == CanvasSelection(notes: ["note1"]))
        #expect(draft.undoStack.count == 1)
        draft.undo()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
        #expect(draft.canvasSelection.isEmpty, "the stale selection is dropped")
        #expect(draft.editingNote == nil)
    }

    @Test func nInAFocusedFieldTypes() async throws {
        let (_, draft, window) = try await fixture()
        let field = try window.element(identifier: "studio.name")
        window.click(at: ScreenPoint(x: field.frame.origin.x + field.frame.size.width - 4,
                                     y: field.frame.origin.y + field.frame.size.height / 2))
        window.hover(at: try center(window, "node.gate"))
        window.typeText("n")
        try await window.runUntilIdle()
        #expect(draft.flow.notes.isEmpty)
        #expect(draft.flow.name.hasSuffix("n"), "the field took the key")
        // And inside the note editor: n is typed, and Tab opens no pane.
        let id = draft.addNote()
        try await window.runUntilIdle()
        window.hover(at: try center(window, "node.gate"))
        window.typeText("n")
        try await window.runUntilIdle()
        #expect(draft.noteEdit == NoteEdit(id: id, draft: "n"))
        #expect(draft.flow.notes.count == 1)
        window.typeKey(.tab)
        window.typeText("n")
        try await window.runUntilIdle()
        #expect(draft.nodeSearch == nil)
        #expect(draft.flow.notes.count == 1, "no second note")
    }

    @Test func noteIDsUseTheSmallestUnusedNumber() async throws {
        let (_, draft, _) = try await fixture()
        let a = draft.addNote(), b = draft.addNote(), c = draft.addNote()
        #expect([a, b, c] == ["note1", "note2", "note3"])
        draft.canvasSelection = CanvasSelection(notes: ["note2"])
        draft.deleteSelection()
        #expect(draft.addNote() == "note2")
    }

    // MARK: Palette and search

    @Test func noteFromPaletteClickAndDropAndSearch() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let size = try #require(draft.canvasSize)
        // Click: a sticky at the canvas centre.
        try window.click(window.element(identifier: "palette.note"))
        try await window.runUntilIdle()
        var added = try note(draft, "note1")
        let centre = draft.geometry.toCanvas(ScreenPoint(x: size.width / 2, y: size.height / 2))
        #expect(abs(added.origin.x + 100 - centre.x) <= 1 && abs(added.origin.y + 60 - centre.y) <= 1)
        #expect(draft.editingNote == "note1")
        // Drop: a sticky centred on the drop point.
        let canvas = try #require(draft.canvasFrame)
        window.drag(from: try center(window, "palette.note"),
                    to: ScreenPoint(x: canvas.origin.x + 300, y: canvas.origin.y + 400))
        try await window.runUntilIdle()
        added = try note(draft, "note2")
        let drop = draft.geometry.toCanvas(ScreenPoint(x: Pixels(300), y: Pixels(400)))
        #expect(abs(added.origin.x + 100 - drop.x) <= 1 && abs(added.origin.y + 60 - drop.y) <= 1)
        #expect(draft.editingNote == "note2")
        // Search: type "note", Return.
        draft.commitNoteEdit()
        try await window.runUntilIdle()
        window.hover(at: ScreenPoint(x: canvas.origin.x + 500, y: canvas.origin.y + 250))
        window.typeKey(.tab)
        try await window.runUntilIdle()
        window.typeText("note")
        try await window.runUntilIdle()
        #expect(draft.nodeSearchMatches == [.note])
        _ = try window.element(identifier: "nodeSearch.note")
        window.typeKey(.return)
        try await window.runUntilIdle()
        added = try note(draft, "note3")
        let spot = draft.geometry.toCanvas(ScreenPoint(x: Pixels(500), y: Pixels(250)))
        #expect(abs(added.origin.x + 100 - spot.x) <= 1 && abs(added.origin.y + 60 - spot.y) <= 1)
        #expect(draft.nodeSearch == nil && draft.editingNote == "note3")
    }

    @Test func theNotesGroupIsAfterTheNodeGroups() {
        #expect(PaletteEntry.groups.map(\.title) == PaletteKind.groups.map(\.title) + ["NOTES"])
        #expect(PaletteEntry.groups.last?.items == [.note])
        #expect(PaletteEntry.note.idPrefix == "note" && PaletteEntry.note.label == "Note")
        #expect(PaletteEntry.node(.gate).idPrefix == "gate")
    }

    // MARK: Moving, carrying, selecting

    @Test func aFrameCarriesNodesWhoseCentresAreInsideAsOneUndo() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let id = frameAround(draft, ["plan", "implement"])
        let before = draft.flow
        let undos = draft.undoStack.count
        let frame = try note(draft, id)
        try await drag(window, draft, from: CanvasPoint(x: frame.origin.x + 60, y: frame.origin.y + 8), by: (60, 40))
        for nodeID: NodeID in ["plan", "implement"] {
            let moved = try #require(draft.flow.node(nodeID)), was = try #require(before.node(nodeID))
            #expect(abs(moved.position.x - was.position.x - 120) < 1.5 && abs(moved.position.y - was.position.y - 80) < 1.5)
        }
        let movedFrame = try note(draft, id)
        #expect(abs(movedFrame.origin.x - frame.origin.x - 120) < 1.5)
        #expect(draft.flow.node("gate") == before.node("gate"))
        #expect(draft.canvasSelection == CanvasSelection(notes: [id]))
        #expect(draft.undoStack.count == undos + 1)
        window.typeKey("z", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
    }

    @Test func aNodeDraggedOutOfAFrameIsNoLongerCarried() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let id = frameAround(draft, ["plan"])
        try await drag(window, draft, from: CanvasPoint(x: 364, y: 210), by: (0, 160))
        let plan = try #require(draft.flow.node("plan"))
        #expect(plan.position.y > 140 + 250, "the node left the frame")
        let frame = try note(draft, id)
        #expect(draft.members(of: frame).isEmpty)
        try await drag(window, draft, from: CanvasPoint(x: frame.origin.x + 60, y: frame.origin.y + 8), by: (40, 40))
        #expect(try #require(draft.flow.node("plan")).position == plan.position, "the frame left it alone")
        #expect(try note(draft, id).origin.x > frame.origin.x + 50)
    }

    @Test func aStickyCarriesNothing() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 100))
        let before = draft.flow
        let undos = draft.undoStack.count
        try await drag(window, draft, from: CanvasPoint(x: 300, y: 110), by: (40, 20))
        #expect(try note(draft, id).origin != before.notes[0].origin)
        #expect(draft.flow.nodes == before.nodes)
        #expect(draft.undoStack.count == undos + 1)
    }

    @Test func draggingASelectedNodeMovesTheSelectedNotesToo() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 100))
        draft.canvasSelection = CanvasSelection(nodes: ["gate"], notes: [id])
        let before = draft.flow
        let undos = draft.undoStack.count
        try await drag(window, draft, from: CanvasPoint(x: 844, y: 255), by: (30, 30))
        #expect(try #require(draft.flow.node("gate")).position != before.node("gate")?.position)
        #expect(try note(draft, id).origin != before.notes[0].origin)
        #expect(draft.undoStack.count == undos + 1)
    }

    @Test func insideAFrameAClickSelectsTheNodeAndABoxStillDraws() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let id = frameAround(draft, ["plan", "implement"])
        window.click(at: try screen(window, draft, CanvasPoint(x: 364, y: 210)))
        try await window.runUntilIdle()
        #expect(draft.canvasSelection == CanvasSelection(nodes: ["plan"]))
        // An empty spot in the frame's interior, under the first node: a click clears.
        let gap = try screen(window, draft, CanvasPoint(x: 400, y: 330))
        window.click(at: gap)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.isEmpty)
        // And a drag from it draws a box that selects neither the frame nor any node.
        let start = draft.geometry.toScreen(CanvasPoint(x: 400, y: 330))
        let end = ScreenPoint(x: start.x + 6, y: start.y + 4)
        draft.primaryDragChanged(.init(startLocation: start, location: end))
        #expect(draft.selectionBox != nil)
        #expect(draft.canvasSelection.isEmpty, "a box wholly inside the interior does not take the frame")
        draft.primaryDragEnded(.init(startLocation: start, location: end))
        #expect(draft.selectionBox == nil)
        #expect(draft.flow.notes.contains { $0.id == id })
    }

    @Test func titleStripAndEdgeBandGrabTheFrame() async throws {
        let (_, draft, window) = try await fixture()
        let frame = FlowNote(id: "note1", text: "t", origin: Point(x: 100, y: 100), width: 300, height: 200, surrounds: true)
        let g = CanvasGeometry()
        func hit(_ x: Double, _ y: Double) -> (NoteID, NotePart)? {
            var flow = BuiltinFlows.fixGitHubIssue
            flow.notes = [frame]
            return g.hitNote(at: CanvasPoint(x: x, y: y), in: flow, selected: [])
        }
        #expect(hit(250, 110)?.1 == .chrome, "title strip")
        #expect(hit(103, 200)?.1 == .chrome, "left band")
        #expect(hit(397, 200)?.1 == .chrome, "right band")
        #expect(hit(250, 297)?.0 == "note1" && hit(250, 297)?.1 == .chrome, "bottom band")
        #expect(hit(250, 200) == nil, "interior")
        #expect(hit(250, 124) == nil, "just below the strip")
        #expect(hit(99, 200) == nil && hit(250, 301) == nil, "outside")
        // And on the canvas, a click on the strip selects it.
        try await zoomedOut(draft, window)
        draft.edit("frame") { $0.notes = [frame] }
        window.click(at: try screen(window, draft, CanvasPoint(x: 250, y: 110)))
        try await window.runUntilIdle()
        #expect(draft.canvasSelection == CanvasSelection(notes: ["note1"]))
    }

    @Test func boxWhollyInsideAFrameDoesNotSelectTheFrame() throws {
        let frame = FlowNote(id: "note1", text: "", origin: Point(x: 100, y: 100), width: 300, height: 200, surrounds: true)
        let stick = FlowNote(id: "note2", text: "", origin: Point(x: 600, y: 100), width: 200, height: 120, surrounds: false)
        var flow = Flow(name: "f", nodes: [], wires: [], notes: [frame, stick])
        let g = CanvasGeometry()
        func notes(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [NoteID] {
            g.notes(in: CanvasRect(x: x, y: y, w: w, h: h), flow: flow)
        }
        #expect(notes(150, 150, 100, 80).isEmpty, "inside the interior")
        #expect(notes(90, 150, 30, 30) == ["note1"], "crossing the edge")
        #expect(notes(150, 90, 30, 30) == ["note1"], "crossing the title strip")
        #expect(notes(0, 0, 1000, 1000) == ["note1", "note2"], "enclosing all of it")
        #expect(notes(700, 200, 10, 10) == ["note2"], "any overlap takes a sticky")
        #expect(notes(0, 500, 50, 50).isEmpty)
        flow.notes = []
        #expect(notes(0, 0, 1000, 1000).isEmpty)
    }

    @Test func aBoxSelectsNotesAndNodesTogether() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let id = sticky(draft, at: CanvasPoint(x: 700, y: 400))
        let start = draft.geometry.toScreen(CanvasPoint(x: 650, y: 150))
        let end = draft.geometry.toScreen(CanvasPoint(x: 800, y: 420))
        draft.primaryDragChanged(.init(startLocation: start, location: end))
        #expect(draft.canvasSelection == CanvasSelection(nodes: ["implement", "gate"], notes: [id]))
        draft.primaryDragEnded(.init(startLocation: start, location: end))
        // A shift click on a note adds it, a command click toggles it out.
        draft.clearSelection()
        window.click(at: try screen(window, draft, CanvasPoint(x: 800, y: 450)))
        try await window.runUntilIdle()
        #expect(draft.canvasSelection == CanvasSelection(notes: [id]))
        window.click(at: try center(window, "node.gate"), modifierFlags: .shift)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection == CanvasSelection(nodes: ["gate"], notes: [id]))
        window.click(at: try screen(window, draft, CanvasPoint(x: 800, y: 450)), modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection == CanvasSelection(nodes: ["gate"]))
    }

    @Test func selectAllIncludesNotes() async throws {
        let (_, draft, window) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 700, y: 400))
        window.hover(at: try center(window, "node.gate"))
        window.typeKey("a", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection.nodes == Set(draft.flow.nodes.map(\.id)))
        #expect(draft.canvasSelection.notes == [id])
    }

    // MARK: Resizing

    @Test func resizeHandleResizesOneUndoAndClampsToTheMinimum() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 400))
        draft.canvasSelection = CanvasSelection(notes: [id])
        let before = draft.flow
        let undos = draft.undoStack.count
        let handle = CanvasPoint(x: 200 + 200 - 6, y: 400 + 120 - 6)
        try await drag(window, draft, from: handle, by: (50, 30))
        let grown = try note(draft, id)
        #expect(abs(grown.width - 200 - 100) < 1.5 && abs(grown.height - 120 - 60) < 1.5, "50 points at zoom 0.5")
        #expect(grown.origin == before.notes[0].origin)
        #expect(draft.undoStack.count == undos + 1)
        draft.undo()
        #expect(draft.flow == before)
        draft.canvasSelection = CanvasSelection(notes: [id])
        try await drag(window, draft, from: handle, by: (-1000, -1000))
        let shrunk = try note(draft, id)
        #expect(shrunk.width == NoteLayout.minimumWidth && shrunk.height == NoteLayout.minimumHeight)
        #expect(draft.undoStack.count == undos + 1)
    }

    @Test func handleOnlyWorksWhenSelected() async throws {
        let (_, draft, window) = try await fixture()
        let g = CanvasGeometry()
        let stick = FlowNote(id: "note1", text: "", origin: Point(x: 100, y: 100), width: 200, height: 120, surrounds: false)
        var flow = BuiltinFlows.fixGitHubIssue
        flow.notes = [stick]
        let corner = CanvasPoint(x: 294, y: 214)
        #expect(g.hitNote(at: corner, in: flow, selected: [])?.1 == .body)
        #expect(g.hitNote(at: corner, in: flow, selected: ["note1"])?.1 == .handle)
        #expect(g.hitNote(at: CanvasPoint(x: 250, y: 150), in: flow, selected: ["note1"])?.1 == .body)
        // Unselected, a drag from the corner moves the note rather than resizing it.
        try await zoomedOut(draft, window)
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 400))
        try await drag(window, draft, from: CanvasPoint(x: 394, y: 514), by: (50, 30))
        let moved = try note(draft, id)
        #expect(moved.width == 200 && moved.height == 120 && moved.origin.x > 200)
    }

    // MARK: Editing

    @Test func doubleClickEdits() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 400), text: "hi")
        let spot = try screen(window, draft, CanvasPoint(x: 260, y: 430))
        window.click(at: spot)
        try await window.runUntilIdle()
        #expect(draft.canvasSelection == CanvasSelection(notes: [id]) && draft.editingNote == nil)
        window.doubleClick(at: spot)
        try await window.runUntilIdle()
        #expect(draft.editingNote == id)
        #expect(try window.focusedElement?.identifier == "note.editor")
        // A frame edits from its title strip.
        draft.cancelNoteEdit()
        let frame = frameAround(draft, ["plan"])
        let strip = try screen(window, draft, CanvasPoint(x: 300, y: try note(draft, frame).origin.y + 8))
        window.doubleClick(at: strip)
        try await window.runUntilIdle()
        #expect(draft.editingNote == frame)
    }

    @Test func returnCommitsTitleCommandReturnCommitsStickyEscapeCancels() async throws {
        let (_, draft, window) = try await fixture()
        let frame = frameAround(draft, ["plan"])
        try await openEditor(draft, window, frame)
        window.typeText("Hello")
        window.typeKey(.return)
        try await window.runUntilIdle()
        #expect(try note(draft, frame).text == "Hello" && draft.editingNote == nil)

        let stick = sticky(draft, at: CanvasPoint(x: 200, y: 600))
        try await openEditor(draft, window, stick)
        window.typeText("ab")
        window.typeKey(.return)
        window.typeText("cd")
        try await window.runUntilIdle()
        #expect(draft.editingNote == stick, "Return in a sticky is a new line")
        window.typeKey(.return, modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(try note(draft, stick).text == "ab\ncd" && draft.editingNote == nil)

        try await openEditor(draft, window, stick)
        window.typeText("zzz")
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(try note(draft, stick).text == "ab\ncd" && draft.editingNote == nil)
        try await openEditor(draft, window, frame)
        window.typeText("x")
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(try note(draft, frame).text == "Hello")
    }

    @Test func losingFocusCommits() async throws {
        let (_, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let stick = sticky(draft, at: CanvasPoint(x: 200, y: 600))
        try await openEditor(draft, window, stick)
        window.typeText("kept")
        try window.click(window.element(identifier: "studio.name"))
        try await window.runUntilIdle()
        #expect(try note(draft, stick).text == "kept" && draft.editingNote == nil)
        // A press elsewhere on the canvas commits too.
        try await openEditor(draft, window, stick)
        draft.updateNoteDraft("kept!")
        window.click(at: try screen(window, draft, CanvasPoint(x: 700, y: 600)))
        try await window.runUntilIdle()
        #expect(try note(draft, stick).text == "kept!" && draft.editingNote == nil)
    }

    @Test func anEditIsOneUndo() async throws {
        let (_, draft, window) = try await fixture()
        let stick = sticky(draft, at: CanvasPoint(x: 200, y: 600))
        let undos = draft.undoStack.count
        try await openEditor(draft, window, stick)
        window.typeText("hello")
        try await window.runUntilIdle()
        #expect(draft.undoStack.count == undos, "typing alone is not an edit")
        window.typeKey(.return, modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.undoStack.count == undos + 1)
        draft.undo()
        #expect(try note(draft, stick).text == "")
        // An unchanged commit records nothing.
        try await openEditor(draft, window, stick)
        draft.commitNoteEdit()
        #expect(draft.undoStack.count == undos)
    }

    @Test func anEmptyNoteStays() async throws {
        let (_, draft, window) = try await fixture()
        let id = draft.addNote()
        try await window.runUntilIdle()
        draft.commitNoteEdit()
        #expect(draft.flow.notes.map(\.id) == [id])
        #expect(try note(draft, id).text == "")
    }

    @Test func aFramesTitleIsOneLine() async throws {
        let (_, draft, _) = try await fixture()
        let frame = frameAround(draft, ["plan"])
        draft.beginEditingNote(frame)
        draft.updateNoteDraft("a\nb")
        draft.commitNoteEdit()
        #expect(try note(draft, frame).text == "a b")
    }

    // MARK: Deleting, fitting, drawing

    @Test func deleteRemovesSelectedNotesAndNodesTogether() async throws {
        let (_, draft, window) = try await fixture()
        let frame = frameAround(draft, ["implement", "gate"])
        let before = draft.flow
        let undos = draft.undoStack.count
        draft.canvasSelection = CanvasSelection(nodes: ["plan"], notes: [frame])
        window.hover(at: try center(window, "node.judge"))
        window.typeKey(.delete)
        try await window.runUntilIdle()
        #expect(draft.flow.notes.isEmpty && draft.flow.node("plan") == nil)
        #expect(draft.flow.node("implement") != nil && draft.flow.node("gate") != nil, "a frame's nodes stay")
        #expect(!draft.flow.wires.contains { $0.from == "plan" || $0.to == "plan" })
        #expect(draft.canvasSelection.isEmpty)
        #expect(draft.undoStack.count == undos + 1)
        window.typeKey("z", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
    }

    @Test func deletingOnlyANoteWorks() async throws {
        let (_, draft, _) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 600))
        draft.canvasSelection = CanvasSelection(notes: [id])
        draft.deleteSelection()
        #expect(draft.flow.notes.isEmpty && draft.canvasSelection.isEmpty)
    }

    @Test func fitIncludesNotes() throws {
        let g = CanvasGeometry()
        let size = Size(width: Pixels(800), height: Pixels(600))
        var flow = BuiltinFlows.fixGitHubIssue
        let plain = g.fit(flow, in: size)
        flow.notes = [FlowNote(id: "note1", text: "", origin: Point(x: 2000, y: 1500), width: 200, height: 120, surrounds: false)]
        let fitted = g.fit(flow, in: size)
        #expect(fitted.zoom < plain.zoom)
        let corner = fitted.toScreen(CanvasPoint(x: 2200, y: 1620))
        #expect(corner.x.value <= 800 - 40 + 0.5 && corner.y.value <= 600 - 40 + 0.5)
        // A flow of only notes still fits.
        let notesOnly = Flow(name: "n", nodes: [], wires: [], notes: flow.notes)
        #expect(g.fit(notesOnly, in: size) != CanvasGeometry())
    }

    @Test func drawOrderIsFramesWiresStickiesNodes() {
        let order = CanvasLayer.drawOrder
        func index(_ layer: CanvasLayer) -> Int { order.firstIndex(of: layer)! }
        #expect(index(.grid) < index(.frames))
        #expect(index(.frames) < index(.wires))
        #expect(index(.wires) < index(.stickies))
        #expect(index(.stickies) < index(.nodes))
        #expect(index(.nodes) < index(.ports))
        #expect(Set(order).count == order.count)
    }

    // MARK: Inspector, history, saving

    @Test func inspectorShowsANoteAndACountForMixedSelections() async throws {
        let (_, draft, window) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 600), text: "Remember this")
        draft.canvasSelection = CanvasSelection(notes: [id])
        try await window.runUntilIdle()
        _ = try window.element(identifier: "inspector.note")
        #expect(try window.element(identifier: "inspector.noteText").value == "Remember this")
        draft.canvasSelection = CanvasSelection(nodes: ["plan"], notes: [id])
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "inspector.selectionCount").value == "2 selected")
        #expect((try? window.element(identifier: "inspector.note")) == nil)
    }

    @Test func notesMakeTheDraftDirtyAndUndoDropsStaleSelection() async throws {
        let (_, draft, _) = try await fixture()
        #expect(!draft.isDirty)
        let id = draft.addNote()
        #expect(draft.isDirty)
        draft.undo()
        #expect(!draft.isDirty && draft.canvasSelection.isEmpty && draft.noteEdit == nil)
        draft.redo()
        #expect(draft.flow.notes.map(\.id) == [id])
    }
}
