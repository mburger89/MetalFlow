import MetalFlowCore
import MetalUI

/// A palette row being dragged: what it adds and where the pointer is, in window points.
struct PaletteDrag: Equatable {
    var kind: PaletteKind
    var windowPoint: ScreenPoint
}

/// The Tab search pane: what was typed, which match is highlighted, where the pane sits (window points) and where
/// the node it adds lands (canvas-local points).
struct NodeSearch: Equatable {
    var query: String
    var highlighted: Int
    var windowPoint: ScreenPoint
    var dropPoint: ScreenPoint
}

extension FlowDraft {
    /// How far, in points, a palette press must move before it is a drag rather than a click.
    static let paletteDragThreshold: Float = 4
    /// The most matches the search pane shows at once.
    static let nodeSearchRows = 6

    /// Adds a node of `kind` centred on the canvas centre (the canvas origin before it is measured) and selects it.
    @discardableResult
    public func addNode(_ kind: PaletteKind) -> NodeID {
        guard let canvasSize else { return insert(kind, at: CanvasPoint(x: 0, y: 0)) }
        return addNode(kind, centredAt: ScreenPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }

    /// Adds a node of `kind` centred on a canvas-local screen point, as one undo step, and selects it.
    @discardableResult
    func addNode(_ kind: PaletteKind, centredAt point: ScreenPoint) -> NodeID {
        let centre = geometry.toCanvas(point)
        let size = geometry.nodeRect(Node(id: "size", title: "", kind: kind.defaultKind, position: centre))
        return insert(kind, at: CanvasPoint(x: (centre.x - size.w / 2).rounded(), y: (centre.y - size.h / 2).rounded()))
    }

    private func insert(_ kind: PaletteKind, at position: CanvasPoint) -> NodeID {
        let id = uniqueID(prefix: kind.idPrefix)
        let node = Node(id: id, title: kind.label, kind: kind.defaultKind, position: position)
        apply("add \(id.rawValue)", coalescing: false) { $0.nodes.append(node) }
        selection = id
        return id
    }

    // MARK: Dragging from the palette

    /// The pointer moved while pressing a palette row (`start` and `point` in window points). Once it is past the
    /// click threshold the row is being dragged, and stays a drag until the press ends, even if the pointer returns.
    func movePaletteDrag(_ kind: PaletteKind, from start: ScreenPoint, to point: ScreenPoint) {
        guard paletteDrag?.kind == kind || Self.distance(start, point) >= Self.paletteDragThreshold else { return }
        paletteDrag = PaletteDrag(kind: kind, windowPoint: point)
    }

    /// The press on a palette row ended at `point` (window points). A press that never left the threshold is a click
    /// and adds at the canvas centre; a drag adds centred on the drop when it lands on the canvas, and nothing
    /// elsewhere. Returns the new node.
    @discardableResult
    func endPaletteDrag(_ kind: PaletteKind, from start: ScreenPoint, at point: ScreenPoint) -> NodeID? {
        let dragged = paletteDrag?.kind == kind || Self.distance(start, point) >= Self.paletteDragThreshold
        paletteDrag = nil
        guard dragged else { return addNode(kind) }
        guard let frame = canvasFrame, frame.contains(point) else { return nil }
        return addNode(kind, centredAt: ScreenPoint(x: point.x - frame.origin.x, y: point.y - frame.origin.y))
    }

    /// The press on a palette row was dropped without a release: nothing is added, not even as a click.
    func cancelPaletteDrag() {
        paletteDrag = nil
    }

    private static func distance(_ a: ScreenPoint, _ b: ScreenPoint) -> Float {
        let dx = a.x.value - b.x.value, dy = a.y.value - b.y.value
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: The pointer

    /// The pointer over the canvas in canvas-local points; nil while it is elsewhere.
    var pointer: ScreenPoint? {
        guard let pointerInWindow, let frame = canvasFrame else { return nil }
        return ScreenPoint(x: pointerInWindow.x - frame.origin.x, y: pointerInWindow.y - frame.origin.y)
    }

    // MARK: The Tab search pane

    /// The palette kinds whose label contains the query, ignoring case, in palette order.
    var nodeSearchMatches: [PaletteKind] {
        let needle = (nodeSearch?.query ?? "").lowercased()
        let all = PaletteKind.groups.flatMap(\.items)
        return needle.isEmpty ? all : all.filter { $0.label.lowercased().contains(needle) }
    }

    /// Opens the pane at the pointer, or at the canvas centre when the pointer is elsewhere. A node it adds lands
    /// centred on that point.
    func openNodeSearch() {
        let size = canvasFrame?.size ?? canvasSize ?? Size(width: Pixels(0), height: Pixels(0))
        let origin = canvasFrame?.origin ?? ScreenPoint(x: Pixels(0), y: Pixels(0))
        let drop = pointer ?? ScreenPoint(x: size.width / 2, y: size.height / 2)
        nodeSearch = NodeSearch(query: "", highlighted: 0,
                                windowPoint: pointerInWindow ?? ScreenPoint(x: origin.x + drop.x, y: origin.y + drop.y),
                                dropPoint: drop)
    }

    /// Filters by `query` and highlights the first match.
    func setNodeSearchQuery(_ query: String) {
        guard nodeSearch != nil else { return }
        nodeSearch?.query = query
        nodeSearch?.highlighted = 0
    }

    /// Moves the highlight, stopping at the first and last match.
    func moveNodeSearch(by delta: Int) {
        guard let search = nodeSearch else { return }
        let highlighted = max(0, min(search.highlighted + delta, nodeSearchMatches.count - 1))
        nodeSearch?.highlighted = highlighted
    }

    /// Adds `kind`, or the highlighted match, at the point the pane opened and closes it. With nothing to add the
    /// pane stays open. Returns the new node.
    @discardableResult
    func confirmNodeSearch(_ kind: PaletteKind? = nil) -> NodeID? {
        guard let search = nodeSearch else { return nil }
        let matches = nodeSearchMatches
        guard let kind = kind ?? (matches.indices.contains(search.highlighted) ? matches[search.highlighted] : nil) else {
            return nil
        }
        nodeSearch = nil
        return addNode(kind, centredAt: search.dropPoint)
    }

    /// Closes the pane, adding nothing.
    func closeNodeSearch() {
        nodeSearch = nil
    }
}
