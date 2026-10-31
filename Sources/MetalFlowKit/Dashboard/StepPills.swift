import MetalFlowCore
import MetalUI

/// One step of a run's progress, a flow node with its lanes collapsed.
public struct StepPill: Equatable, Sendable, Identifiable {
    /// A step's collapsed state.
    public enum State: Equatable, Sendable {
        /// Every execution succeeded.
        case done
        /// At least one execution is running.
        case run
        /// Not started, or waiting on someone.
        case wait
        /// At least one execution failed.
        case fail
    }
    /// The node's title.
    public var label: String
    /// The collapsed state.
    public var state: State
    /// The node id.
    public var id: String
}

extension Run {
    /// One pill per flow node in plan order. Done if all its executions succeeded, run if any is running,
    /// fail if any failed, wait otherwise.
    public var stepPills: [StepPill] {
        let order = (try? flow.validate().order) ?? flow.nodes.map(\.id)
        return order.compactMap { id -> StepPill? in
            guard let node = flow.node(id) else { return nil }
            let states = nodes.filter { $0.key.node == id }.map(\.value.state)
            let state: StepPill.State
            if states.contains(where: { if case .failed = $0 { true } else { false } }) {
                state = .fail
            } else if states.contains(.running) {
                state = .run
            } else if !states.isEmpty && states.allSatisfy({ $0 == .succeeded }) {
                state = .done
            } else {
                state = .wait
            }
            return StepPill(label: node.title, state: state, id: id.rawValue)
        }
    }

    /// The newest log line, preferring nodes that are running.
    public var lastLogLine: String? {
        func pick(_ candidates: [(NodeKey, NodeRun)]) -> String? {
            candidates
                .filter { !$0.1.log.isEmpty }
                .max { a, b in
                    let (x, y) = (a.1.startedAt ?? .distantPast, b.1.startedAt ?? .distantPast)
                    return x != y ? x < y : a.0.description < b.0.description
                }?.1.log.last
        }
        let all = nodes.map { ($0.key, $0.value) }
        return pick(all.filter { $0.1.state == .running }) ?? pick(all)
    }
}

/// The row of step pills on a run card, coloured as in the mockup.
struct StepPills: Component {
    let pills: [StepPill]

    var content: some ElementGroup {
        HStack(spacing: Spacing.xs) {
            ForEach(pills, id: \.id) { pill in
                StepPillView(pill: pill)
            }
        }
    }
}

/// A single coloured pill.
struct StepPillView: Component {
    let pill: StepPill

    var content: some ElementGroup {
        let (bg, fg) = Self.colors(pill.state)
        Text(verbatim: pill.label).font(size: 11).foregroundColor(fg)
            .padding(insets(top: 3, right: 7, bottom: 3, left: 7))
            .background(bg)
            .cornerRadius(4)
            .accessibilityIdentifier("pill.\(pill.id).\(Self.name(pill.state))")
    }

    static func name(_ s: StepPill.State) -> String {
        switch s {
        case .done: "done"
        case .run: "run"
        case .wait: "wait"
        case .fail: "fail"
        }
    }

    static func colors(_ s: StepPill.State) -> (Color, Color) {
        switch s {
        case .done: (Color(Hsla.rgb(0x16261b)), Palette.ok)
        case .run: (Color(Hsla.rgb(0x152235)), Palette.accent)
        case .wait: (Color(Hsla.rgb(0x1b1e23)), Color(Hsla.rgb(0x8b93a1)))
        case .fail: (Color(Hsla.rgb(0x2a1618)), Palette.bad)
        }
    }
}
