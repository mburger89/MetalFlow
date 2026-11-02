# Canvas Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the Flow Studio, select several nodes, drag nodes from the palette onto the canvas, press Tab to search for a node to add, and put notes on the canvas or around selected nodes.

**Architecture:** Behaviour lives in `FlowDraft` extensions, tested without a window; views stay thin, as they are today and as in MetalCreator's `EditorModel`. Selection becomes a value of several kinds. Notes are a new optional `Flow.notes` list that the engine and validation never read.

**Tech Stack:** Swift, MetalUI, Swift Testing, MetalUITesting.

**Spec:** None. The user's request is the source: "I should be able to drag nodes on to the canvas and I should be able to call up a search pane when I hit tab and start searching for a node. I should also be able to make notes on the canvas or around select nodes, I should be able to select multiple nodes as well." The Decisions below are the authority once the user approves this plan.

**Reference:** `../MetalCreator/Sources/CreatorEditor` (read it; do not copy its types). `CanvasSelection`, `SelectionMode`, `CommentLayout`, `EditorModel+CommentMembers`, `EditorModel+Library`, `SearchPaletteOverlay`, `SearchPaletteView`, `GraphPanelInput`. Its session answered questions on 2026-11-02; its warnings are repeated where they apply.

## Decisions

1. **A plain drag on empty canvas draws a selection box. It no longer pans.** The user confirmed on 2026-11-02: two-finger scroll pans, pinch zooms, and middle or right drag remain for a mouse. The existing wheel and ⌘-wheel behaviour stays.
2. **Modifiers:** a plain click replaces the selection, ⇧ adds, ⌘ toggles (⌘ wins). They apply to clicks and to the box. ⌘A selects all nodes and notes. Esc clears. Delete removes everything selected as one undo step.
3. **Dragging a selected node moves everything selected, as one undo step.** A note in the selection moves too. Dragging an unselected node selects only it first (with ⇧, adds it). Wires are not part of a multi-selection: a wire click stays a single exclusive selection.
4. **The inspector** shows the single node's settings when exactly one node is selected, and "N selected" with a Delete button otherwise.
5. **Palette rows both click and drag.** Click adds at the canvas centre, as today. A drag past 4 points shows the node's label under the pointer; dropping on the canvas centres the node on the drop point; dropping anywhere else adds nothing. Esc is not handled during this drag.
6. **Tab opens the search pane** when the canvas has key focus or the pointer is over it and no text field is focused. It opens at the pointer, or the canvas centre if the pointer is elsewhere. The node lands where the pane opened. Typing filters by case-insensitive substring of the label, ↑/↓ move, Return adds, a click adds, Esc or a click outside closes. The new node is selected. No automatic wiring.
7. **One note type, two shapes.** `FlowNote` has `text`, `frame`, and `surrounds`. A sticky (`surrounds: false`) sits above wires and below nodes. A frame (`surrounds: true`) sits below wires and has a title strip.
8. **Creating a note:** press **N** on the canvas, or pick **Note** in the palette or the Tab pane. With nodes selected it creates a frame around them; with none it creates a sticky at the pointer (or the canvas centre, or the drop point). It opens for typing either way.
9. **A frame holds whichever nodes' centres lie inside it, worked out at drag start and never saved.** Moving a frame carries those nodes. Dragging a node out needs no bookkeeping. Stickies carry nothing.
10. **Only a frame's title strip and a 6-point edge band grab the frame,** so clicks and box drags inside it still reach nodes and empty canvas. A selected note has a 12-point resize handle at its bottom-right corner.
11. **Editing:** double-click a note to edit. Return commits a frame title, ⌘Return commits a sticky, Esc cancels, losing focus commits. Each edit is one undo step.
12. **Notes never affect a run.** `Flow.notes` is left out of the file when empty, so existing flow files save byte for byte as before. `formatVersion` stays. An older build ignores the key on load, and would drop notes if it saved.
13. **Notes are counted by Fit,** and they make a draft dirty like any other edit.
14. **Not in this plan:** copy, paste and duplicate; arrow-key nudging; note colours; snapping; dragging a wire onto empty canvas to open the pane. The user did not ask for these.
15. **Branch from master, independent of `review-node`.** The two overlap in three Studio files by a few lines. The palette and search read `PaletteKind.groups`, so Review appears in both once merged. Whichever lands second resolves the overlap.

