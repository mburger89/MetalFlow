import MetalFlowCore
import MetalUI

/// All wires in one stroked `Path`. Wires touching the selected node are left out of it and drawn in a second,
/// accent-coloured `Path`.
struct WireLayer: Component {
    let flow: Flow
    let geometry: CanvasGeometry
    let selection: NodeID?
    let size: Size<Pixels>

    var content: some ElementGroup {
        let paths = Self.paths(flow: flow, geometry: geometry, selection: selection)
        ZStack(alignment: .topLeading) {
            paths.all.stroke(Palette.muted.opacity(0.55), lineWidth: Pixels(2))
            if !paths.selected.isEmpty {
                paths.selected.stroke(Palette.accent, lineWidth: Pixels(2))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The wire paths, split by whether they touch the selection, and the port circles.
    static func paths(flow: Flow, geometry g: CanvasGeometry, selection: NodeID?) -> (all: Path, selected: Path) {
        var all = Path(), selected = Path()
        for wire in flow.wires {
            guard let from = flow.node(wire.from), let to = flow.node(wire.to) else { continue }
            let (a, c1, c2, b) = g.wirePath(from: g.outPort(from), to: g.inPort(to))
            let (sa, s1, s2, sb) = (g.toScreen(a), g.toScreen(c1), g.toScreen(c2), g.toScreen(b))
            let touches = selection != nil && (wire.from == selection || wire.to == selection)
            if touches {
                selected.move(to: sa); selected.addCurve(to: sb, control1: s1, control2: s2)
            } else {
                all.move(to: sa); all.addCurve(to: sb, control1: s1, control2: s2)
            }
        }
        return (all, selected)
    }
}

/// The port circles, drawn above the node cards as in the mockup.
struct PortLayer: Component {
    let flow: Flow
    let geometry: CanvasGeometry
    let size: Size<Pixels>

    var content: some ElementGroup {
        let ports = Self.path(flow: flow, geometry: geometry)
        ZStack(alignment: .topLeading) {
            ports.fill(Palette.ground)
            ports.stroke(Color(Hsla.rgb(0x5d6470)), lineWidth: Pixels(1))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// One circle per input and output port.
    static func path(flow: Flow, geometry g: CanvasGeometry) -> Path {
        var ports = Path()
        let r = Float(4 * g.zoom)
        for node in flow.nodes {
            for p in [g.outPort(node), g.inPort(node)] {
                let s = g.toScreen(p)
                ports.addEllipse(in: Bounds(origin: ScreenPoint(x: s.x - Pixels(r), y: s.y - Pixels(r)),
                                            size: Size(width: Pixels(2 * r), height: Pixels(2 * r))))
            }
        }
        return ports
    }
}
