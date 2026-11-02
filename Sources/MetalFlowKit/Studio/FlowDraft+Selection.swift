import MetalFlowCore
import MetalUI

/// What a press on the canvas lands on, ports aside.
enum CanvasHit: Equatable {
    case node(NodeID)
    case note(NoteID, NotePart)
}

extension FlowDraft {
    /// What is under a canvas point: the handle of a selected note, then a node, then a sticky or a frame's chrome.
    func hit(at canvas: CanvasPoint) -> CanvasHit? {
        let note = geometry.hitNote(at: canvas, in: flow, selected: canvasSelection.notes)
        if let note, note.1 == .handle { return .note(note.0, note.1) }
        if let id = geometry.hitNode(at: canvas, in: flow) { return .node(id) }
        return note.map { .note($0.0, $0.1) }
    }

    /// Selects the node or note under a canvas-local screen point as `modifiers` say (plain replaces, ⇧ adds, ⌘
    /// toggles), else the wire near it (always replacing), else clears the selection unless ⇧ or ⌘ is held. A plain
    /// double click on a note edits it.
    func select(at location: ScreenPoint, modifiers: EventModifiers, clickCount: Int = 1) {
        lastEditName = nil  // a click on the canvas moves focus off any inspector field
        let mode = SelectionMode(modifiers)
        switch hit(at: geometry.toCanvas(location)) {
        case .node(let id):
            canvasSelection = canvasSelection.applying([id], mode: mode)
        case .note(let id, _):
            canvasSelection = canvasSelection.applying([], notes: [id], mode: mode)
            if clickCount >= 2, mode == .replace { beginEditingNote(id) }
        case nil:
            if let wire = geometry.hitWire(at: location, in: flow) {
                canvasSelection = CanvasSelection(wire: wire)
            } else if mode == .replace {
                canvasSelection = CanvasSelection()
            }
        }
    }

    /// Selects every node and note.
    func selectAll() {
        canvasSelection = CanvasSelection(nodes: Set(flow.nodes.map(\.id)), notes: Set(flow.notes.map(\.id)))
    }

    /// Selects nothing.
    func clearSelection() {
        canvasSelection = CanvasSelection()
    }

    /// Starts moving: selects what was pressed as `mode` says unless it is selected already, and returns the positions
    /// of everything selected, with the nodes whose centres lie in a selected frame, which it carries.
    func beginMove(of hit: CanvasHit, mode: SelectionMode) -> (nodes: [NodeID: CanvasPoint], notes: [NoteID: CanvasPoint]) {
        let pressed: (nodes: Set<NodeID>, notes: Set<NoteID>)
        switch hit {
        case .node(let id): pressed = ([id], [])
        case .note(let id, _): pressed = ([], [id])
        }
        if !canvasSelection.nodes.isSuperset(of: pressed.nodes) || !canvasSelection.notes.isSuperset(of: pressed.notes) {
            canvasSelection = canvasSelection.applying(pressed.nodes, notes: pressed.notes, mode: mode == .replace ? .replace : .add)
        }
        var nodes = Dictionary(uniqueKeysWithValues: canvasSelection.nodes.compactMap { id in
            flow.node(id).map { (id, $0.position) }
        })
        var notes: [NoteID: CanvasPoint] = [:]
        for note in flow.notes where canvasSelection.notes.contains(note.id) {
            notes[note.id] = note.origin
            for member in members(of: note) { nodes[member] = flow.node(member)?.position }
        }
        return (nodes, notes)
    }

    /// Grows the box to `location` and selects what it overlaps, combined with what was selected at its start.
    func updateBox(to location: ScreenPoint, start: ScreenPoint, base: CanvasSelection, mode: SelectionMode) {
        let x0 = min(start.x.value, location.x.value), y0 = min(start.y.value, location.y.value)
        let x1 = max(start.x.value, location.x.value), y1 = max(start.y.value, location.y.value)
        selectionBox = CanvasRect(x: Double(x0), y: Double(y0), w: Double(x1 - x0), h: Double(y1 - y0))
        let a = geometry.toCanvas(ScreenPoint(x: Pixels(x0), y: Pixels(y0)))
        let b = geometry.toCanvas(ScreenPoint(x: Pixels(x1), y: Pixels(y1)))
        let box = CanvasRect(x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y)
        canvasSelection = base.applying(Set(geometry.nodes(in: box, flow: flow)),
                                        notes: Set(geometry.notes(in: box, flow: flow)), mode: mode)
    }
}
