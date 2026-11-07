import Foundation
import MetalFlowCore
import MetalUI
import Observation

/// A flow being viewed or edited in the Studio: the flow, where it lives, its validation, undo history,
/// the canvas view and the selection.
@Observable @MainActor
public final class FlowDraft {
    /// The most undo steps kept.
    public static let historyLimit = 100

    /// The flow as edited.
    public private(set) var flow: Flow {
        didSet { validation = Self.validate(flow) }
    }
    /// Where the flow lives: the built-in, not yet saved, a library file or a repo's `.flows` file.
    public var location: FlowLocation
    /// The file it was loaded from or saved to; nil for the built-in and for a flow not yet saved.
    public var url: URL? {
        switch location {
        case .library(let file), .repo(_, let file): file
        case .builtin, .unsaved: nil
        }
    }
    /// The flow as last loaded or saved.
    public private(set) var lastSavedFlow: Flow
    /// Whether the flow differs from the one last loaded or saved. Undoing back to it makes the draft clean.
    public var isDirty: Bool { flow != lastSavedFlow || pendingNoteEditChangesFlow }
    /// The plan, or why the flow cannot run. Recomputed on every change.
    public private(set) var validation: Result<FlowPlan, FlowError>
    /// Earlier states of the flow, oldest first.
    public private(set) var undoStack: [Flow] = []
    /// States undone, most recently undone last.
    public private(set) var redoStack: [Flow] = []
    /// What is selected. View state: never undone. Selecting different nodes ends a typing burst.
    var canvasSelection = CanvasSelection() {
        didSet { if canvasSelection.nodes != oldValue.nodes || canvasSelection.notes != oldValue.notes { lastEditName = nil } }
    }
    /// The selected node: the one node when exactly one node and nothing else is selected, else nil. Setting
    /// replaces the selection with that node (nil clears the nodes).
    public var selection: NodeID? {
        get { canvasSelection.count == 1 && canvasSelection.wire == nil ? canvasSelection.nodes.first : nil }
        set {
            if let newValue {
                canvasSelection = CanvasSelection(nodes: [newValue])
            } else {
                canvasSelection.nodes = []
            }
        }
    }
    /// The selected wire; exclusive with node selection. Setting one replaces the selection (nil drops the wire).
    public var selectedWire: Wire? {
        get { canvasSelection.wire }
        set {
            if let newValue {
                canvasSelection = CanvasSelection(wire: newValue)
            } else {
                canvasSelection.wire = nil
            }
        }
    }
    /// The box being drawn, in canvas-local screen points.
    var selectionBox: CanvasRect?
    /// The wire being dragged out of an out-port: its source and the pointer, in canvas-local screen points.
    var pendingWire: (from: NodeID, to: ScreenPoint)?

