import Foundation
import MetalFlowCore
import MetalUI

/// The graph: dotted grid, wires and node cards under a pan and zoom, with the Fit button and zoom readout.
/// Pan with the wheel or a middle / secondary drag, zoom with ⌘-wheel or a pinch, click to select.
struct CanvasView: Component {
    let model: AppModel
    let draft: FlowDraft

    var content: some ElementGroup {
        let g = draft.geometry
        let size = draft.canvasSize ?? Size(width: Pixels(0), height: Pixels(0))
        let run = model.studioShownRun
        let scoped = run.map(NodeOverlay.laneScoped) ?? []
        let draft = draft
        ZStack(alignment: .topLeading) {
            DotGrid(geometry: g, size: size)
            WireLayer(flow: draft.flow, geometry: g, selection: draft.selection, selectedWire: draft.selectedWire,
                      pending: draft.pendingWire, size: size)
            ForEach(draft.flow.nodes, id: \.id) { node in
                NodeCardView(
                    node: node, geometry: g, selected: draft.selection == node.id,
                    overlay: run.map { NodeOverlay.make(node: node, run: $0, laneScoped: scoped.contains(node.id)) })
            }
            PortLayer(flow: draft.flow, geometry: g, size: size)
        }
        // minWidth / minHeight 0: the layers are as big as the canvas was last, and must not stop it shrinking
        // (the candidates strip appearing takes space from it).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(Hsla.rgb(0x101215)))
        .clipped()
        .overlay(alignment: .topLeading) {
            // Marks the canvas's origin (a container's identifier would replace those inside it).
            Spacer().frame(width: 0, height: 0).accessibilityIdentifier("canvas")
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: Spacing.xs) {
                Text(verbatim: "\(Int((g.zoom * 100).rounded()))%").font(size: 12).foregroundColor(Palette.body)
                    .accessibilityIdentifier("canvas.zoom")
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
        .onScrollWheel { Self.scroll($0, draft) }
        .gesture(SpatialTapGesture().onEnded { draft.select(at: $0.location) })
        .gesture(MagnifyGesture()
            .onChanged { draft.pinchChanged($0) }
            .onEnded { draft.pinchEnded($0) })
        .focusable(true, interactions: .edit)
        .onKeyPress { Self.key($0, draft) }
        .gesture(DragGesture(minimumDistance: Pixels(3))
            .onChanged { draft.primaryDragChanged($0) }
            .onEnded { draft.primaryDragEnded($0) })
        .gesture(DragGesture(button: .middle)
            .onChanged { draft.panChanged($0) }
            .onEnded { _ in draft.panStart = nil })
        .gesture(DragGesture(button: .secondary)
            .onChanged { draft.panChanged($0) }
            .onEnded { _ in draft.panStart = nil })
    }

    /// Delete and Backspace remove the selection; ⌘Z undoes, ⇧⌘Z redoes. Only reached while the canvas has focus,
    /// so typing in an inspector field never lands here.
    @MainActor
    static func key(_ press: KeyPress, _ draft: FlowDraft) -> KeyPress.Result {
        if press.key == .delete || press.key == .deleteForward {
            guard draft.selection != nil || draft.selectedWire != nil else { return .ignored }
            draft.deleteSelection()
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
    /// Selects the node under a canvas-local screen point, else the wire near it, else clears the selection.
    func select(at location: ScreenPoint) {
        lastEditName = nil  // a click on the canvas moves focus off any inspector field
        if let id = geometry.hitNode(at: geometry.toCanvas(location), in: flow) {
            selection = id
        } else if let wire = geometry.hitWire(at: location, in: flow) {
            selectedWire = wire
        } else {
            selection = nil
            selectedWire = nil
        }
    }

    /// A primary drag: on an out-port it draws a wire, on a node it moves it, on empty canvas it pans.
    func primaryDragChanged(_ value: DragGesture.Value) {
        if dragMode == nil {
            let start = geometry.toCanvas(value.startLocation)
            if let (id, side) = geometry.hitPort(at: start, in: flow), side == .output {
                dragMode = .wire(id)
            } else if let id = geometry.hitNode(at: start, in: flow), let node = flow.node(id) {
                dragMode = .move(id, origin: node.position)
                dragStartFlow = flow
                selection = id
            } else {
                dragMode = .pan
            }
        }
        switch dragMode {
        case .move(let id, let origin):
            let z = geometry.zoom
            moveLive(id, to: CanvasPoint(x: origin.x + Double(value.translation.width.value) / z,
                                         y: origin.y + Double(value.translation.height.value) / z))
        case .wire(let id):
            pendingWire = (id, value.location)
        case .pan, nil:
            panChanged(value)
        }
    }

    func primaryDragEnded(_ value: DragGesture.Value) {
        switch dragMode {
        case .move:
            finishMove()
        case .wire(let from):
            pendingWire = nil
            if let (to, side) = geometry.hitPort(at: geometry.toCanvas(value.location), in: flow), side == .input {
                connect(from: from, to: to, allowParallel: false)
            }
        case .pan, nil:
            panStart = nil
        }
        dragMode = nil
    }

    func panChanged(_ value: DragGesture.Value) {
        if panStart == nil { panStart = geometry.pan }
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