## Global Constraints

- No SwiftUI or AppKit workaround for a MetalUI gap, and no patching `../MetalUI`. Ask the "Mini MetalUI" session to fix or add it, and report that to the controller.
- Tests: `swift test --no-parallel -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`, typed literally in zsh. Long runs go to a file. AppKit tests can flake; rerun once.
- Failing test first, seen failing on an assertion rather than a compile error where the type already exists. Say so in the report if it slips.
- `.claude/` stays untracked. No pushing.
- Commit trailers: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_0195iKYn69jgc6AKCLYiUKab`. Commit messages are plain imperative sentences, as in `git log`.
- New controls carry accessibility identifiers, following `palette.*`, `node.*`, `inspector.*`.
- A panning canvas must not rebuild node cards: keep `NodeCardView` equatable, and give note views the same treatment.

## Review Focus

1. **Tab or a typed N while a text field is focused** (inspector, flow name, note editor) goes to the field. Test: focus a field, send Tab and `n`, no pane opens and no note appears.
2. **Undo after a group action** (group move, group delete, carried frame move, drop, new note) restores everything in one ⌘Z, and a stale selection is dropped. Test each.
3. **Dropping or adding under pan and zoom.** Test at zoom 0.5 with a non-zero pan: the node's centre is the drop point in canvas units, and the palette's global coordinates are converted by the canvas's frame, not by layout constants.
4. **Old flow files and old runs still load, and a flow without notes saves unchanged.** Test: decode a handwritten JSON fixture with no `notes`; encode a note-less flow and assert no `notes` key; a run record containing a flow still round-trips.
5. **Selection with a run showing, or across `draft` replacement.** The Candidates strip and run overlay keep working. Selecting several nodes while a run is shown must not change what the overlay shows. Test: `NodeOverlay` output is unchanged with two nodes selected.

---

### Task 1: Select several nodes

**Files:**
- Create: `Sources/MetalFlowKit/Studio/CanvasSelection.swift`, `Sources/MetalFlowKit/Studio/FlowDraft+Selection.swift`, `Tests/MetalFlowKitTests/CanvasSelectionTests.swift`
- Modify: `FlowDraft.swift`, `CanvasView.swift`, `CanvasGeometry.swift`, `WireLayer.swift`, `InspectorView.swift`, `NodeCardView.swift` if needed

**Interfaces:**
- Produces:
  - `struct CanvasSelection: Equatable { var nodes: Set<NodeID>; var notes: Set<NoteID>; var wire: Wire?; var isEmpty: Bool }`. `NoteID` arrives in Task 3; until then omit `notes` and let Task 3 add it.
  - `enum SelectionMode { case replace, add, toggle; init(_ modifiers: EventModifiers) }`
  - `FlowDraft.canvasSelection: CanvasSelection` (stored, observable, not undone).
  - `FlowDraft.selection: NodeID?` stays public as a computed bridge. Get: the node when exactly one node is selected and nothing else, else nil. Set: replaces the whole selection. Existing callers and tests keep compiling and passing. `selectedWire` bridges the same way.
  - `func select(at: ScreenPoint, modifiers: EventModifiers)`, `func selectAll()`, `func clearSelection()`
  - `DragMode` gains `.box(start: ScreenPoint, base: CanvasSelection, mode: SelectionMode)`, and `.move` becomes `.move(origins: [NodeID: CanvasPoint])` (Task 3 adds notes).
  - `FlowDraft.selectionBox: CanvasRect?` in screen points, while a box is being drawn.
  - `CanvasGeometry.nodes(in: CanvasRect, flow: Flow) -> [NodeID]`: any overlap selects.
  - `WireLayer.paths(flow:geometry:selection: Set<NodeID>, selectedWire:)`.

- [ ] **Step 1: Write failing tests** in `CanvasSelectionTests`: `plainClickReplaces`, `shiftClickAdds`, `commandClickToggles`, `commandWinsOverShift`, `clickOnEmptyCanvasClearsWithoutModifiers`, `shiftClickOnEmptyCanvasKeepsSelection`, `plainDragOnEmptyCanvasDrawsABoxAndDoesNotPan` (pan is unchanged, box selects overlapped nodes at zoom 0.5 with a non-zero pan), `shiftBoxAddsCommandBoxToggles`, `draggingASelectedNodeMovesAllSelectedAsOneUndo`, `draggingAnUnselectedNodeSelectsOnlyIt`, `shiftDraggingAnUnselectedNodeAddsIt`, `deleteRemovesAllSelectedAndTheirWiresAsOneUndo`, `undoDropsStaleSelection`, `selectAllSelectsEveryNode`, `escapeClearsSelection`, `selectionBridgeIsNilWithTwoSelected`, `aWireClickClearsNodesAndAShiftClickOnAWireDoesNotAddIt` (it replaces, per Decision 3), `wiresTouchingAnySelectedNodeHighlight`, `overlayIsUnchangedWithTwoNodesSelected`, `inspectorShowsCountAndDeleteForTwoNodes`, `inspectorShowsSettingsForOneNode`.
- [ ] **Step 2: Run them.** Expected: fail to compile on `CanvasSelection`, then fail on assertions once the type stubs exist.
- [ ] **Step 3: Implement.** `SpatialTapGesture.Value.modifiers` and `DragGesture.Value.modifiers` carry the keys. Add `SelectionBoxView` (a translucent `Palette.accent` rectangle, no hit testing) above the port layer. Add `.onKeyPress` handling for ⌘A and Esc in `CanvasView.key`. Add `.hoverKeyRegion()` to the canvas so these keys work with nothing focused and the pointer over it; a focused field keeps every key. Keep the drag's minimum distance of 3 so a click stays a tap.
- [ ] **Step 4: Run the whole suite.** Any test that relied on panning by plain drag gets updated to a middle drag, named in the report.
- [ ] **Step 5: Commit** `Select several nodes on the canvas`.

### Task 2: Drag from the palette, and search with Tab

**Files:**
- Create: `Sources/MetalFlowKit/Studio/NodeSearchPane.swift`, `Sources/MetalFlowKit/Studio/FlowDraft+Adding.swift`, `Tests/MetalFlowKitTests/CanvasAddingTests.swift`
- Modify: `PaletteView.swift`, `CanvasView.swift`, `StudioView.swift`, `FlowDraft.swift`

**Interfaces:**
- Consumes: `canvasSelection` from Task 1.
- Produces:
  - `FlowDraft.addNode(_:centredAt: ScreenPoint) -> NodeID`; the existing `addNode(_:)` calls it with the canvas centre.
  - `FlowDraft.canvasFrame: Bounds<Pixels>?` in window points, reported by `CanvasView`'s `onGeometryChange`. Nothing computes it from layout constants.
  - `FlowDraft.paletteDrag: PaletteDrag?` with `kind` and `windowPoint`; `movePaletteDrag`, `endPaletteDrag`, `cancelPaletteDrag`.
  - `FlowDraft.pointer: ScreenPoint?` and `pointerInWindow`, from the canvas's `onContinuousHover`.
  - `struct NodeSearch { var query: String; var highlighted: Int; var windowPoint: ScreenPoint; var dropPoint: ScreenPoint }`, `FlowDraft.nodeSearch: NodeSearch?`, `openNodeSearch()`, `setNodeSearchQuery(_:)`, `moveNodeSearch(by:)`, `confirmNodeSearch(_ kind: PaletteKind? = nil)`, `closeNodeSearch()`, `nodeSearchMatches: [PaletteKind]`.

- [ ] **Step 1: Write failing tests** in `CanvasAddingTests`: `dropCentresTheNodeUnderPanAndZoom` (zoom 0.5, non-zero pan, canvas frame not at the window origin), `dropOutsideTheCanvasAddsNothing`, `aShortDragIsAClickAndAddsAtTheCentre`, `dropIsOneUndoAndSelectsTheNode`, `cancelledDragAddsNothing`, `tabOpensThePaneAtThePointer`, `tabWithAFocusedFieldDoesNotOpenThePane`, `tabWithThePointerElsewhereAndNoCanvasFocusIsIgnored`, `queryFiltersCaseInsensitivelyAndResetsTheHighlight`, `arrowsClampAtTheEnds`, `returnAddsTheHighlightedNodeAtTheOpeningPoint`, `returnWithNoMatchesDoesNothing`, `escapeClosesAndAddsNothing`, `clickingARowAdds`, `everyPaletteKindIsSearchable` (compared with `PaletteKind.groups`).
- [ ] **Step 2: Run them.** Expected: fail.
- [ ] **Step 3: Implement the palette drag.** MetalCreator's warnings apply: a `Button` row's click holds the drag off, so a row is a label under one `DragGesture(minimumDistance: Pixels(0), coordinateSpace: .global)` that treats under 4 points as a click and keeps the `palette.<prefix>` identifier and an accessibility button action. Do not use MetalUI's `draggable` here, since it becomes a system drag once it leaves the window. Draw the drag's label at `StudioBody`'s root, not inside the canvas, or it clips. End through `onCancelled` too. Existing `press("palette.*")` tests must keep passing unchanged.
- [ ] **Step 4: Implement the pane.** Use `anchoredOverlay(isPresented:at:in: .global)` at `StudioBody`'s root, which handles edge flipping, outside clicks, Esc and swallowing scroll. The field is `.focused` on appear, with `.onKeyPress(keys:)` on it for ↑ and ↓ (MetalUI gap M5-h is closed; do not use the window keymap) and `.onSubmit` to confirm. Identifiers: `nodeSearch`, `nodeSearch.field`, `nodeSearch.<prefix>`. Fixed size, so it does not jump as results change.
- [ ] **Step 5: Run the whole suite.**
- [ ] **Step 6: Commit** `Drag nodes from the palette and search for them with Tab`.

### Task 3: Notes in the flow, and on the canvas

**Files:**
- Create: `Sources/MetalFlowCore/Graph/FlowNote.swift`, `Sources/MetalFlowKit/Studio/FlowDraft+Notes.swift`, `Sources/MetalFlowKit/Studio/NoteViews.swift`, `Tests/MetalFlowCoreTests/FlowNoteTests.swift`, `Tests/MetalFlowKitTests/CanvasNotesTests.swift`
- Modify: `Flow.swift`, `CanvasSelection.swift`, `CanvasGeometry.swift`, `CanvasView.swift`, `FlowDraft.swift`, `PaletteView.swift`, `NodeSearchPane.swift`, `InspectorView.swift`

**Interfaces:**
- Consumes: `CanvasSelection`, `DragMode`, `addNode` drop handling, `nodeSearch`.
- Produces:
  - `struct NoteID: RawRepresentable, Codable, Hashable, Sendable` with values `note1`, `note2`, ...
  - `struct FlowNote: Codable, Hashable, Sendable { var id: NoteID; var text: String; var origin: Point; var width: Double; var height: Double; var surrounds: Bool }`
  - `Flow.notes: [FlowNote]`, defaulted in `init` so the 65 existing `Flow(name:nodes:wires:)` call sites compile. Custom `Codable`: `decodeIfPresent ?? []`, omitted from the encoding when empty.
  - `CanvasSelection.notes: Set<NoteID>`; `DragMode.move` gains note origins and `.resize(NoteID, origin: size)`.
  - `FlowDraft.addNote(at: ScreenPoint?) -> NoteID` (a frame around selected nodes, else a sticky), `setNoteText`, `members(of: FlowNote) -> [NodeID]`, `beginEditingNote`, `commitNoteEdit`, `cancelNoteEdit`, `editingNote: NoteID?`.
  - `CanvasGeometry.hitNote(at:in:) -> (NoteID, NotePart)?`, with `NotePart` of `.body`, `.chrome`, `.handle`. Sizes: new sticky 200×120; frame padding 24; title strip 22; edge band 6; handle 12; minimum 80×40. All computed, never measured.
  - Palette item `Note` under a new `NOTES` group, kept apart from `PaletteKind` (it is not a node) through a `PaletteEntry` enum of `.node(PaletteKind)` and `.note`, used by the palette and by search.

- [ ] **Step 1: Write failing Core tests:** `flowWithoutNotesKeyDecodes` (a handwritten fixture), `flowWithoutNotesEncodesNoNotesKey`, `notesRoundTripThroughFlowFile`, `runRecordWithNotesRoundTrips`, `notesDoNotAffectValidationOrThePlan`.
- [ ] **Step 2: Write failing Kit tests:** `nWithNothingSelectedAddsAStickyAtThePointerAndOpensIt`, `nWithNodesSelectedAddsAFrameAroundThem` (bounds plus padding plus title strip), `nInAFocusedFieldTypes`, `noteFromPaletteClickAndDropAndSearch`, `aFrameCarriesNodesWhoseCentresAreInsideAsOneUndo`, `aNodeDraggedOutOfAFrameIsNoLongerCarried`, `aStickyCarriesNothing`, `insideAFrameAClickSelectsTheNodeAndABoxStillDraws`, `titleStripAndEdgeBandGrabTheFrame`, `boxWhollyInsideAFrameDoesNotSelectTheFrame`, `resizeHandleResizesOneUndoAndClampsToTheMinimum`, `handleOnlyWorksWhenSelected`, `doubleClickEdits`, `returnCommitsTitleCommandReturnCommitsStickyEscapeCancels`, `losingFocusCommits`, `anEditIsOneUndo`, `deleteRemovesSelectedNotesAndNodesTogether` (deleting a frame leaves its nodes), `fitIncludesNotes`, `drawOrderIsFramesWiresStickiesNodes`, `selectAllIncludesNotes`.
- [ ] **Step 3: Run them.** Expected: fail.
- [ ] **Step 4: Implement the model** and confirm the Core tests pass.
- [ ] **Step 5: Implement the canvas.** Hit order: port, selected note's handle, node, sticky, frame chrome, wire, empty. Double-click reads `SpatialTapGesture.Value.clickCount`, so the OS's double-click speed decides. MetalCreator's warning applies: the note editor field must be a sibling of the keyed canvas surface, never inside it, or its keys reach the canvas handler. No shadows on note views. Hit testing must see every note. Key `ForEach` on `id.rawValue`. The inspector shows "Note" with its text for one selected note, and a count for mixed selections.
- [ ] **Step 6: Run the whole suite.**
- [ ] **Step 7: Commit** `Add notes on the canvas and around selected nodes`.

### Task 4: Hand it over on screen

Not delegated. The controller runs this, after the whole-branch review.

- [ ] **Step 1:** Run the full suite on the branch.
- [ ] **Step 2:** Bundle from the worktree to a scratch path and tell the user what to try: palette drag at a zoomed canvas; Tab, type, arrows, Return; Tab with a field focused; box select; ⇧ and ⌘ click; group drag and ⌘Z; N with and without a selection; moving a frame with nodes inside; resize; double-click to edit; save, reopen and see the notes; a run from a flow with notes. This session has no computer use, so these are checked by the user.
