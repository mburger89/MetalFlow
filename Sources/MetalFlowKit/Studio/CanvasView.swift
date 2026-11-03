import Foundation
import MetalFlowCore
import MetalUI

/// The layers of the canvas surface, bottom to top. Frames lie under the wires and stickies over them, both under the
/// nodes; `CanvasSurface` draws them in this order.
enum CanvasLayer: Hashable {
    case grid, frames, wires, stickies, nodes, ports, box

    /// Bottom to top.
    static let drawOrder: [CanvasLayer] = [.grid, .frames, .wires, .stickies, .nodes, .ports, .box]
}

/// The graph and the field of the note being typed into. The field is a sibling of the surface, never inside it: the
/// surface is a key region, and a field inside it would pass its keys to the canvas's own handler.
struct CanvasView: Component {
    let model: AppModel
    let draft: FlowDraft

    var content: some ElementGroup {
        ZStack(alignment: .topLeading) {
            CanvasSurface(model: model, draft: draft)
            NoteEditorLayer(draft: draft)
        }
    }
}

/// The graph: dotted grid, notes, wires and node cards under a pan and zoom, with the Fit button and zoom readout.
/// Pan with the wheel or a middle / secondary drag, zoom with ⌘-wheel or a pinch, click to select (⇧ adds, ⌘ toggles),
/// drag on empty canvas to draw a selection box, double-click a note to edit it.
struct CanvasSurface: Component {
    let model: AppModel
    let draft: FlowDraft

    var content: some ElementGroup {
        let g = draft.geometry
        let size = draft.canvasSize ?? Size(width: Pixels(0), height: Pixels(0))
        let run = model.studioShownRun
        let scoped = run.map(NodeOverlay.laneScoped) ?? []
        let draft = draft
        ZStack(alignment: .topLeading) {
            CanvasLayers(draft: draft, run: run, laneScoped: scoped, size: size)
        }
        // minWidth / minHeight 0: the layers are as big as the canvas was last, and must not stop it shrinking
        // (the candidates strip appearing takes space from it).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(Hsla.rgb(0x101215)))
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas")
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: Spacing.xs) {
                Button("\u{2212}") { draft.zoomCanvasOut() }
                    .buttonStyle(.bordered)
                    .disabled(g.zoom <= CanvasGeometry.minZoom)
                    .accessibilityIdentifier("canvas.zoomOut")
                Text(verbatim: "\(Int((g.zoom * 100).rounded()))%").font(size: 12).foregroundColor(Palette.body)
                    .accessibilityIdentifier("canvas.zoom")
                Button("+") { draft.zoomCanvasIn() }
                    .buttonStyle(.bordered)
                    .disabled(g.zoom >= CanvasGeometry.maxZoom)
                    .accessibilityIdentifier("canvas.zoomIn")
                Button("Fit") { draft.fit() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("canvas.fit")
            }
            .padding(Edges(all: Spacing.xs))
            .background(Color(Hsla.rgb(0x171a1f)))
            .cornerRadius(8)
            .padding(Edges(all: Spacing.md))
        }
        .coordinateSpace(.named("canvas"))
        .onGeometryChange(for: Size<Pixels>.self, of: { $0.size }) { draft.canvasSizeChanged($0) }
        .onGeometryChange(for: Bounds<Pixels>.self, of: { $0.frame(in: .global) }) { draft.canvasFrame = $0 }
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let point): draft.pointerInWindow = point
            case .ended: draft.pointerInWindow = nil
            }
        }
        .onScrollWheel { Self.scroll($0, draft) }
        .gesture(SpatialTapGesture().onEnded { (tap: SpatialTapGesture.Value) in
            draft.select(at: tap.location, modifiers: tap.modifiers, clickCount: tap.clickCount)
        })
        .gesture(MagnifyGesture()
            .onChanged { draft.pinchChanged($0) }
            .onEnded { draft.pinchEnded($0) })
        .focusable(true, interactions: .edit)
        .hoverKeyRegion()
        .onKeyPress { Self.key($0, draft) }
        .gesture(DragGesture(minimumDistance: Pixels(3))
            .onChanged { draft.primaryDragChanged($0) }
            .onEnded { draft.primaryDragEnded($0) }
            .onCancelled { draft.primaryDragCancelled() })
        .gesture(DragGesture(button: .middle)
            .onChanged { draft.panChanged($0) }
            .onEnded { _ in draft.panCancelled() }
            .onCancelled { draft.panCancelled() })
        .gesture(DragGesture(button: .secondary)
            .onChanged { draft.panChanged($0) }
            .onEnded { _ in draft.panCancelled() }
            .onCancelled { draft.panCancelled() })
    }

    /// Delete and Backspace remove the selection; ⌘A selects every node and note, Esc clears the selection; ⌘Z undoes,
    /// ⇧⌘Z redoes; Tab opens the node search; N adds a note at the pointer. Only reached while the canvas has focus or
    /// the pointer is over it with nothing focused, so typing in an inspector field never lands here.
    @MainActor
    static func key(_ press: KeyPress, _ draft: FlowDraft) -> KeyPress.Result {
        // A drag under way owns the canvas: a key that changes the flow would push a step the drag then repeats.
        if draft.isGestureActive {
            let mutating = press.key == .delete || press.key == .deleteForward || press.key == .tab
                || press.key == .escape || ["n", "a", "z"].contains(press.key.character.lowercased())
            return mutating ? .handled : .ignored
        }
        if press.key == .delete || press.key == .deleteForward {
            guard !draft.canvasSelection.isEmpty else { return .ignored }
            draft.deleteSelection()
            return .handled
        }
        if press.key == .tab, press.modifiers.isEmpty {
            draft.openNodeSearch()
            return .handled
        }
        if press.key.character.lowercased() == "n", press.modifiers.isEmpty {
            draft.addNote(at: draft.pointer)
            return .handled
        }
        if press.key == .escape {
            guard !draft.canvasSelection.isEmpty else { return .ignored }
            draft.clearSelection()
            return .handled
        }
        if press.key.character.lowercased() == "a", press.modifiers.contains(.command) {
            draft.selectAll()
            return .handled
        }
        if press.key.character.lowercased() == "z", press.modifiers.contains(.command) {
            if press.modifiers.contains(.shift) { draft.redo() } else { draft.undo() }
            return .handled
        }
        return .ignored
    }

    /// ⌘ or ⌃ zooms by `2^(Δy/100)` about the pointer; anything else pans.
    @MainActor
    static func scroll(_ event: ScrollEvent, _ draft: FlowDraft) -> Bool {
        if event.modifiers.contains(.command) || event.modifiers.contains(.control) {
            draft.geometry.zoom(to: draft.geometry.zoom * pow(2, Double(event.delta.y.value) / 100), about: event.location)
        } else {
            let pan = draft.geometry.pan
            draft.geometry.pan = ScreenPoint(x: pan.x + event.delta.x, y: pan.y + event.delta.y)
        }
        return true
    }
}