    /// The canvas view transform.
    var geometry = CanvasGeometry()
    /// The canvas view's size, once measured.
    var canvasSize: Size<Pixels>?
    /// The canvas view's frame in window points, once measured. Drops and the search pane convert between window
    /// and canvas-local points with it.
    var canvasFrame: Bounds<Pixels>?
    /// The palette row being dragged, once the pointer is past the click threshold.
    var paletteDrag: PaletteDrag?
    /// The pointer over the canvas in window points; nil while it is elsewhere.
    @ObservationIgnored var pointerInWindow: ScreenPoint?
    /// The Tab search pane, while open.
    var nodeSearch: NodeSearch?
    /// The note being typed into, while its field is open. The text is written to the flow when the edit commits.
    var noteEdit: NoteEdit?
    /// The open note field's selection (a `TextSelection`, type-erased because it needs macOS 15): what it opened with,
    /// then what the field last reported.
    var noteSelection: AnyHashable?
    /// The note added by the edit now open and the undo depth just after its add step, while that edit is its first:
    /// committing joins the add step and cancelling takes it back.
    @ObservationIgnored var newNote: (id: NoteID, depth: Int)?
    @ObservationIgnored private var hasFitted = false
    @ObservationIgnored var panStart: ScreenPoint?
    /// Where the press behind `panStart` landed; a drag that starts elsewhere is a new gesture.
    @ObservationIgnored var panPress: ScreenPoint?
    /// Where the press behind `dragMode` landed.
    @ObservationIgnored var dragPress: ScreenPoint?
    /// What the current primary drag is doing.
    @ObservationIgnored var dragMode: DragMode?
    /// The flow when a node drag began; its undo step's before-state.
    @ObservationIgnored var dragStartFlow: Flow?
    /// The name of the last edit, while it can still absorb more of the same typing burst.
    @ObservationIgnored var lastEditName: String?
    /// The allowed-tools text being typed, as long as it still parses to the node's tools.
    var toolsBuffer: (node: NodeID, text: String)?
    /// The local-model name being typed for a node, once "Local model…" is picked.
    var localModelBuffer: (node: NodeID, text: String)?
    /// The local-model name being typed for one candidate of a node, once "Local model…" is picked there.
    var candidateLocalModelBuffer: (node: NodeID, index: Int, text: String)?
    @ObservationIgnored var pinchStart: (pan: ScreenPoint, zoom: Double)?

    /// Creates a draft.
    public init(flow: Flow, location: FlowLocation) {
        self.flow = flow
        self.lastSavedFlow = flow
        self.location = location
        self.validation = Self.validate(flow)
    }

    private static func validate(_ flow: Flow) -> Result<FlowPlan, FlowError> {
        do { return .success(try flow.validate()) } catch { return .failure(error) }
    }

    /// The plan when the flow is valid.
    public var plan: FlowPlan? { try? validation.get() }

    /// Applies `change` to the flow as one undo step named `name`. Consecutive edits with the same name (one typing
    /// session in a field) replace that step's result instead of adding another.
    public func edit(_ name: String, _ change: (inout Flow) -> Void) {
        apply(name, coalescing: true, change)
    }

    /// Applies a change; `coalescing` lets it join the previous edit of the same name.
    func apply(_ name: String, coalescing: Bool, _ change: (inout Flow) -> Void) {
        var updated = flow
        change(&updated)
        guard updated != flow else { return }
        if coalescing, lastEditName == name, let before = undoStack.last, redoStack.isEmpty {
            flow = updated
            if updated == before {
                // The burst reverted itself: its step is gone and must not absorb the next keystroke.
                undoStack.removeLast()
                lastEditName = nil
            }
            return
        }
        pushUndo(flow)
        flow = updated
        lastEditName = coalescing ? name : nil
    }

    private func pushUndo(_ before: Flow) {
        undoStack.append(before)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
        redoStack = []
    }

    /// Takes the newest undo step off the stack, returning the flow it held; nothing goes to the redo stack.
    func takeLastUndoState() -> Flow? { undoStack.popLast() }

    /// Replaces the flow without an undo step; the caller keeps the history consistent.
    func replaceFlowWithoutHistory(_ updated: Flow) { flow = updated }

    /// Whether a drag is under way, on the canvas or from the palette: edits by key wait for it to end.
    var isGestureActive: Bool { dragMode != nil || paletteDrag != nil }

    /// Steps back one edit. An open note edit is committed first, so its text is not left to land on the undone
    /// state; a drag under way ignores it.
    public func undo() {
        guard !isGestureActive else { return }
        commitNoteEdit()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(flow)
        flow = previous
        lastEditName = nil
        dropStaleSelection()
    }

    /// Re-applies the last undone edit. An open note edit is committed first.
    public func redo() {
        guard !isGestureActive else { return }
        commitNoteEdit()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(flow)
        flow = next
        lastEditName = nil
        dropStaleSelection()
    }

