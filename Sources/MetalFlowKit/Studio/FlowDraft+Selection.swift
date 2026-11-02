import MetalFlowCore
import MetalUI

extension FlowDraft {
    /// Selects the node under a canvas-local screen point as `modifiers` say (plain replaces, ⇧ adds, ⌘ toggles),
    /// else the wire near it (always replacing), else clears the selection unless ⇧ or ⌘ is held.
    func select(at location: ScreenPoint, modifiers: EventModifiers) {
        lastEditName = nil  // a click on the canvas moves focus off any inspector field
        let mode = SelectionMode(modifiers)
        if let id = geometry.hitNode(at: geometry.toCanvas(location), in: flow) {
            canvasSelection = canvasSelection.applying([id], mode: mode)
        } else if let wire = geometry.hitWire(at: location, in: flow) {
            canvasSelection = CanvasSelection(wire: wire)
        } else if mode == .replace {
            canvasSelection = CanvasSelection()
        }
    }

    /// Selects every node.
    func selectAll() {
        canvasSelection = CanvasSelection(nodes: Set(flow.nodes.map(\.id)))
    }

    /// Selects nothing.
    func clearSelection() {
        canvasSelection = CanvasSelection()
    }

    /// Starts moving: selects the node at the press as `mode` says unless it is selected already, and returns
    /// the positions of everything selected.
    func beginMove(of id: NodeID, mode: SelectionMode) -> [NodeID: CanvasPoint] {
        if !canvasSelection.nodes.contains(id) {
            canvasSelection = canvasSelection.applying([id], mode: mode == .replace ? .replace : .add)
        }
        return Dictionary(uniqueKeysWithValues: canvasSelection.nodes.compactMap { id in
            flow.node(id).map { (id, $0.position) }
        })
    }

    /// Grows the box to `location` and selects what it overlaps, combined with what was selected at its start.
    func updateBox(to location: ScreenPoint, start: ScreenPoint, base: CanvasSelection, mode: SelectionMode) {
        let x0 = min(start.x.value, location.x.value), y0 = min(start.y.value, location.y.value)
        let x1 = max(start.x.value, location.x.value), y1 = max(start.y.value, location.y.value)
        selectionBox = CanvasRect(x: Double(x0), y: Double(y0), w: Double(x1 - x0), h: Double(y1 - y0))
        let a = geometry.toCanvas(ScreenPoint(x: Pixels(x0), y: Pixels(y0)))
        let b = geometry.toCanvas(ScreenPoint(x: Pixels(x1), y: Pixels(y1)))
        let hit = geometry.nodes(in: CanvasRect(x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y), flow: flow)
        canvasSelection = base.applying(Set(hit), mode: mode)
    }
}
