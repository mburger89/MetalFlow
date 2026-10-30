import Foundation
import Testing
@testable import MetalFlowCore

private func prompt(_ id: NodeID, _ text: String = "go", candidates: [String] = []) -> Node {
    Node(id: id, title: id.rawValue, kind: .prompt(PromptConfig(model: "sonnet", prompt: text, candidates: candidates, allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0))
}

private func wire(_ from: NodeID, _ to: NodeID, _ input: String = "in") -> Wire {
    Wire(from: from, to: to, input: input)
}

@Suite struct FlowValidationTests {
    @Test func orderRespectsWires() throws {
        let flow = Flow(name: "f", nodes: [prompt("c", "{x}{y}"), prompt("b", "{x}"), prompt("a")],
                        wires: [wire("a", "b", "x"), wire("b", "c", "x"), wire("a", "c", "y")])
        let order = try flow.validate().order
        let ia = order.firstIndex(of: "a")!, ib = order.firstIndex(of: "b")!, ic = order.firstIndex(of: "c")!
        #expect(ia < ib && ib < ic)
    }

    @Test func cycleIsRejected() {
        let flow = Flow(name: "f", nodes: [prompt("a", "{x}"), prompt("b", "{x}")],
                        wires: [wire("a", "b", "x"), wire("b", "a", "x")])
        do {
            _ = try flow.validate()
            Issue.record("expected cycle")
        } catch {
            guard case .cycle(let ids) = error else { Issue.record("wrong error \(error)"); return }
            #expect(ids.contains("a") && ids.contains("b"))
        }
    }

    @Test func danglingWireIsRejected() {
        let w = wire("a", "ghost")
        let flow = Flow(name: "f", nodes: [prompt("a")], wires: [w])
        #expect(throws: FlowError.danglingWire(w)) { try flow.validate() }
    }

    @Test func invalidNodeIDIsRejected() {
        for bad in ["a@b", "", "has space"] {
            let flow = Flow(name: "f", nodes: [prompt(NodeID(rawValue: bad))], wires: [])
            #expect(throws: FlowError.invalidNodeID(NodeID(rawValue: bad))) { try flow.validate() }
        }
    }

    @Test func duplicateNodeIsRejected() {
        let flow = Flow(name: "f", nodes: [prompt("a"), prompt("a")], wires: [])
        #expect(throws: FlowError.duplicateNode("a")) { try flow.validate() }
    }

    @Test func duplicateInputIsRejected() {
        let flow = Flow(name: "f", nodes: [prompt("a"), prompt("c"), prompt("b", "{x}")],
                        wires: [wire("a", "b", "x"), wire("c", "b", "x")])
        #expect(throws: FlowError.duplicateInput("b", "x")) { try flow.validate() }
    }

    @Test func nestedFanOutIsRejected() {
        let flow = Flow(name: "f", nodes: [prompt("first", candidates: ["a", "b", "c"]),
                                           prompt("second", "{x}", candidates: ["a", "b", "c"])],
                        wires: [wire("first", "second", "x")])
        #expect(throws: FlowError.nestedFanOut("second")) { try flow.validate() }
    }

    @Test func siblingFanOutsAreRejected() {
        let flow = Flow(name: "f", nodes: [prompt("one", candidates: ["a", "b"]),
                                           prompt("two", candidates: ["a", "b"])],
                        wires: [])
        #expect(throws: FlowError.multipleFanOuts("two")) { try flow.validate() }
    }

    @Test func laneScopeStopsAtJudge() throws {
        let judge = Node(id: "judge", title: "judge", kind: .judge(PromptConfig(model: "opus", prompt: "{candidates}", candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0))
        let gate = Node(id: "gate", title: "gate", kind: .gate(ShellConfig(command: "make {x}")), position: Point(x: 0, y: 0))
        let pick = Node(id: "pick", title: "pick", kind: .pick, position: Point(x: 0, y: 0))
        let flow = Flow(name: "f",
                        nodes: [prompt("plan"), prompt("impl", "{plan}", candidates: ["a", "b", "c"]), gate, judge, pick],
                        wires: [wire("plan", "impl", "plan"), wire("impl", "gate", "x"), wire("gate", "judge"), wire("judge", "pick")])
        let plan = try flow.validate()
        #expect(plan.laneScoped == ["impl", "gate"])
        #expect(plan.fanOut == "impl")
    }

    @Test func laneScopeExcludesJudgeDescendantsInDiamond() throws {
        let judge = Node(id: "judge", title: "judge", kind: .judge(PromptConfig(model: "opus", prompt: "{candidates}", candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0))
        let gate = Node(id: "gate", title: "gate", kind: .gate(ShellConfig(command: "make {x}")), position: Point(x: 0, y: 0))
        let flow = Flow(name: "f",
                        nodes: [prompt("impl", candidates: ["a", "b"]), gate, judge, prompt("report", "{j}{g}")],
                        wires: [wire("impl", "gate", "x"), wire("gate", "judge"), wire("judge", "report", "j"), wire("gate", "report", "g")])
        let plan = try flow.validate()
        #expect(plan.laneScoped == ["impl", "gate"])
    }

    @Test func noFanOutMeansEmptyScope() throws {
        let plan = try Flow(name: "f", nodes: [prompt("a")], wires: []).validate()
        #expect(plan.fanOut == nil)
        #expect(plan.laneScoped.isEmpty)
    }

    @Test func judgeWithoutFanOutIsRejected() {
        let judge = Node(id: "j", title: "j", kind: .judge(PromptConfig(model: "opus", prompt: "x", candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0))
        let flow = Flow(name: "f", nodes: [prompt("a"), judge], wires: [wire("a", "j")])
        #expect(throws: FlowError.judgeWithoutFanOut("j")) { try flow.validate() }
    }

    @Test func unwiredPlaceholderIsRejected() {
        let flow = Flow(name: "f", nodes: [prompt("a", "Fix {issue}")], wires: [])
        #expect(throws: FlowError.unwiredPlaceholder("a", "issue")) { try flow.validate() }
    }

    @Test func judgeIsExemptForCandidatesOnly() throws {
        func judge(_ text: String) -> Flow {
            let j = Node(id: "j", title: "j", kind: .judge(PromptConfig(model: "opus", prompt: text, candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0))
            return Flow(name: "f", nodes: [prompt("a", candidates: ["x", "y"]), j], wires: [wire("a", "j")])
        }
        _ = try judge("Pick {candidates}").validate()
        #expect(throws: FlowError.unwiredPlaceholder("j", "other")) { try judge("{candidates} {other}").validate() }
    }

    @Test func placeholderScanner() {
        #expect(Template.placeholders(in: "a {x} {y_1} {1no} {} {x}") == ["x", "y_1", "x"])
    }

    @Test func flowRoundTripsThroughJSON() throws {
        let flow = Flow(name: "rt",
                        nodes: [Node(id: "in", title: "Issue", kind: .flowInput(FlowInputConfig(name: "issue", source: .githubIssue)), position: Point(x: 1, y: 2)),
                                prompt("p", "{issue}", candidates: ["a", "b"]),
                                Node(id: "g", title: "G", kind: .gate(ShellConfig(command: "true")), position: Point(x: 3, y: 4))],
                        wires: [wire("in", "p", "issue"), wire("p", "g", "x")])
        let data = try JSONEncoder().encode(flow)
        #expect(try JSONDecoder().decode(Flow.self, from: data) == flow)
    }
}