    func dropStaleSelection() {
        let nodes = canvasSelection.nodes.filter { flow.node($0) != nil }
        if nodes != canvasSelection.nodes { canvasSelection.nodes = nodes }
        let notes = canvasSelection.notes.filter { id in flow.notes.contains { $0.id == id } }
        if notes != canvasSelection.notes { canvasSelection.notes = notes }
        if let selectedWire, !flow.wires.contains(selectedWire) { self.selectedWire = nil }
        if let edit = noteEdit, !flow.notes.contains(where: { $0.id == edit.id }) {
            noteEdit = nil
            noteSelection = nil
            newNote = nil
        }
    }

    // MARK: Structural edits

    /// The id `<prefix><n>` with the smallest positive `n` no node uses.
    func uniqueID(prefix: String) -> NodeID {
        var n = 1
        while flow.node(NodeID(rawValue: "\(prefix)\(n)")) != nil { n += 1 }
        return NodeID(rawValue: "\(prefix)\(n)")
    }

    /// Removes a node and every wire touching it, as one undo step.
    public func deleteNode(_ id: NodeID) {
        removeNodes([id], name: "delete \(id.rawValue)")
    }

    /// Removes `ids` with every wire touching them, and the notes `noteIDs`, as one undo step named `name`, and drops
    /// them from the selection. The nodes inside a removed frame stay.
    private func removeNodes(_ ids: Set<NodeID>, notes noteIDs: Set<NoteID> = [], name: String) {
        apply(name, coalescing: false) { flow in
            flow.nodes.removeAll { ids.contains($0.id) }
            flow.wires.removeAll { ids.contains($0.from) || ids.contains($0.to) }
            flow.notes.removeAll { noteIDs.contains($0.id) }
        }
        canvasSelection.nodes.subtract(ids)
        canvasSelection.notes.subtract(noteIDs)
        if let edit = noteEdit, noteIDs.contains(edit.id) { noteEdit = nil }
    }

    /// Removes the selected nodes with their wires, and the selected notes, as one undo step, or the selected wire.
    public func deleteSelection() {
        let ids = canvasSelection.nodes, notes = canvasSelection.notes
        if ids.count == 1, notes.isEmpty, let id = ids.first {
            deleteNode(id)
        } else if ids.isEmpty, notes.count == 1, let id = notes.first {
            removeNodes([], notes: [id], name: "delete \(id.rawValue)")
        } else if !ids.isEmpty || !notes.isEmpty {
            removeNodes(ids, notes: notes, name: "delete \(ids.count + notes.count) items")
        } else if let wire = selectedWire {
            apply("delete wire", coalescing: false) { flow in
                if let i = flow.wires.firstIndex(of: wire) { flow.wires.remove(at: i) }
            }
            selectedWire = nil
        }
    }

    /// Wires `from`'s output into `to`. The input name defaults to the source id, with `_2`, `_3`... if `to`
    /// already has one of that name. A wire from a node to itself, or an exact duplicate, is refused; with
    /// `allowParallel` false so is any second wire between the same pair.
    public func connect(from: NodeID, to: NodeID, input: String? = nil, allowParallel: Bool = true) {
        guard from != to, flow.node(from) != nil, flow.node(to) != nil else { return }
        if !allowParallel, flow.wires.contains(where: { $0.from == from && $0.to == to }) { return }
        let taken = Set(flow.inputs(of: to).map(\.input))
        var name = input ?? from.rawValue
        if input == nil {
            var n = 2
            while taken.contains(name) { name = "\(from.rawValue)_\(n)"; n += 1 }
        }
        let wire = Wire(from: from, to: to, input: name)
        guard !flow.wires.contains(wire) else { return }
        apply("connect \(from.rawValue) \(to.rawValue)", coalescing: false) { flow in
            flow.wires.append(wire)
            // A wire takes over the input: a binding on the same name would make it bound twice.
            if let i = flow.nodes.firstIndex(where: { $0.id == to }) { flow.nodes[i].inputs[name] = nil }
        }
    }

    // MARK: Moving

