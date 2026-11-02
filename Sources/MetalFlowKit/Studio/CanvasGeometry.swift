import MetalFlowCore
import MetalUI

/// A position on screen, in points relative to the canvas view.
typealias ScreenPoint = MetalUI.Point<Pixels>

/// A rectangle in canvas units.
struct CanvasRect: Equatable, Sendable {
    /// Left edge.
    var x: Double
    /// Top edge.
    var y: Double
    /// Width.
    var w: Double
    /// Height.
    var h: Double

    /// The right edge.
    var maxX: Double { x + w }
    /// The bottom edge.
    var maxY: Double { y + h }

    /// Whether the point lies inside (half-open on the right and bottom edges).
    func contains(_ p: CanvasPoint) -> Bool { p.x >= x && p.x < x + w && p.y >= y && p.y < y + h }

    /// Whether the two rectangles overlap. Rectangles that only touch do not.
    func intersects(_ other: CanvasRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

/// Which part of a note a point is on.
enum NotePart: Equatable, Sendable {
    /// A sticky anywhere: it grabs every press inside it.
    case body
    /// A frame's title strip or edge band: the only parts of a frame that grab a press.
    case chrome
    /// The resize handle at the bottom-right corner of a selected note.
    case handle
}

/// The sizes of notes, in canvas units. Computed, never measured, so drawing, hit testing and resizing agree.
enum NoteLayout {
    /// A new sticky's size.
    static let stickyWidth = 200.0
    static let stickyHeight = 120.0
    /// Slack between the nodes a new frame surrounds and the frame.
    static let framePadding = 24.0
    /// The title strip at the top of a frame.
    static let titleStrip = 22.0
    /// How far inside a frame's edge a press still grabs the frame.
    static let edgeBand = 6.0
    /// The side of the resize handle.
    static let handle = 12.0
    /// The smallest a note can be resized to.
    static let minimumWidth = 80.0
    static let minimumHeight = 40.0
    /// A sticky's text inset.
    static let textPadding = 8.0
}

/// Which side of a node a port is on.
enum PortSide: Equatable, Sendable {
    /// The left-middle port that receives wires.
    case input
    /// The right-middle port that sends wires.
    case output
}

/// The canvas view transform and the geometry of nodes and wires: `screen = canvas * zoom + pan`.
struct CanvasGeometry: Equatable {
    /// Where canvas point (0, 0) is drawn.
    var pan: ScreenPoint
    /// Points per canvas unit, 0.25...4.
    var zoom: Double

    /// Smallest zoom.
    static let minZoom = 0.25
    /// Largest zoom.
    static let maxZoom = 4.0
    /// Node width in canvas units.
    static let nodeWidth = 200.0
    /// Port hit radius in screen points.
    static let portRadius = 8.0
    /// Margin `fit` leaves around the nodes, in screen points.
    static let fitMargin = 40.0

    /// The identity view.
    init(pan: ScreenPoint = ScreenPoint(x: Pixels(0), y: Pixels(0)), zoom: Double = 1) {
        self.pan = pan
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
    }

    /// The screen position of a canvas point.
    func toScreen(_ p: CanvasPoint) -> ScreenPoint {
        ScreenPoint(x: Pixels(Float(p.x * zoom + Double(pan.x.value))), y: Pixels(Float(p.y * zoom + Double(pan.y.value))))
    }

    /// The canvas point under a screen position.
    func toCanvas(_ p: ScreenPoint) -> CanvasPoint {
        CanvasPoint(x: (Double(p.x.value) - Double(pan.x.value)) / zoom, y: (Double(p.y.value) - Double(pan.y.value)) / zoom)
    }

    /// Sets the zoom (clamped), keeping the canvas point under the screen point `anchor` where it is
    /// (CanvasDemo's formula).
    mutating func zoom(to newZoom: Double, about anchor: ScreenPoint) {
        let clamped = min(max(newZoom, Self.minZoom), Self.maxZoom)
        let factor = clamped / zoom
        let px = Double(anchor.x.value), py = Double(anchor.y.value)
        pan = ScreenPoint(
            x: Pixels(Float(px - (px - Double(pan.x.value)) * factor)),
            y: Pixels(Float(py - (py - Double(pan.y.value)) * factor)))
        zoom = clamped
    }

    /// A node's rectangle in canvas units: 200 wide, 120 tall for input, repo and pick nodes, else 140.
    func nodeRect(_ n: Node) -> CanvasRect {
        let height: Double
        switch n.kind {
        case .flowInput, .repo, .pick, .openPR: height = 120
        default: height = 140
        }
        return CanvasRect(x: n.position.x, y: n.position.y, w: Self.nodeWidth, h: height)
    }

    /// The right-middle port, in canvas units.
    func outPort(_ n: Node) -> CanvasPoint {
        let r = nodeRect(n)
        return CanvasPoint(x: r.x + r.w, y: r.y + r.h / 2)
    }

    /// The left-middle port, in canvas units.
    func inPort(_ n: Node) -> CanvasPoint {
        let r = nodeRect(n)
        return CanvasPoint(x: r.x, y: r.y + r.h / 2)
    }

    /// A wire as a cubic: start, two control points at the horizontal midpoint, end. All in the units of the inputs.
    func wirePath(from a: CanvasPoint, to b: CanvasPoint) -> (CanvasPoint, CanvasPoint, CanvasPoint, CanvasPoint) {
        let mid = (a.x + b.x) / 2
        return (a, CanvasPoint(x: mid, y: a.y), CanvasPoint(x: mid, y: b.y), b)
    }

    /// The topmost (last drawn) node containing the canvas point.
    func hitNode(at canvas: CanvasPoint, in flow: Flow) -> NodeID? {
        flow.nodes.last { nodeRect($0).contains(canvas) }?.id
    }

    /// The nodes whose rectangle overlaps `rect`, in draw order. Any overlap counts.
    func nodes(in rect: CanvasRect, flow: Flow) -> [NodeID] {
        flow.nodes.filter { node in
            let r = nodeRect(node)
            return r.x < rect.x + rect.w && rect.x < r.x + r.w && r.y < rect.y + rect.h && rect.y < r.y + r.h
        }.map(\.id)
    }

    /// A note's rectangle in canvas units.
    func noteRect(_ n: FlowNote) -> CanvasRect {
        CanvasRect(x: n.origin.x, y: n.origin.y, w: n.width, h: n.height)
    }

    /// The part of a frame drawn at `rect` that is not its chrome (inside the title strip and the edge band); nil when
    /// the frame is so small that all of it is chrome.
    func interior(of rect: CanvasRect) -> CanvasRect? {
        let w = rect.w - 2 * NoteLayout.edgeBand, h = rect.h - NoteLayout.titleStrip - NoteLayout.edgeBand
        guard w > 0, h > 0 else { return nil }
        return CanvasRect(x: rect.x + NoteLayout.edgeBand, y: rect.y + NoteLayout.titleStrip, w: w, h: h)
    }

    /// The resize handle of a note drawn at `rect`: its bottom-right corner.
    func handleRect(of rect: CanvasRect) -> CanvasRect {
        CanvasRect(x: rect.maxX - NoteLayout.handle, y: rect.maxY - NoteLayout.handle, w: NoteLayout.handle, h: NoteLayout.handle)
    }

    /// The note under a canvas point, with the part of it. Order: the handle of a selected note, then stickies (the
    /// last drawn first), then the chrome of frames. A frame's interior is not a hit, so nodes and empty canvas
    /// inside it still get their presses. The caller puts nodes between the handle and the rest.
    func hitNote(at canvas: CanvasPoint, in flow: Flow, selected: Set<NoteID>) -> (NoteID, NotePart)? {
        for note in flow.notes.reversed() where selected.contains(note.id) && handleRect(of: noteRect(note)).contains(canvas) {
            return (note.id, .handle)
        }
        for note in flow.notes.reversed() where !note.surrounds && noteRect(note).contains(canvas) {
            return (note.id, .body)
        }
        for note in flow.notes.reversed() where note.surrounds {
            let rect = noteRect(note)
            guard rect.contains(canvas) else { continue }
            if interior(of: rect)?.contains(canvas) != true { return (note.id, .chrome) }
        }
        return nil
    }

    /// The notes a box takes, in draw order: a sticky it overlaps, a frame whose chrome it meets (a box wholly inside
    /// a frame's interior is among the nodes, not on the frame).
    func notes(in box: CanvasRect, flow: Flow) -> [NoteID] {
        flow.notes.filter { note in
            let rect = noteRect(note)
            guard rect.intersects(box) else { return false }
            guard note.surrounds, let inside = interior(of: rect) else { return true }
            let wholly = box.x >= inside.x && box.y >= inside.y && box.maxX <= inside.maxX && box.maxY <= inside.maxY
            return !wholly
        }.map(\.id)
    }

    /// The nodes whose centre lies inside `rect`, in draw order.
    func nodes(centredIn rect: CanvasRect, flow: Flow) -> [NodeID] {
        flow.nodes.filter { node in
            let r = nodeRect(node)
            return rect.contains(CanvasPoint(x: r.x + r.w / 2, y: r.y + r.h / 2))
        }.map(\.id)
    }

    /// The port within 8 screen points of the canvas point. Outputs win over inputs; later nodes over earlier.
    func hitPort(at canvas: CanvasPoint, in flow: Flow) -> (NodeID, PortSide)? {
        let radius = Self.portRadius / zoom
        func near(_ p: CanvasPoint) -> Bool {
            let dx = p.x - canvas.x, dy = p.y - canvas.y
            return dx * dx + dy * dy <= radius * radius
        }
        for node in flow.nodes.reversed() {
            if near(outPort(node)) { return (node.id, .output) }
            if near(inPort(node)) { return (node.id, .input) }
        }
        return nil
    }

    /// The wire passing within `tolerance` screen points of a canvas-local screen point, sampling each cubic.
    /// Later wires win.
    func hitWire(at screen: ScreenPoint, in flow: Flow, tolerance: Double = 6) -> Wire? {
        let px = Double(screen.x.value), py = Double(screen.y.value)
        func distance(_ a: ScreenPoint, _ b: ScreenPoint) -> Double {
            let ax = Double(a.x.value), ay = Double(a.y.value), bx = Double(b.x.value), by = Double(b.y.value)
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : min(max(((px - ax) * dx + (py - ay) * dy) / len2, 0), 1)
            let cx = ax + t * dx - px, cy = ay + t * dy - py
            return (cx * cx + cy * cy).squareRoot()
        }
        for wire in flow.wires.reversed() {
            guard let from = flow.node(wire.from), let to = flow.node(wire.to) else { continue }
            let (a, c1, c2, b) = wirePath(from: outPort(from), to: inPort(to))
            let steps = 24
            var previous = toScreen(a)
            for i in 1...steps {
                let t = Double(i) / Double(steps), u = 1 - t
                let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
                let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
                let next = toScreen(CanvasPoint(x: x, y: y))
                if distance(previous, next) <= tolerance { return wire }
                previous = next
            }
        }
        return nil
    }

    /// A geometry whose projection of every node and note lies inside `size` with a 40 point margin, centred.
    /// A flow with no nodes or notes gives the identity view.
    func fit(_ flow: Flow, in size: Size<Pixels>) -> CanvasGeometry {
        let rects = flow.nodes.map(nodeRect) + flow.notes.map(noteRect)
        guard !rects.isEmpty else { return CanvasGeometry() }
        let minX = rects.map(\.x).min()!, minY = rects.map(\.y).min()!
        let maxX = rects.map { $0.x + $0.w }.max()!, maxY = rects.map { $0.y + $0.h }.max()!
        let w = Double(size.width.value), h = Double(size.height.value)
        let bw = max(maxX - minX, 1), bh = max(maxY - minY, 1)
        let z = min(max(min((w - 2 * Self.fitMargin) / bw, (h - 2 * Self.fitMargin) / bh), Self.minZoom), Self.maxZoom)
        let px = (w - bw * z) / 2 - minX * z
        let py = (h - bh * z) / 2 - minY * z
        return CanvasGeometry(pan: ScreenPoint(x: Pixels(Float(px)), y: Pixels(Float(py))), zoom: z)
    }
}
