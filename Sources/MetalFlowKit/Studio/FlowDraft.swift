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
    public var isDirty: Bool { flow != lastSavedFlow }
    /// The plan, or why the flow cannot run. Recomputed on every change.
    public private(set) var validation: Result<FlowPlan, FlowError>
    /// Earlier states of the flow, oldest first.
    public private(set) var undoStack: [Flow] = []
    /// States undone, most recently undone last.
    public private(set) var redoStack: [Flow] = []
    /// What is selected. View state: never undone. Selecting different nodes ends a typing burst.
    var canvasSelection = CanvasSelection() {
        didSet { if canvasSelection.nodes != oldValue.nodes { lastEditName = nil } }
    }
    /// The selected node: the one node when exactly one node and nothing else is selected, else nil. Setting
    /// replaces the selection with that node (nil clears the nodes).
    public var selection: NodeID? {
        get { canvasSelection.wire == nil && canvasSelection.nodes.count == 1 ? canvasSelection.nodes.first : nil }
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
    @ObservationIgnored private var hasFitted = false
    @ObservationIgnored var panStart: ScreenPoint?
    /// What the current primary drag is doing.
    @ObservationIgnored var dragMode: DragMode?
    /// The flow when a node drag began; its undo step's before-state.
    @ObservationIgnored var dragStartFlow: Flow?
    /// The name of the last edit, while it can still absorb more of the same typing burst.
    @ObservationIgnored var lastEditName: String?
    /// The allowed-tools text being typed, as long as it still parses to the node's tools.
    var toolsBuffer: (node: NodeID, text: String)?
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

    /// Steps back one edit.
    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(flow)
        flow = previous
        lastEditName = nil
        dropStaleSelection()
    }

    /// Re-applies the last undone edit.
    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(flow)
        flow = next
        lastEditName = nil
        dropStaleSelection()
    }

    private func dropStaleSelection() {
        let nodes = canvasSelection.nodes.filter { flow.node($0) != nil }
        if nodes != canvasSelection.nodes { canvasSelection.nodes = nodes }
        if let selectedWire, !flow.wires.contains(selectedWire) { self.selectedWire = nil }
    }

    // MARK: Structural edits

    /// The id `<prefix><n>` with the smallest positive `n` no node uses.
    func uniqueID(prefix: String) -> NodeID {
        var n = 1
        while flow.node(NodeID(rawValue: "\(prefix)\(n)")) != nil { n += 1 }
        return NodeID(rawValue: "\(prefix)\(n)")
    }

    /// Adds a node of `kind` centred on the canvas centre (the canvas origin before it is measured) and selects it.
    @discardableResult
    public func addNode(_ kind: PaletteKind) -> NodeID {
        let id = uniqueID(prefix: kind.idPrefix)
        var node = Node(id: id, title: kind.label, kind: kind.defaultKind, position: CanvasPoint(x: 0, y: 0))
        if let canvasSize {
            let centre = geometry.toCanvas(ScreenPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
            let rect = geometry.nodeRect(node)
            node.position = CanvasPoint(x: (centre.x - rect.w / 2).rounded(), y: (centre.y - rect.h / 2).rounded())
        }
        apply("add \(id.rawValue)", coalescing: false) { $0.nodes.append(node) }
        selection = id
        return id
    }

    /// Removes a node and every wire touching it, as one undo step.
    public func deleteNode(_ id: NodeID) {
        removeNodes([id], name: "delete \(id.rawValue)")
    }

    /// Removes `ids` with every wire touching them as one undo step named `name`, and drops them from the selection.
    private func removeNodes(_ ids: Set<NodeID>, name: String) {
        apply(name, coalescing: false) { flow in
            flow.nodes.removeAll { ids.contains($0.id) }
            flow.wires.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        }
        canvasSelection.nodes.subtract(ids)
    }

    /// Removes the selected nodes with their wires as one undo step, or the selected wire.
    public func deleteSelection() {
        let ids = canvasSelection.nodes
        if ids.count == 1, let id = ids.first {
            deleteNode(id)
        } else if !ids.isEmpty {
            removeNodes(ids, name: "delete \(ids.count) nodes")
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

    /// Moves the nodes in `origins` by `delta` canvas units, without an undo step.
    func moveLive(_ origins: [NodeID: CanvasPoint], by delta: CanvasPoint) {
        var updated = flow
        for i in updated.nodes.indices {
            if let origin = origins[updated.nodes[i].id] {
                updated.nodes[i].position = CanvasPoint(x: origin.x + delta.x, y: origin.y + delta.y)
            }
        }
        flow = updated
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
    /// Moving the selected nodes, whose positions were `origins` when the drag began.
    case move(origins: [NodeID: CanvasPoint])
    /// Drawing a selection box from `start` (canvas-local screen points) over the selection `base`.
    case box(start: ScreenPoint, base: CanvasSelection, mode: SelectionMode)
    /// Dragging a new wire out of a node's out-port.
    case wire(NodeID)
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
