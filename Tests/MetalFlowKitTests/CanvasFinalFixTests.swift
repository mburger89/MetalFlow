import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

/// The fixes from the final review of the canvas-editing branch.
@MainActor
@Suite struct CanvasFinalFixTests {
    let repo = URL(fileURLWithPath: "/repo")

    func fixture() async throws -> (AppModel, FakeEngineClient, FlowDraft, TestWindow) {
        let client = FakeEngineClient(restored: [], repos: [repo], gitRepoPaths: [])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model, size: metalFlowWindowSize)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.screen = .studio
        try await window.runUntilIdle()
        return (model, client, try #require(model.draft), window)
    }

    /// A saved library flow with a sticky in it, open in the Studio, and the sticky's id.
    func savedFixture() async throws -> (AppModel, FakeEngineClient, FlowDraft, TestWindow, NoteID) {
        let (model, client, _, window) = try await fixture()
        var flow = BuiltinFlows.fixGitHubIssue
        let id = NoteID(rawValue: "note1")
        flow.notes = [FlowNote(id: id, text: "", origin: CanvasPoint(x: 200, y: 400), width: 200, height: 120, surrounds: false)]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("final-\(UUID().uuidString).flow")
        let draft = FlowDraft(flow: flow, location: .library(file: file))
        model.draft = draft
        try await window.runUntilIdle()
        return (model, client, draft, window, id)
    }

    func typeIntoOpenNote(_ draft: FlowDraft, _ window: TestWindow, _ id: NoteID, _ text: String = "typed") async throws {
        draft.beginEditingNote(id)
        try await window.runUntilIdle()
        window.typeText(text)
        try await window.runUntilIdle()
        #expect(draft.noteEdit?.draft.hasSuffix(text) == true, "the text is in the open editor")
    }

    func screen(_ window: TestWindow, _ draft: FlowDraft, _ p: CanvasPoint) throws -> ScreenPoint {
        let origin = try window.element(identifier: "canvas").frame.origin
        let s = draft.geometry.toScreen(p)
        return ScreenPoint(x: origin.x + s.x, y: origin.y + s.y)
    }

    func center(_ window: TestWindow, _ id: String) throws -> ScreenPoint {
        let f = try window.element(identifier: id).frame
        return ScreenPoint(x: f.origin.x + f.size.width / 2, y: f.origin.y + f.size.height / 2)
    }

    func zoomedOut(_ draft: FlowDraft, _ window: TestWindow) async throws {
        draft.geometry = CanvasGeometry(pan: ScreenPoint(x: Pixels(30), y: Pixels(20)), zoom: 0.5)
        try await window.runUntilIdle()
    }

    func text(_ flow: Flow?, _ id: NoteID) -> String? { flow?.notes.first { $0.id == id }?.text }

    @discardableResult
    func sticky(_ draft: FlowDraft, at origin: CanvasPoint, text: String = "") -> NoteID {
        let id = NoteID(rawValue: "sticky\(draft.flow.notes.count + 1)")
        draft.edit("sticky \(id.rawValue)") {
            $0.notes.append(FlowNote(id: id, text: text, origin: origin, width: 200, height: 120, surrounds: false))
        }
        return id
    }

    func tempRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mf-final-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: 1. Text in an open note editor reaches Save, Copy, Launch and the unsaved-changes checks

    @Test func openEditorMakesTheDraftDirty() async throws {
        let (_, _, draft, window, id) = try await savedFixture()
        #expect(!draft.isDirty)
        try await typeIntoOpenNote(draft, window, id)
        #expect(draft.isDirty, "typed text is an unsaved change")
    }

    @Test func saveCommandWritesTheTextOfTheOpenEditor() async throws {
        let (model, client, draft, window, id) = try await savedFixture()
        try await typeIntoOpenNote(draft, window, id)
        try window.testApp.performMenuBarItem("File", "Save")
        try await window.runUntil { !client.files.saved.isEmpty }
        #expect(text(client.files.saved.first?.flow, id) == "typed")
        #expect(draft.editingNote == nil)
        #expect(!draft.isDirty)
        _ = model
    }