extension FlowDraft {
    /// A primary drag: on an out-port it draws a wire, on a node or a note it moves the selection (selecting what was
    /// pressed first unless it is selected), on the handle of a selected note it resizes the note, on empty canvas it
    /// draws a selection box.
    func primaryDragChanged(_ value: DragGesture.Value) {
        // A press somewhere else than the drag in hand began: that drag was dropped without being cancelled.
        if dragMode != nil, dragPress != value.startLocation { primaryDragCancelled() }
        if dragMode == nil {
            dragPress = value.startLocation
            let start = geometry.toCanvas(value.startLocation)
            let mode = SelectionMode(value.modifiers)
            if let (id, side) = geometry.hitPort(at: start, in: flow), side == .output {
                dragMode = .wire(id)
            } else if let hit = hit(at: start) {
                dragStartFlow = flow
                if case .note(let id, .handle) = hit, let note = flow.notes.first(where: { $0.id == id }) {
                    dragMode = .resize(id, origin: geometry.noteRect(note))
                } else {
                    let origins = beginMove(of: hit, mode: mode)
                    dragMode = .move(origins: origins.nodes, notes: origins.notes)
                }
            } else {
                let base = mode == .replace ? CanvasSelection()
                    : CanvasSelection(nodes: canvasSelection.nodes, notes: canvasSelection.notes)
                dragMode = .box(start: value.startLocation, base: base, mode: mode)
            }
        }
        switch dragMode {
        case .move(let origins, let notes):
            let z = geometry.zoom
            moveLive(origins, notes: notes, by: CanvasPoint(x: Double(value.translation.width.value) / z,
                                                            y: Double(value.translation.height.value) / z))
        case .resize(let id, let origin):
            let z = geometry.zoom
            resizeLive(id, from: origin, by: CanvasPoint(x: Double(value.translation.width.value) / z,
                                                         y: Double(value.translation.height.value) / z))
        case .wire(let id):
            pendingWire = (id, value.location)
        case .box(let start, let base, let mode):
            updateBox(to: value.location, start: start, base: base, mode: mode)
        case nil:
            break
        }
    }

    func primaryDragEnded(_ value: DragGesture.Value) {
        switch dragMode {
        case .move, .resize:
            finishMove()
        case .wire(let from):
            pendingWire = nil
            if let (to, side) = geometry.hitPort(at: geometry.toCanvas(value.location), in: flow), side == .input {
                connect(from: from, to: to, allowParallel: false)
            }
        case .box:
            selectionBox = nil
        case nil:
            break
        }
        dragMode = nil
        dragPress = nil
    }

    func panChanged(_ value: DragGesture.Value) {
        if panStart != nil, panPress != value.startLocation { panCancelled() }
        if panStart == nil {
            panStart = geometry.pan
            panPress = value.startLocation
        }
        let start = panStart ?? geometry.pan
        geometry.pan = ScreenPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
    }