    /// Moves the nodes in `origins` and the notes in `noteOrigins` by `delta` canvas units, without an undo step.
    func moveLive(_ origins: [NodeID: CanvasPoint], notes noteOrigins: [NoteID: CanvasPoint] = [:], by delta: CanvasPoint) {
        var updated = flow
        for i in updated.nodes.indices {
            if let origin = origins[updated.nodes[i].id] {
                updated.nodes[i].position = CanvasPoint(x: origin.x + delta.x, y: origin.y + delta.y)
            }
        }
        for i in updated.notes.indices {
            if let origin = noteOrigins[updated.notes[i].id] {
                updated.notes[i].origin = CanvasPoint(x: origin.x + delta.x, y: origin.y + delta.y)
            }
        }
        flow = updated
    }

    /// Sets a note's size to its size at drag start plus `delta` canvas units, no smaller than the minimum, without
    /// an undo step.
    func resizeLive(_ id: NoteID, from origin: CanvasRect, by delta: CanvasPoint) {
        var updated = flow
        guard let i = updated.notes.firstIndex(where: { $0.id == id }) else { return }
        updated.notes[i].width = max(origin.w + delta.x, NoteLayout.minimumWidth)
        updated.notes[i].height = max(origin.h + delta.y, NoteLayout.minimumHeight)
        flow = updated
    }

    /// A primary drag was dropped without a release (the system took it, or a second press began): puts back what it
    /// had changed and clears its state, leaving the draft as it was before the press.
    func primaryDragCancelled() {
        switch dragMode {
        case .move, .resize:
            if let start = dragStartFlow, start != flow { flow = start }
        case .box(_, let base, _):
            canvasSelection = base
        case .wire, nil:
            break
        }
        dragMode = nil
        dragPress = nil
        dragStartFlow = nil
        selectionBox = nil
        pendingWire = nil
    }

    /// A middle or secondary pan was dropped without a release.
    func panCancelled() {
        panStart = nil
        panPress = nil
    }

    /// The Studio went away (another screen, or another draft): ends whatever gesture or pane was open, commits the
    /// note being typed, so none of it is there when the Studio comes back.
    func leaveStudio() {
        commitNoteEdit()
        primaryDragCancelled()
        panCancelled()
        pinchStart = nil
        paletteDrag = nil
        nodeSearch = nil
    }

    /// Ends a node drag: one undo step from the flow at drag start, if anything moved.
    func finishMove() {
        defer { dragStartFlow = nil }
        guard let start = dragStartFlow, start != flow else { return }
        pushUndo(start)
        lastEditName = nil
    }

    /// Records the canvas size and fits the flow the first time it is known.
    func canvasSizeChanged(_ size: Size<Pixels>) {
        guard size.width.value > 0, size.height.value > 0 else { return }
        canvasSize = size
        if !hasFitted {
            hasFitted = true
            geometry = geometry.fit(flow, in: size)
        }
    }

    /// Fits the flow into the canvas.
    func fit() {
        if let canvasSize { geometry = geometry.fit(flow, in: canvasSize) }
    }

    /// Marks `saved` (the flow as written, which save-time normalisation may have changed) as saved at `location`.
    /// The draft shows what the file holds; its undo history is kept.
    func didSave(_ saved: Flow, at location: FlowLocation) {
        self.location = location
        if saved != flow { flow = saved }
        lastSavedFlow = saved
    }
}

/// What a primary drag on the canvas is doing.
enum DragMode {
    /// Moving the selected nodes and notes, and the nodes the selected frames carry, whose positions were `origins` and
    /// `notes` when the drag began.
    case move(origins: [NodeID: CanvasPoint], notes: [NoteID: CanvasPoint])
    /// Resizing a note by its handle; `origin` is its rectangle when the drag began.
    case resize(NoteID, origin: CanvasRect)
    /// Drawing a selection box from `start` (canvas-local screen points) over the selection `base`.
    case box(start: ScreenPoint, base: CanvasSelection, mode: SelectionMode)
    /// Dragging a new wire out of a node's out-port.
    case wire(NodeID)
}

