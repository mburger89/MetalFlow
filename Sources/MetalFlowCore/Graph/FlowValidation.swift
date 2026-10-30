import Foundation

/// Reasons a flow is not runnable.
public enum FlowError: Error, Equatable, Sendable {
    /// A node ID is empty or has characters outside `[A-Za-z0-9_-]`.
    case invalidNodeID(NodeID)
    /// The flow contains a cycle through these nodes.
    case cycle([NodeID])
    /// A wire references a node that does not exist.
    case danglingWire(Wire)
    /// Two nodes share this ID.
    case duplicateNode(NodeID)
    /// Two wires feed the same placeholder of one node.
    case duplicateInput(NodeID, String)
    /// A fan-out node sits downstream of another fan-out.
    case nestedFanOut(NodeID)
    /// The flow has more than one fan-out node; this is the second.
    case multipleFanOuts(NodeID)
    /// A judge node has no fan-out upstream of it.
    case judgeWithoutFanOut(NodeID)
    /// A placeholder has no wire feeding it.
    case unwiredPlaceholder(NodeID, String)
}

/// The result of validating a flow: execution order and fan-out structure.
public struct FlowPlan: Hashable, Sendable {
    /// Topological order, ties broken by node order in the flow.
    public let order: [NodeID]
    /// The single fan-out node, if any.
    public let fanOut: NodeID?
    /// The fan-out node and its descendants, excluding judge/pick nodes and anything downstream of one.
    public let laneScoped: Set<NodeID>
}

extension Node {
    fileprivate var isFanOut: Bool {
        if case .prompt(let c) = kind { return c.candidates.count > 1 }
        return false
    }
    fileprivate var isJudgeOrPick: Bool {
        switch kind {
        case .judge, .pick: return true
        default: return false
        }
    }
}

extension Flow {
    /// Checks the flow and returns its execution plan.
    public func validate() throws(FlowError) -> FlowPlan {
        for n in nodes where !n.id.isValidIdentifier { throw .invalidNodeID(n.id) }
        var seen = Set<NodeID>()
        for n in nodes where !seen.insert(n.id).inserted { throw .duplicateNode(n.id) }
        for w in wires where !seen.contains(w.from) || !seen.contains(w.to) { throw .danglingWire(w) }
        var inputs = Set<String>()
        for w in wires where !inputs.insert("\(w.to.rawValue)\u{0}\(w.input)").inserted {
            throw .duplicateInput(w.to, w.input)
        }

        let order = try topologicalOrder()

        var children: [NodeID: [NodeID]] = [:]
        for w in wires { children[w.from, default: []].append(w.to) }
        func descendants(of id: NodeID) -> Set<NodeID> {
            var out = Set<NodeID>(), stack = children[id] ?? []
            while let n = stack.popLast(), out.insert(n).inserted { stack += children[n] ?? [] }
            return out
        }

        let fanOuts = order.filter { node($0)?.isFanOut == true }
        for f in fanOuts {
            let desc = descendants(of: f)
            if let nested = fanOuts.first(where: { desc.contains($0) }) { throw .nestedFanOut(nested) }
        }
        if fanOuts.count > 1 { throw .multipleFanOuts(fanOuts[1]) }
        let fanOut = fanOuts.first

        let downstreamOfFan = fanOut.map { descendants(of: $0) } ?? []
        for id in order {
            if let n = node(id), case .judge = n.kind, !downstreamOfFan.contains(id) {
                throw .judgeWithoutFanOut(id)
            }
        }

        for id in order {
            guard let n = node(id) else { continue }
            var texts: [String] = []
            var exempt: Set<String> = []
            switch n.kind {
            case .prompt(let c): texts = [c.prompt]
            case .judge(let c): texts = [c.prompt]; exempt = ["candidates"]
            case .shell(let c), .gate(let c): texts = [c.command]
            case .flowInput, .repo, .pick: break
            }
            let wired = Set(self.inputs(of: id).map(\.input))
            for name in texts.flatMap({ Template.placeholders(in: $0) })
            where !wired.contains(name) && !exempt.contains(name) {
                throw .unwiredPlaceholder(id, name)
            }
        }

        var scoped = Set<NodeID>()
        if let f = fanOut {
            var excluded = Set<NodeID>()
            for n in nodes where n.isJudgeOrPick {
                excluded.insert(n.id)
                excluded.formUnion(descendants(of: n.id))
            }
            scoped = Set([f]).union(descendants(of: f)).subtracting(excluded)
        }
        return FlowPlan(order: order, fanOut: fanOut, laneScoped: scoped)
    }

    private func topologicalOrder() throws(FlowError) -> [NodeID] {
        var indegree: [NodeID: Int] = [:]
        for n in nodes { indegree[n.id] = 0 }
        for w in wires { indegree[w.to, default: 0] += 1 }
        var remaining = nodes.map(\.id)
        var order: [NodeID] = []
        while let idx = remaining.firstIndex(where: { indegree[$0] == 0 }) {
            let id = remaining.remove(at: idx)
            order.append(id)
            for w in wires where w.from == id { indegree[w.to, default: 0] -= 1 }
        }
        if !remaining.isEmpty {
            // Trim nodes that merely hang off a cycle so the report names the cycle itself.
            var cyc = Set(remaining)
            var changed = true
            while changed {
                changed = false
                for id in cyc where !wires.contains(where: { $0.from == id && cyc.contains($0.to) }) {
                    cyc.remove(id); changed = true
                }
            }
            throw .cycle(remaining.filter { cyc.contains($0) })
        }
        return order
    }
}

extension NodeID {
    /// True when the ID is non-empty and uses only `[A-Za-z0-9_-]`.
    public var isValidIdentifier: Bool {
        !rawValue.isEmpty && rawValue.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45
        }
    }
}