    func pinchChanged(_ value: MagnifyGesture.Value) {
        if pinchStart == nil { pinchStart = (geometry.pan, geometry.zoom) }
        guard let start = pinchStart else { return }
        geometry.pan = start.pan
        geometry.zoom = start.zoom
        geometry.zoom(to: start.zoom * value.magnification, about: value.startLocation)
    }

    func pinchEnded(_ value: MagnifyGesture.Value) {
        pinchChanged(value)
        pinchStart = nil
    }
}

/// The grid, notes, wires, cards, ports and selection box, in `CanvasLayer.drawOrder`.
struct CanvasLayers: Component {
    let draft: FlowDraft
    let run: Run?
    let laneScoped: Set<NodeID>
    let size: Size<Pixels>

    var content: some ElementGroup {
        let g = draft.geometry
        let draft = draft
        let run = run, scoped = laneScoped
        ZStack(alignment: .topLeading) {
            ForEach(CanvasLayer.drawOrder, id: \.self) { layer in
                switch layer {
                case .grid:
                    DotGrid(geometry: g, size: size)
                case .frames:
                    NoteLayer(draft: draft, frames: true)
                case .wires:
                    WireLayer(flow: draft.flow, geometry: g, selection: draft.canvasSelection.nodes,
                              selectedWire: draft.selectedWire, pending: draft.pendingWire, size: size)
                case .stickies:
                    NoteLayer(draft: draft, frames: false)
                case .nodes:
                    NodeLayer(draft: draft, run: run, laneScoped: scoped)
                case .ports:
                    PortLayer(flow: draft.flow, geometry: g, size: size)
                case .box:
                    if let box = draft.selectionBox {
                        SelectionBoxView(rect: box)
                    }
                }
            }
        }
    }
}

/// The node cards. They sit at canvas * zoom, so a pan is the one offset and no card is rebuilt for it.
struct NodeLayer: Component {
    let draft: FlowDraft
    let run: Run?
    let laneScoped: Set<NodeID>

    var content: some ElementGroup {
        let g = draft.geometry
        let selection = draft.canvasSelection.nodes
        ZStack(alignment: .topLeading) {
            ForEach(draft.flow.nodes, id: \.id) { node in
                NodeCardView(
                    node: node, zoom: g.zoom, selected: selection.contains(node.id),
                    overlay: run.map { NodeOverlay.make(node: node, run: $0, laneScoped: laneScoped.contains(node.id)) })
                    .equatable()
            }
        }
        .offset(x: g.pan.x, y: g.pan.y)
    }
}

/// The frames, or the stickies, of the flow, placed like the node cards.
struct NoteLayer: Component {
    let draft: FlowDraft
    let frames: Bool

    var content: some ElementGroup {
        let g = draft.geometry
        let notes = draft.flow.notes.filter { $0.surrounds == frames }
        let selection = draft.canvasSelection.notes
        let editing = draft.editingNote
        ZStack(alignment: .topLeading) {
            ForEach(notes, id: \.id.rawValue) { note in
                if frames {
                    FrameView(note: note, zoom: g.zoom, selected: selection.contains(note.id), editing: editing == note.id)
                        .equatable()
                } else {
                    StickyView(note: note, zoom: g.zoom, selected: selection.contains(note.id), editing: editing == note.id)
                        .equatable()
                }
            }
        }
        .offset(x: g.pan.x, y: g.pan.y)
    }
}

/// The dotted grid: one `Path` of the dots that are on screen. Spacing is 20 × zoom, doubled until at least 12 points.
struct DotGrid: Component {
    let geometry: CanvasGeometry
    let size: Size<Pixels>

    var content: some ElementGroup {
        Self.path(geometry: geometry, size: size).fill(Color(Hsla.rgb(0x2a2f37)))
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
    }

    /// The grid spacing in points.
    static func spacing(zoom: Double) -> Double {
        var s = 20 * zoom
        while s < 12 { s *= 2 }
        return s
    }

    /// The dots inside `size`.
    static func path(geometry g: CanvasGeometry, size: Size<Pixels>) -> Path {
        let s = spacing(zoom: g.zoom)
        let w = Double(size.width.value), h = Double(size.height.value)
        func first(_ pan: Float) -> Double {
            let r = Double(pan).truncatingRemainder(dividingBy: s)
            return r < 0 ? r + s : r
        }
        var path = Path()
        for x in stride(from: first(g.pan.x.value), to: w, by: s) {
            for y in stride(from: first(g.pan.y.value), to: h, by: s) {
                path.addRect(Bounds(origin: ScreenPoint(x: Pixels(Float(x)), y: Pixels(Float(y))),
                                    size: Size(width: Pixels(2), height: Pixels(2))))
            }
        }
        return path
    }
}