/// What the palette adds: a node, or a note.
public enum PaletteEntry: Hashable, Sendable {
    /// A node of a kind.
    case node(PaletteKind)
    /// A note, which is not a node.
    case note

    /// The palette item's identifier suffix.
    public var idPrefix: String {
        switch self {
        case .node(let kind): kind.idPrefix
        case .note: "note"
        }
    }

    /// The palette label.
    public var label: String {
        switch self {
        case .node(let kind): kind.label
        case .note: "Note"
        }
    }

    /// The palette groups, in order: the node groups, then NOTES.
    public static let groups: [(title: String, items: [PaletteEntry])] =
        PaletteKind.groups.map { ($0.title, $0.items.map(PaletteEntry.node)) } + [("NOTES", [.note])]
}

/// The node kinds the palette adds.
public enum PaletteKind: CaseIterable, Sendable {
    /// A flow input.
    case flowInput
    /// The run's repository.
    case repo
    /// A prompt step.
    case prompt
    /// A shell step.
    case shell
    /// A gate check.
    case gate
    /// A judge.
    case judge
    /// A human pick.
    case pick
    /// Pushes the picked branch and opens a pull request.
    case openPR
    /// An agent that reviews each candidate's diff.
    case review

    /// The prefix of generated ids, also the palette item's identifier suffix.
    public var idPrefix: String {
        switch self {
        case .flowInput: "input"
        case .repo: "repo"
        case .prompt: "prompt"
        case .shell: "shell"
        case .gate: "gate"
        case .judge: "judge"
        case .pick: "pick"
        case .openPR: "openpr"
        case .review: "review"
        }
    }

    /// The palette label, also the new node's title.
    public var label: String {
        switch self {
        case .flowInput: "Flow input"
        case .repo: "Repo"
        case .prompt: "Prompt"
        case .shell: "Shell"
        case .gate: "Gate"
        case .judge: "Judge"
        case .pick: "You pick"
        case .openPR: "Open PR"
        case .review: "Review"
        }
    }

    /// A new node's configuration.
    var defaultKind: NodeKind {
        let prompt = PromptConfig(model: "sonnet", prompt: "", candidates: [], allowedTools: [], maxTurns: nil)
        switch self {
        case .flowInput: return .flowInput(FlowInputConfig(name: "issue", source: .githubIssue))
        case .repo: return .repo(RepoConfig(mode: .exposed(default: nil)))
        case .prompt: return .prompt(prompt)
        case .shell: return .shell(ShellConfig(command: ""))
        case .gate: return .gate(ShellConfig(command: ""))
        case .judge: return .judge(prompt)
        case .pick: return .pick
        case .openPR: return .openPR(OpenPRConfig())
        case .review: return .review(ReviewConfig())
        }
    }

    /// The palette groups, in order.
    public static let groups: [(title: String, items: [PaletteKind])] = [
        ("INPUTS", [.flowInput, .repo]),
        ("STEPS", [.prompt, .shell]),
        ("CHECKS", [.gate, .review]),
        ("DECIDE", [.judge, .pick, .openPR]),
    ]
}

extension PromptConfig {
    /// The most candidates a node can fan out to.
    static let maxCandidates = 6

    /// The stepper's value: `max(1, candidates.count)`.
    var candidateCount: Int { max(1, candidates.count) }

    /// Sets the stepper value, clamped to 1...6. 1 means a single run with `model` (no candidates); more resizes the
    /// list, new slots copying `model`.
    mutating func setCandidateCount(_ n: Int) {
        let n = min(max(n, 1), Self.maxCandidates)
        if n == 1 { candidates = []; return }
        if candidates.count > n { candidates.removeLast(candidates.count - n) }
        while candidates.count < n { candidates.append(model) }
    }
}
