import MetalFlowCore
import MetalUI
import Testing
@testable import MetalFlowKit

@Suite struct CanvasGeometryTests {
    func screen(_ x: Double, _ y: Double) -> ScreenPoint { ScreenPoint(x: Pixels(Float(x)), y: Pixels(Float(y))) }
    func node(_ id: String, _ kind: NodeKind, at x: Double, _ y: Double) -> Node {
        Node(id: NodeID(rawValue: id), title: id, kind: kind, position: CanvasPoint(x: x, y: y))
    }
    func prompt() -> NodeKind {
        .prompt(PromptConfig(model: "opus", prompt: "x", candidates: [], allowedTools: [], maxTurns: nil))
    }

    @Test func roundTripScreenCanvas() {
        let g = CanvasGeometry(pan: screen(37, -12), zoom: 1.75)
        let p = CanvasPoint(x: 120, y: 80)
        let back = g.toCanvas(g.toScreen(p))
        #expect(abs(back.x - 120) < 0.01 && abs(back.y - 80) < 0.01)
        let s = g.toScreen(CanvasPoint(x: 0, y: 0))
        #expect(s == screen(37, -12))
    }

    @Test func zoomAboutPointKeepsItFixed() {
        var g = CanvasGeometry(pan: screen(10, 20), zoom: 1)
        let anchor = screen(300, 200)
        let before = g.toCanvas(anchor)
        g.zoom(to: 2.5, about: anchor)
        let after = g.toCanvas(anchor)
        #expect(g.zoom == 2.5)
        #expect(abs(before.x - after.x) < 0.01 && abs(before.y - after.y) < 0.01)
    }

    @Test func zoomClamps() {
        var g = CanvasGeometry()
        g.zoom(to: 100, about: screen(0, 0))
        #expect(g.zoom == 4)
        g.zoom(to: 0.001, about: screen(0, 0))
        #expect(g.zoom == 0.25)
        #expect(CanvasGeometry(zoom: 9).zoom == 4)
    }

    @Test func nodeSizesAndPorts() {
        let g = CanvasGeometry()
        let input = node("i", .repo, at: 10, 20)
        let step = node("p", prompt(), at: 300, 20)
        #expect(g.nodeRect(input) == CanvasRect(x: 10, y: 20, w: 200, h: 120))
        #expect(g.nodeRect(step) == CanvasRect(x: 300, y: 20, w: 200, h: 140))
        #expect(g.outPort(input) == CanvasPoint(x: 210, y: 80))
        #expect(g.inPort(step) == CanvasPoint(x: 300, y: 90))
        let (a, c1, c2, b) = g.wirePath(from: g.outPort(input), to: g.inPort(step))
        #expect(a == CanvasPoint(x: 210, y: 80) && b == CanvasPoint(x: 300, y: 90))
        #expect(c1 == CanvasPoint(x: 255, y: 80) && c2 == CanvasPoint(x: 255, y: 90))
    }

    @Test func hitNodeTopmostWins() {
        let flow = Flow(name: "t", nodes: [node("under", prompt(), at: 0, 0), node("over", prompt(), at: 100, 50)], wires: [])
        let g = CanvasGeometry()
        #expect(g.hitNode(at: CanvasPoint(x: 150, y: 100), in: flow) == "over")
        #expect(g.hitNode(at: CanvasPoint(x: 10, y: 10), in: flow) == "under")
        #expect(g.hitNode(at: CanvasPoint(x: 900, y: 900), in: flow) == nil)
    }

    @Test func hitPortRadius() {
        let flow = Flow(name: "t", nodes: [node("a", prompt(), at: 0, 0)], wires: [])
        let g = CanvasGeometry()
        // a's out port is at (200, 70), its in port at (0, 70).
        #expect(g.hitPort(at: CanvasPoint(x: 207, y: 70), in: flow)?.1 == .output)
        #expect(g.hitPort(at: CanvasPoint(x: 209, y: 70), in: flow) == nil)
        #expect(g.hitPort(at: CanvasPoint(x: -5, y: 74), in: flow)?.1 == .input)
        let zoomed = CanvasGeometry(zoom: 2)
        // 8 screen points are 4 canvas units at zoom 2.
        #expect(zoomed.hitPort(at: CanvasPoint(x: 203, y: 70), in: flow) != nil)
        #expect(zoomed.hitPort(at: CanvasPoint(x: 205, y: 70), in: flow) == nil)
    }

    @Test func fitContainsAllNodes() {
        let flow = BuiltinFlows.fixGitHubIssue
        for size in [Size(width: Pixels(900), height: Pixels(600)), Size(width: Pixels(400), height: Pixels(700)), Size(width: Pixels(3000), height: Pixels(2000))] {
            let g = CanvasGeometry().fit(flow, in: size)
            var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
            for n in flow.nodes {
                let r = g.nodeRect(n)
                let tl = g.toScreen(CanvasPoint(x: r.x, y: r.y)), br = g.toScreen(CanvasPoint(x: r.x + r.w, y: r.y + r.h))
                minX = min(minX, tl.x.value); minY = min(minY, tl.y.value)
                maxX = max(maxX, br.x.value); maxY = max(maxY, br.y.value)
            }
            #expect(minX >= 39.9 && minY >= 39.9, "\(size)")
            #expect(maxX <= size.width.value - 39.9 && maxY <= size.height.value - 39.9)
            // Centred: equal slack on both sides in both axes.
            let left = minX, right = size.width.value - maxX, top = minY, bottom = size.height.value - maxY
            #expect(abs(left - right) < 0.5 && abs(top - bottom) < 0.5)
        }
    }

    @Test func clampedFitIsStillCentred() {
        let size = Size(width: Pixels(900), height: Pixels(800))
        let one = Flow(name: "t", nodes: [node("a", prompt(), at: 50, 50)], wires: [])
        let big = CanvasGeometry().fit(one, in: size)
        #expect(big.zoom == 4)
        let c = big.toScreen(CanvasPoint(x: 150, y: 120))   // the node's centre
        #expect(abs(c.x.value - 450) < 0.5 && abs(c.y.value - 400) < 0.5)

        let huge = Flow(name: "t", nodes: [node("a", prompt(), at: 0, 0), node("b", prompt(), at: 20_000, 9_000)], wires: [])
        let small = CanvasGeometry().fit(huge, in: size)
        #expect(small.zoom == 0.25)
        let mid = small.toScreen(CanvasPoint(x: 10_100, y: 4_570))   // the middle of the bounding box
        #expect(abs(mid.x.value - 450) < 0.5 && abs(mid.y.value - 400) < 0.5)
    }
}
