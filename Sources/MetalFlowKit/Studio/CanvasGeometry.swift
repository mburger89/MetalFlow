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

    /// Whether the point lies inside (half-open on the right and bottom edges).
    func contains(_ p: CanvasPoint) -> Bool { p.x >= x && p.x < x + w && p.y >= y && p.y < y + h }
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
        case .flowInput, .repo, .pick: height = 120
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

    /// A geometry whose projection of every node lies inside `size` with a 40 point margin, centred.
    /// A flow with no nodes gives the identity view.
    func fit(_ flow: Flow, in size: Size<Pixels>) -> CanvasGeometry {
        guard !flow.nodes.isEmpty else { return CanvasGeometry() }
        let rects = flow.nodes.map(nodeRect)
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