    @Test func saveButtonWritesTheTextOfTheOpenEditor() async throws {
        let (_, client, draft, window, id) = try await savedFixture()
        try await typeIntoOpenNote(draft, window, id)
        window.click(at: try center(window, "studio.save"))
        try await window.runUntil { !client.files.saved.isEmpty }
        #expect(text(client.files.saved.first?.flow, id) == "typed")
        #expect(!draft.isDirty)
    }

    @Test func copyToCarriesTheTextOfTheOpenEditor() async throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, client, draft, window, id) = try await savedFixture()
        client.catalog.library = dir
        model.repos = [dir]
        try await typeIntoOpenNote(draft, window, id)
        let copying = Task { await model.copyDraft() }
        try await window.runUntil { model.isSavePanelVisible }
        // Chosen by the model, not by a click, which would move focus and commit the note itself.
        model.chooseSaveDestination(.repo(dir))
        await copying.value
        try await window.runUntilIdle()
        #expect(text(client.files.saved.first?.flow, id) == "typed")
    }

    @Test func launchSendsTheTextOfTheOpenEditor() async throws {
        let (model, client, draft, window, id) = try await savedFixture()
        model.studioValues["issue"] = "42"
        try await window.runUntilIdle()
        try await typeIntoOpenNote(draft, window, id)
        _ = await model.launchFromStudio()
        #expect(text(await client.launchedFlows.first, id) == "typed")
    }

    @Test func quitAsksWhenOnlyTheOpenEditorHoldsChanges() async throws {
        let (model, _, draft, window, id) = try await savedFixture()
        try await typeIntoOpenNote(draft, window, id)
        #expect(model.requestTerminate() == .later)
        #expect(model.pendingAction == .quit)
        #expect(text(draft.flow, id) == "typed")
    }

    @Test func openNewAndBuiltinAskWhenOnlyTheOpenEditorHoldsChanges() async throws {
        let (model, _, draft, window, id) = try await savedFixture()
        try await typeIntoOpenNote(draft, window, id)
        let other = repo.appendingPathComponent(".flows/b.flow")
        model.open(flow: other)
        #expect(model.pendingAction == .open(other))
        model.cancelPending()
        await model.newFlow()
        #expect(model.pendingAction == .newFlow)
        model.cancelPending()
        model.openBuiltin(BuiltinFlows.buildFeature)
        #expect(model.pendingAction == .openBuiltin(BuiltinFlows.buildFeature.name))
        #expect(model.draft === draft)
    }

    // MARK: 2. The note editor stays inside the canvas

    @Test func openingAWideNoteEditorDoesNotMoveOrResizeTheCanvas() async throws {
        let (_, _, draft, window) = try await fixture()
        draft.geometry = CanvasGeometry()
        try await window.runUntilIdle()
        let before = try window.element(identifier: "canvas").frame
        let sizeBefore = draft.canvasSize, frameBefore = draft.canvasFrame
        draft.selectAll()
        let id = draft.addNote()
        draft.updateNoteDraft("x")
        try await window.runUntilIdle()
        #expect(draft.editingNote == id)
        #expect(try window.element(identifier: "canvas").frame == before)
        #expect(draft.canvasSize == sizeBefore && draft.canvasFrame == frameBefore)
    }

    @Test func aStickyNearTheRightEdgeEditsInsideTheCanvas() async throws {
        let (_, _, draft, window) = try await fixture()
        let canvas = try window.element(identifier: "canvas").frame
        let size = try #require(draft.canvasSize)
        let id = sticky(draft, at: draft.geometry.toCanvas(ScreenPoint(x: size.width - 40, y: 60)))
        draft.beginEditingNote(id)
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "canvas").frame == canvas)
        #expect(draft.canvasSize == size, "the canvas keeps its size")
    }

    // MARK: 3. A dropped primary drag leaves nothing behind

    /// A press at `p` that is not released.
    func press(_ window: TestWindow, _ p: ScreenPoint) {
        window.send(.mouseDown(MouseEvent(position: p)))
    }

    func moveHeld(_ window: TestWindow, _ p: ScreenPoint) {
        window.send(.mouseDragged(MouseEvent(position: p)))
        window.advanceFrames(1)
    }

    @Test func aSecondPressAfterALostBoxDragClearsTheBox() async throws {
        let (_, _, draft, window) = try await fixture()
        let a = try screen(window, draft, CanvasPoint(x: 60, y: 560))
        press(window, a)
        moveHeld(window, ScreenPoint(x: a.x + 80, y: a.y + 60))
        try await window.runUntilIdle()
        #expect(draft.dragMode != nil && draft.selectionBox != nil)
        press(window, ScreenPoint(x: a.x + 300, y: a.y))
        try await window.runUntilIdle()
        #expect(draft.dragMode == nil && draft.selectionBox == nil, "the dropped drag was cancelled")
    }

    @Test func aLostNodeMoveIsRestoredAndTheNextEmptyDragDoesNotMoveThatNode() async throws {
        let (_, _, draft, window) = try await fixture()
        let before = draft.flow
        let node = try center(window, "node.gate")
        press(window, node)
        moveHeld(window, ScreenPoint(x: node.x + 40, y: node.y + 30))
        try await window.runUntilIdle()
        #expect(draft.flow != before, "mid-move")
        let empty = try screen(window, draft, CanvasPoint(x: 60, y: 560))
        press(window, empty)
        try await window.runUntilIdle()
        #expect(draft.flow == before && draft.dragStartFlow == nil && draft.dragMode == nil)
        moveHeld(window, ScreenPoint(x: empty.x + 50, y: empty.y + 40))
        window.send(.mouseUp(MouseEvent(position: ScreenPoint(x: empty.x + 50, y: empty.y + 40))))
        try await window.runUntilIdle()
        #expect(draft.flow == before, "the next empty drag moved nothing")
        #expect(draft.undoStack.isEmpty)
    }

    @Test func cancellingEachDragModeClearsItsState() async throws {
        let (_, _, draft, window) = try await fixture()
        let before = draft.flow
        draft.dragMode = .wire("plan")
        draft.pendingWire = ("plan", ScreenPoint(x: Pixels(5), y: Pixels(5)))
        draft.primaryDragCancelled()
        #expect(draft.dragMode == nil && draft.pendingWire == nil)
        draft.selectAll()
        let base = CanvasSelection(nodes: ["gate"])
        draft.canvasSelection = CanvasSelection(nodes: ["gate", "plan"])
        draft.dragMode = .box(start: ScreenPoint(x: Pixels(1), y: Pixels(1)), base: base, mode: .replace)
        draft.selectionBox = CanvasRect(x: 1, y: 1, w: 10, h: 10)
        draft.primaryDragCancelled()
        #expect(draft.dragMode == nil && draft.selectionBox == nil)
        #expect(draft.canvasSelection == base, "the box's live selection is dropped")
        draft.dragStartFlow = draft.flow
        draft.moveLive(["gate": CanvasPoint(x: 0, y: 0)], by: CanvasPoint(x: 9, y: 9))
        draft.dragMode = .move(origins: [:], notes: [:])
        draft.primaryDragCancelled()
        #expect(draft.flow == before && draft.dragStartFlow == nil && draft.undoStack.isEmpty)
        draft.panStart = ScreenPoint(x: Pixels(1), y: Pixels(1))
        draft.panCancelled()
        #expect(draft.panStart == nil)
        _ = window
    }

    @Test func aDroppedMiddleDragPanLetsTheNextPanStartFresh() async throws {
        let (_, _, draft, window) = try await fixture()
        let a = try screen(window, draft, CanvasPoint(x: 60, y: 560))
        let pan = draft.geometry.pan
        window.send(.otherMouseDown(MouseEvent(position: a, buttonNumber: 2)))
        window.send(.otherMouseDragged(MouseEvent(position: ScreenPoint(x: a.x + 30, y: a.y), buttonNumber: 2)))
        window.advanceFrames(1)
        window.send(.otherMouseDown(MouseEvent(position: ScreenPoint(x: a.x + 100, y: a.y), buttonNumber: 2)))
        try await window.runUntilIdle()
        #expect(draft.panStart == nil, "the lost pan was cancelled")
        #expect(draft.geometry.pan.x == pan.x + 30)
    }

    // MARK: 4. Mutating keys are ignored during a live drag

    @Test func keysDuringANodeMoveDoNothing() async throws {
        let (_, _, draft, window) = try await fixture()
        let node = try center(window, "node.gate")
        window.hover(at: node)
        press(window, node)
        moveHeld(window, ScreenPoint(x: node.x + 40, y: node.y + 30))
        try await window.runUntilIdle()
        let mid = draft.flow
        window.typeKey("n")
        window.typeKey(.delete)
        window.typeKey("z", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow == mid, "no note, no delete, no undo mid-move")
        #expect(draft.undoStack.isEmpty)
        window.send(.mouseUp(MouseEvent(position: ScreenPoint(x: node.x + 40, y: node.y + 30))))
        try await window.runUntilIdle()
        #expect(draft.undoStack.count == 1)
    }

    @Test func keysDuringAPaletteDragDoNothing() async throws {
        let (_, _, draft, window) = try await fixture()
        let frame = try #require(draft.canvasFrame)
        draft.selection = "gate"
        let before = draft.flow
        draft.movePaletteDrag(.node(.shell), from: ScreenPoint(x: frame.origin.x - 50, y: frame.origin.y + 50),
                              to: ScreenPoint(x: frame.origin.x + 100, y: frame.origin.y + 100))
        #expect(draft.paletteDrag != nil)
        window.hover(at: try center(window, "node.plan"))
        window.typeKey("n")
        window.typeKey(.delete)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
    }

    // MARK: 5. A press on inert chrome or the palette commits the note

    @Test func aPressOnTheStudioChromeCommitsTheOpenNote() async throws {
        let (_, _, draft, window) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 600))
        try await typeIntoOpenNote(draft, window, id, "kept")
        let palette = try window.element(identifier: "palette.prompt").frame
        // The empty part of the palette column, under its rows.
        window.click(at: ScreenPoint(x: palette.origin.x + 20, y: palette.origin.y + 600))
        try await window.runUntilIdle()
        #expect(draft.editingNote == nil)
        #expect(text(draft.flow, id) == "kept")
    }

    @Test func aPaletteClickCommitsTheOpenNote() async throws {
        let (_, _, draft, window) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 600))
        try await typeIntoOpenNote(draft, window, id, "kept")
        window.click(at: try center(window, "palette.shell"))
        try await window.runUntilIdle()
        #expect(draft.editingNote == nil)
        #expect(text(draft.flow, id) == "kept")
    }

    // MARK: 6. A brand-new note: Esc leaves nothing, commit joins the add step

    @Test func escapeOnABrandNewNoteRemovesItWithoutAnUndoStep() async throws {
        let (_, _, draft, window) = try await fixture()
        let before = draft.flow
        let undos = draft.undoStack.count
        window.hover(at: try center(window, "node.gate"))
        window.typeKey("n")
        try await window.runUntilIdle()
        #expect(draft.flow.notes.count == 1 && draft.editingNote != nil)
        window.typeText("abc")
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
        #expect(draft.undoStack.count == undos && draft.redoStack.isEmpty)
        #expect(draft.editingNote == nil && draft.canvasSelection.notes.isEmpty)
        #expect(!draft.isDirty)
    }

    @Test func typingInABrandNewNoteIsOneUndo() async throws {
        let (_, _, draft, window) = try await fixture()
        let before = draft.flow
        let undos = draft.undoStack.count
        window.hover(at: try center(window, "node.gate"))
        window.typeKey("n")
        try await window.runUntilIdle()
        window.typeText("hello")
        window.typeKey(.return, modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow.notes.first?.text == "hello")
        #expect(draft.undoStack.count == undos + 1, "the first commit joins the add step")
        draft.undo()
        #expect(draft.flow == before)
    }

    @Test func aBrandNewNoteCommittedEmptyStaysAndIsOneUndo() async throws {
        let (_, _, draft, _) = try await fixture()
        let before = draft.flow
        let id = draft.addNote()
        draft.commitNoteEdit()
        #expect(draft.flow.notes.map(\.id) == [id])
        #expect(draft.undoStack.count == 1)
        draft.undo()
        #expect(draft.flow == before)
    }

    @Test func escapeOnAnExistingNoteKeepsItsTextAndHistory() async throws {
        let (_, _, draft, window) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 600), text: "old")
        let undos = draft.undoStack.count
        try await typeIntoOpenNote(draft, window, id, "zzz")
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(text(draft.flow, id) == "old" && draft.undoStack.count == undos)
    }

    @Test func aSecondEditOfANoteIsItsOwnUndoStep() async throws {
        let (_, _, draft, _) = try await fixture()
        let id = draft.addNote()
        draft.updateNoteDraft("one")
        draft.commitNoteEdit()
        let undos = draft.undoStack.count
        draft.beginEditingNote(id)
        draft.updateNoteDraft("two")
        draft.commitNoteEdit()
        #expect(draft.undoStack.count == undos + 1)
        draft.undo()
        #expect(text(draft.flow, id) == "one")
    }

    // MARK: 7. Grab sizes are screen sizes

    @Test func edgeBandAndHandleKeepTheirScreenSizeUnderZoom() throws {
        let note = FlowNote(id: "f", text: "", origin: CanvasPoint(x: 0, y: 0), width: 1000, height: 800, surrounds: true)
        let flow = Flow(name: "t", nodes: [], wires: [], notes: [note])
        for zoom in [0.25, 1.0] {
            let g = CanvasGeometry(pan: ScreenPoint(x: Pixels(0), y: Pixels(0)), zoom: zoom)
            func part(screenX: Double, screenY: Double) -> NotePart? {
                g.hitNote(at: CanvasPoint(x: screenX / zoom, y: screenY / zoom), in: flow, selected: ["f"]).map(\.1)
            }
            let right = 1000 * zoom, bottom = 800 * zoom
            #expect(part(screenX: right - 5, screenY: bottom / 2) == .chrome, "5 pt in is the band at zoom \(zoom)")
            #expect(part(screenX: right - 8, screenY: bottom / 2) == nil, "8 pt in is the interior at zoom \(zoom)")
            #expect(part(screenX: right - 10, screenY: bottom - 10) == .handle, "10 pt from the corner is the handle at zoom \(zoom)")
            #expect(part(screenX: right - 14, screenY: bottom - 14) != .handle, "14 pt is not at zoom \(zoom)")
        }
    }

    @Test func theDrawnHandleIsTwelvePointsAtAnyZoom() async throws {
        let (_, _, draft, window) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 400))
        draft.canvasSelection = CanvasSelection(notes: [id])
        draft.geometry = CanvasGeometry(pan: ScreenPoint(x: Pixels(30), y: Pixels(20)), zoom: 0.25)
        try await window.runUntilIdle()
        let handle = try window.element(identifier: "note.\(id.rawValue).handle").frame
        #expect(abs(handle.size.width.value - 12) < 0.5 && abs(handle.size.height.value - 12) < 0.5)
    }

    // MARK: 8. Leaving the Studio mid-gesture

    @Test func leavingTheStudioClearsGestureState() async throws {
        let (model, _, draft, window) = try await fixture()
        let before = draft.flow
        let frame = try #require(draft.canvasFrame)
        draft.movePaletteDrag(.node(.shell), from: ScreenPoint(x: frame.origin.x - 50, y: frame.origin.y + 50),
                              to: ScreenPoint(x: frame.origin.x + 100, y: frame.origin.y + 100))
        draft.openNodeSearch()
        let node = try center(window, "node.gate")
        press(window, node)
        moveHeld(window, ScreenPoint(x: node.x + 40, y: node.y + 30))
        try await window.runUntilIdle()
        #expect(draft.paletteDrag != nil && draft.nodeSearch != nil && draft.dragMode != nil)
        model.screen = .dashboard
        try await window.runUntilIdle()
        #expect(draft.paletteDrag == nil && draft.nodeSearch == nil && draft.dragMode == nil)
        #expect(draft.pendingWire == nil && draft.selectionBox == nil && draft.dragStartFlow == nil)
        #expect(draft.flow == before, "the lost move is undone")
        model.screen = .studio
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "palette.drag")) == nil)
        #expect((try? window.element(identifier: "search.pane")) == nil)
    }

    // MARK: 9. One undo for group actions, and undo or redo mid-edit

    @Test func groupMoveWithNotesRestoresInOneUndo() async throws {
        let (_, _, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 100))
        draft.canvasSelection = CanvasSelection(nodes: ["gate"], notes: [id])
        let before = draft.flow
        let undos = draft.undoStack.count
        let from = try screen(window, draft, CanvasPoint(x: 844, y: 255))
        window.drag(from: from, to: ScreenPoint(x: from.x + 30, y: from.y + 30))
        try await window.runUntilIdle()
        #expect(draft.flow != before)
        window.typeKey("z", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow == before)
        #expect(draft.undoStack.count == undos)
    }

    @Test func aNoteDroppedFromThePaletteIsOneUndo() async throws {
        let (_, _, draft, window) = try await fixture()
        try await zoomedOut(draft, window)
        let before = draft.flow
        let frame = try #require(draft.canvasFrame)
        let start = ScreenPoint(x: frame.origin.x - 50, y: frame.origin.y + 50)
        let drop = ScreenPoint(x: frame.origin.x + 300, y: frame.origin.y + 300)
        draft.movePaletteDrag(.note, from: start, to: drop)
        #expect(draft.endPaletteDrag(.note, from: start, at: drop) != nil)
        try await window.runUntilIdle()
        #expect(draft.flow.notes.count == 1)
        draft.undo()
        try await window.runUntilIdle()
        #expect(draft.flow == before)
        #expect(draft.editingNote == nil)
    }

    @Test func aNoteAddedFromTheSearchPaneIsOneUndo() async throws {
        let (_, _, draft, window) = try await fixture()
        let before = draft.flow
        draft.openNodeSearch()
        draft.setNodeSearchQuery("note")
        #expect(draft.confirmNodeSearch() == .note("note1"))
        try await window.runUntilIdle()
        draft.undo()
        #expect(draft.flow == before)
        #expect(draft.editingNote == nil)
    }

    @Test func undoWhileAnEditIsOpenCommitsItFirst() async throws {
        let (_, _, draft, window) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 600), text: "old")
        try await typeIntoOpenNote(draft, window, id, "new")
        draft.undo()
        try await window.runUntilIdle()
        #expect(draft.noteEdit == nil, "the editor is closed")
        #expect(text(draft.flow, id) == "old", "undo took back the typed text, not something earlier")
        draft.redo()
        #expect(text(draft.flow, id)?.hasSuffix("new") == true)
    }

    @Test func redoWhileAnEditIsOpenCommitsItFirst() async throws {
        let (_, _, draft, window) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 600))
        draft.edit("rename") { $0.name = "A" }
        draft.undo()
        try await typeIntoOpenNote(draft, window, id, "x")
        draft.redo()
        try await window.runUntilIdle()
        #expect(draft.noteEdit == nil, "the editor is closed")
        #expect(text(draft.flow, id) == "x", "the typed text was committed, not left pending on the redone state")
    }

    // MARK: 10. A reopened note's caret

    @Test func reopeningAStickyPutsTheCaretAtTheEnd() async throws {
        let (_, _, draft, window) = try await fixture()
        let id = sticky(draft, at: CanvasPoint(x: 200, y: 600), text: "hello")
        draft.beginEditingNote(id)
        try await window.runUntilIdle()
        window.typeText("!")
        try await window.runUntilIdle()
        #expect(draft.noteEdit?.draft == "hello!")
    }

    @Test func reopeningAFrameSelectsItsTitle() async throws {
        let (_, _, draft, window) = try await fixture()
        draft.canvasSelection = CanvasSelection(nodes: ["plan"])
        let id = draft.addNote()
        draft.updateNoteDraft("Title")
        draft.commitNoteEdit()
        draft.beginEditingNote(id)
        try await window.runUntilIdle()
        window.typeText("Z")
        try await window.runUntilIdle()
        #expect(draft.noteEdit?.draft == "Z")
    }
}
