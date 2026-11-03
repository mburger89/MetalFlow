import MetalFlowCore
import MetalUI

/// A palette row being dragged: what it adds and where the pointer is, in window points.
struct PaletteDrag: Equatable {
    var entry: PaletteEntry
    var windowPoint: ScreenPoint
}

/// What a palette row, a drop or the search pane added.
enum AddedItem: Equatable {
    case node(NodeID)
    case note(NoteID)
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

    /// Adds `entry` at the canvas centre: a node, or a note (a frame if nodes are selected).
    @discardableResult
    func add(_ entry: PaletteEntry) -> AddedItem {
        switch entry {
        case .node(let kind): .node(addNode(kind))
        case .note: .note(addNote())
        }
    }

    /// Adds `entry` centred on a canvas-local screen point.
    @discardableResult
    func add(_ entry: PaletteEntry, centredAt point: ScreenPoint) -> AddedItem {
        switch entry {
        case .node(let kind): .node(addNode(kind, centredAt: point))
        case .note: .note(addNote(at: point))
        }
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
    func movePaletteDrag(_ entry: PaletteEntry, from start: ScreenPoint, to point: ScreenPoint) {
        guard paletteDrag?.entry == entry || Self.distance(start, point) >= Self.paletteDragThreshold else { return }
        paletteDrag = PaletteDrag(entry: entry, windowPoint: point)
    }

    /// The press on a palette row ended at `point` (window points). A press that never left the threshold is a click
    /// and adds at the canvas centre; a drag adds centred on the drop when it lands on the canvas, and nothing
    /// elsewhere. Returns what was added.
    @discardableResult
    func endPaletteDrag(_ entry: PaletteEntry, from start: ScreenPoint, at point: ScreenPoint) -> AddedItem? {
        let dragged = paletteDrag?.entry == entry || Self.distance(start, point) >= Self.paletteDragThreshold
        paletteDrag = nil
        guard dragged else { return addFromPalette(entry) }
        guard let frame = canvasFrame, frame.contains(point) else { return nil }
        paletteFilter = ""
        return add(entry, centredAt: ScreenPoint(x: point.x - frame.origin.x, y: point.y - frame.origin.y))
    }

    /// Adds `entry` at the canvas centre for a click on its palette row, and clears the Find filter like Return does.
    @discardableResult
    func addFromPalette(_ entry: PaletteEntry) -> AddedItem {
        paletteFilter = ""
        return add(entry)
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

    /// The palette entries whose label contains the query, ignoring case, in palette order.
    var nodeSearchMatches: [PaletteEntry] {
        let query = nodeSearch?.query ?? ""
        return PaletteEntry.groups.flatMap(\.items).filter { $0.matches(query) }
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

    /// Adds `entry`, or the highlighted match, at the point the pane opened and closes it. With nothing to add the
    /// pane stays open. Returns what was added.
    @discardableResult
    func confirmNodeSearch(_ entry: PaletteEntry? = nil) -> AddedItem? {
        guard let search = nodeSearch else { return nil }
        let matches = nodeSearchMatches
        guard let entry = entry ?? (matches.indices.contains(search.highlighted) ? matches[search.highlighted] : nil) else {
            return nil
        }
        nodeSearch = nil
        return add(entry, centredAt: search.dropPoint)
    }

    /// Closes the pane, adding nothing.
    func closeNodeSearch() {
        nodeSearch = nil
    }
}

// MARK: The palette's Find field and the zoom buttons

extension FlowDraft {
    /// How much one press of a zoom button scales the view.
    static let zoomStep = 1.25

    /// The palette groups with only the entries matching `paletteFilter`, groups with none left out.
    var visiblePaletteGroups: [(title: String, items: [PaletteEntry])] {
        PaletteEntry.groups.compactMap { group in
            let items = group.items.filter { $0.matches(paletteFilter) }
            return items.isEmpty ? nil : (group.title, items)
        }
    }

    /// Return in the Find field: adds the first match at the canvas centre, selects it and clears the filter. With nothing
    /// typed, or no match, nothing happens. Returns whether a node was added.
    @discardableResult
    func addFirstPaletteMatch() -> Bool {
        guard !paletteFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = visiblePaletteGroups.first?.items.first else { return false }
        add(first)
        paletteFilter = ""
        return true
    }

    /// Scales the view by `factor` about the canvas centre; nothing until the canvas is measured.
    func zoomCanvas(by factor: Double) {
        guard let canvasSize else { return }
        geometry.zoom(to: geometry.zoom * factor, about: ScreenPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
    }
}
