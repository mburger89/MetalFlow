import MetalFlowCore
import MetalUI

/// All wires in one stroked `Path`, and the ports in another. Wires touching the selected node are drawn
/// again in the accent colour.
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
            paths.ports.fill(Palette.ground)
            paths.ports.stroke(Color(Hsla.rgb(0x5d6470)), lineWidth: Pixels(1))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The wire paths, split by whether they touch the selection, and the port circles.
    static func paths(flow: Flow, geometry g: CanvasGeometry, selection: NodeID?) -> (all: Path, selected: Path, ports: Path) {
        var all = Path(), selected = Path(), ports = Path()
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
        let r = Float(4 * g.zoom)
        for node in flow.nodes {
            for p in [g.outPort(node), g.inPort(node)] {
                let s = g.toScreen(p)
                ports.addEllipse(in: Bounds(origin: ScreenPoint(x: s.x - Pixels(r), y: s.y - Pixels(r)),
                                            size: Size(width: Pixels(2 * r), height: Pixels(2 * r))))
            }
        }
        return (all, selected, ports)
    }
}
