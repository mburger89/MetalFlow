import MetalFlowCore
import MetalUI

/// What a node card shows beyond the node itself.
struct NodeOverlay: Equatable {
    /// The status line.
    var text: String
    /// Its colour.
    var color: Color
}

extension Node {
    /// The small caps label above the title.
    var kindLabel: String {
        switch kind {
        case .flowInput: "FLOW INPUT"
        case .repo: "CONTEXT"
        case .prompt(let c): c.candidates.count > 1 ? "PROMPT · FAN-OUT" : "PROMPT"
        case .shell: "SHELL"
        case .gate: "GATE"
        case .judge: "JUDGE"
        case .pick: "YOU PICK"
        }
    }

    /// The kind's accent, as in the mockup.
    var kindColor: Color {
        switch kind {
        case .flowInput, .repo: Color(Hsla.rgb(0x8b93a1))
        case .prompt: Palette.accent
        case .shell, .gate: Color(Hsla.rgb(0x4fd1a5))
        case .judge: Palette.warn
        case .pick: Color(Hsla.rgb(0xd2a8ff))
        }
    }

    /// A line or two about what the node does.
    var summary: String {
        switch kind {
        case .flowInput(let c): c.source == .githubIssue ? "gh issue view {\(c.name)}" : "Text you type: {\(c.name)}"
        case .repo: "The run's worktree"
        case .prompt(let c):
            c.candidates.count > 1 ? "×\(c.candidates.count): \(c.candidates.joined(separator: ", "))" : c.model
        case .shell(let c), .gate(let c): c.command
        case .judge(let c): c.model
        case .pick: "Merge the chosen branch back"
        }
    }
}

extension NodeOverlay {
    /// The nodes whose state is per lane: those of the run's own flow, or, if that flow does not validate,
    /// those with lane-keyed states in the run.
    static func laneScoped(_ run: Run) -> Set<NodeID> {
        if let plan = try? run.flow.validate() { return plan.laneScoped }
        return Set(run.nodes.keys.filter { $0.lane != nil }.map(\.node))
    }

    /// The overlay of `node` in `run`. A lane-scoped node reads "A ✓ B ✓ C ✕", one lane per candidate;
    /// any other node shows its state as the run detail words it.
    @MainActor
    static func make(node: Node, run: Run, laneScoped: Bool) -> NodeOverlay {
        if laneScoped, !run.lanes.isEmpty {
            let states = run.lanes.map { lane in run.nodes[NodeKey(node: node.id, lane: lane.id)]?.state ?? .waiting }
            let text = zip(run.lanes, states).map { "\($0.id.uppercased()) \(NodeStateStyle($1).symbol)" }.joined(separator: " ")
            return NodeOverlay(text: text, color: aggregateColor(states))
        }
        let state = run.nodes[NodeKey(node: node.id)]?.state ?? .waiting
        let style = NodeStateStyle(state)
        return NodeOverlay(text: style.text, color: style.color)
    }

    private static func aggregateColor(_ states: [NodeState]) -> Color {
        if states.contains(where: { if case .failed = $0 { true } else { false } }) { return Tone.bad.color }
        if states.contains(where: { if case .needsYou = $0 { true } else { false } }) { return Tone.warn.color }
        if states.contains(.running) { return Tone.accent.color }
        if states.allSatisfy({ $0 == .succeeded }) { return Tone.ok.color }
        return Tone.muted.color
    }
}

extension NodeCardView {
    /// Counts a `content` run in debug builds (tests); nothing in release.
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}

/// One node on the canvas, drawn at its position for the zoom but not the pan: the canvas offsets all the cards by the
/// pan together, and an `.equatable()` card whose node, zoom, selection and overlay are unchanged is not rebuilt for it.
struct NodeCardView: Component, @MainActor Equatable {
    let node: Node
    let zoom: Double
    let selected: Bool
    let overlay: NodeOverlay?

    /// How many times a card's `content` has run, for the test that a pan leaves the cards alone.
    @MainActor static var bodyCount = 0

    var content: some ElementGroup {
        let _ = Self.countBody()
        let z = zoom
        let rect = CanvasGeometry().nodeRect(node)
        let origin = (x: Pixels(Float(rect.x * z)), y: Pixels(Float(rect.y * z)))
        VStack(alignment: .leading, spacing: Pixels(Float(4 * z))) {
            Text(verbatim: node.kindLabel).font(size: 10.5 * z).foregroundColor(node.kindColor)
            Text(verbatim: node.title).font(size: 14 * z).foregroundColor(Palette.text)
                .accessibilityIdentifier("node.\(node.id.rawValue).title")
                .lineLimit(1)
            Text(verbatim: node.summary).font(size: 12 * z).foregroundColor(Palette.body).lineLimit(2)
            Spacer()
            if let overlay {
                Text(verbatim: overlay.text).font(size: 12 * z).foregroundColor(overlay.color)
                    .accessibilityIdentifier("node.\(node.id.rawValue).status")
                    .lineLimit(1)
            }
        }
        .padding(Edges(all: Pixels(Float(10 * z))))
        .frame(width: Pixels(Float(rect.w * z)), height: Pixels(Float(rect.h * z)), alignment: .topLeading)
        .background(Color(Hsla.rgb(0x181b21)))
        .cornerRadius(Pixels(Float(10 * z)))
        .border(selected ? Palette.accent : Color(Hsla.rgb(0x262a31)), width: Pixels(selected ? 2 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("node.\(node.id.rawValue)")
        .offset(x: origin.x, y: origin.y)
    }
}
