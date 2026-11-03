import Foundation
import Testing
@testable import MetalFlowCore

private func prompt(_ id: NodeID, _ text: String = "go", candidates: [String] = [], continues: NodeID? = nil) -> Node {
    Node(id: id, title: "T-\(id.rawValue)", kind: .prompt(PromptConfig(
        model: "sonnet", prompt: text, candidates: candidates, allowedTools: [], maxTurns: nil,
        continuesSessionOf: continues)), position: Point(x: 0, y: 0))
}

private func wire(_ from: NodeID, _ to: NodeID, _ input: String = "in") -> Wire {
    Wire(from: from, to: to, input: input)
}

@Suite struct ContinueSessionTests {
    typealias Harness = RunEngineTests.Harness

    // MARK: Validation

    @Test func sourceMustExist() {
        let flow = Flow(name: "f", nodes: [prompt("a"), prompt("b", continues: "ghost")], wires: [wire("a", "b")])
        #expect(throws: FlowError.badSessionSource("b")) { try flow.validate() }
    }

    @Test func sourceMustBeAPrompt() {
        let judge = Node(id: "j", title: "J", kind: .judge(PromptConfig(
            model: "sonnet", prompt: "go", candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0))
        let flow = Flow(name: "f", nodes: [prompt("f", candidates: ["a", "b"]), judge, prompt("b", continues: "j")],
                        wires: [wire("f", "j"), wire("j", "b")])
        #expect(throws: FlowError.badSessionSource("b")) { try flow.validate() }
        let shell = Node(id: "s", title: "S", kind: .shell(ShellConfig(command: "true")), position: Point(x: 0, y: 0))
        let flow2 = Flow(name: "f", nodes: [shell, prompt("b", continues: "s")], wires: [wire("s", "b")])
        #expect(throws: FlowError.badSessionSource("b")) { try flow2.validate() }
    }

    @Test func sourceMustBeUpstream() {
        let sibling = Flow(name: "f", nodes: [prompt("a"), prompt("b", continues: "a")], wires: [])
        #expect(throws: FlowError.badSessionSource("b")) { try sibling.validate() }
        let downstream = Flow(name: "f", nodes: [prompt("a", continues: "b"), prompt("b")], wires: [wire("a", "b")])
        #expect(throws: FlowError.badSessionSource("a")) { try downstream.validate() }
        let itself = Flow(name: "f", nodes: [prompt("a", continues: "a")], wires: [])
        #expect(throws: FlowError.badSessionSource("a")) { try itself.validate() }
    }

    @Test func laneCannotContinueNonLane() {
        let flow = Flow(name: "f", nodes: [prompt("a"), prompt("f", candidates: ["x", "y"], continues: "a")],
                        wires: [wire("a", "f")])
        #expect(throws: FlowError.sessionScopeMismatch("f")) { try flow.validate() }
        let after = Flow(name: "f", nodes: [prompt("a"), prompt("f", candidates: ["x", "y"]), prompt("l", continues: "a")],
                         wires: [wire("a", "f"), wire("f", "l")])
        #expect(throws: FlowError.sessionScopeMismatch("l")) { try after.validate() }
    }

    @Test func nonLaneCannotContinueLane() {
        let judge = Node(id: "j", title: "J", kind: .judge(PromptConfig(
            model: "sonnet", prompt: "go", candidates: [], allowedTools: [], maxTurns: nil,
            continuesSessionOf: "f")), position: Point(x: 0, y: 0))
        let flow = Flow(name: "f", nodes: [prompt("f", candidates: ["x", "y"]), judge], wires: [wire("f", "j")])
        #expect(throws: FlowError.sessionScopeMismatch("j")) { try flow.validate() }
    }

    @Test func reviewCannotContinue() {
        var review = ReviewConfig()
        review.agent.continuesSessionOf = "f"
        let flow = Flow(name: "f", nodes: [
            prompt("f", candidates: ["x", "y"]),
            Node(id: "r", title: "R", kind: .review(review), position: Point(x: 0, y: 0)),
            Node(id: "j", title: "J", kind: .judge(PromptConfig(model: "sonnet", prompt: "go", candidates: [], allowedTools: [], maxTurns: nil)),
                 position: Point(x: 0, y: 0)),
        ], wires: [wire("f", "r"), wire("r", "j")])
        #expect(throws: FlowError.badSessionSource("r")) { try flow.validate() }
    }

    @Test func twoCannotContinueOne() {
        let flow = Flow(name: "f", nodes: [prompt("a"), prompt("b", continues: "a"), prompt("c", continues: "a")],
                        wires: [wire("a", "b"), wire("b", "c")])
        #expect(throws: FlowError.sessionContinuedTwice("c")) { try flow.validate() }
    }

    @Test func valid() throws {
        let plain = Flow(name: "f", nodes: [prompt("a"), prompt("b", continues: "a")], wires: [wire("a", "b")])
        _ = try plain.validate()
        let lanes = Flow(name: "f", nodes: [prompt("f", candidates: ["x", "y"]), prompt("l", continues: "f")],
                         wires: [wire("f", "l")])
        _ = try lanes.validate()
    }

    @Test func messagesNameNodesByTitle() {
        let flow = Flow(name: "f", nodes: [prompt("a"), prompt("b")], wires: [])
        #expect(flow.message(for: .badSessionSource("b")) == "T-b can only continue the session of a Prompt that runs before it.")
        #expect(flow.message(for: .sessionScopeMismatch("b"))
                == "T-b and the step it continues have to run in the same worktree: both candidates, or neither.")
        #expect(flow.message(for: .sessionContinuedTwice("b")) == "Only one step can continue a given session.")
        #expect(FlowError.badSessionSource("b").errorDescription?.isEmpty == false)
    }

    @Test func sessionSourcesListsOnlyValidOnes() {
        // a -> b -> c -> d; c continues a. e is a sibling of nothing; f is the fan-out after d.
        let flow = Flow(name: "f", nodes: [
            prompt("a"), prompt("b"), prompt("c", continues: "a"), prompt("d"), prompt("e"),
            prompt("f", candidates: ["x", "y"]), prompt("l"),
            Node(id: "s", title: "S", kind: .shell(ShellConfig(command: "true")), position: Point(x: 0, y: 0)),
        ], wires: [wire("a", "b"), wire("b", "c"), wire("c", "d"), wire("d", "f"), wire("f", "l")])
        #expect(flow.sessionSources(for: "d") == ["b", "c"])         // a is taken by c
        #expect(flow.sessionSources(for: "c") == ["a", "b"])         // its own source stays listed
        #expect(flow.sessionSources(for: "a") == [])                 // nothing upstream
        #expect(flow.sessionSources(for: "e") == [])                 // unwired
        #expect(flow.sessionSources(for: "f") == [])                 // the fan-out is in the lanes, they are not
        #expect(flow.sessionSources(for: "l") == ["f"])              // same lane scope as the fan-out
        #expect(flow.sessionSources(for: "s") == [])                 // not a Prompt or Judge
        #expect(flow.sessionSources(for: "ghost") == [])
    }

    // MARK: File

    @Test func oldFlowFilesLoad() throws {
        let json = #"{"model":"sonnet","prompt":"go","candidates":[],"allowedTools":[]}"#
        let config = try JSONDecoder().decode(PromptConfig.self, from: Data(json.utf8))
        #expect(config.continuesSessionOf == nil)
    }

    @Test func unusedFieldIsNotWritten() throws {
        let config = PromptConfig(model: "sonnet", prompt: "go", candidates: [], allowedTools: [], maxTurns: nil)
        let text = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!text.contains("continuesSessionOf"))
    }

    @Test func roundTrips() throws {
        let repo = Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .exposed(default: nil))), position: Point(x: 0, y: 0))
        let flow = Flow(name: "f", nodes: [repo, prompt("a"), prompt("b", continues: "a")], wires: [wire("a", "b")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("continue-\(UUID().uuidString).flow")
        defer { try? FileManager.default.removeItem(at: url) }
        try FlowFile.save(flow, to: url)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("continuesSessionOf"))
        let loaded = try FlowFile.load(from: url)
        #expect(loaded == flow)
        #expect(loaded.node("b").flatMap { node -> NodeID? in
            if case .prompt(let c) = node.kind { return c.continuesSessionOf } else { return nil }
        } == "a")
        // A flow without the key stays free of it on disk.
        let plain = Flow(name: "p", nodes: [repo, prompt("a")], wires: [])
        try FlowFile.save(plain, to: url)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("continuesSessionOf"))
        #expect(try FlowFile.load(from: url) == plain)
    }

    // MARK: Engine

    private func result(_ session: String, _ text: String = "done", error: Bool = false) -> AgentResult {
        AgentResult(sessionID: session, text: text, isError: error, deniedTools: [], costUSD: 0, turns: 1)
    }

    private func repoNode() -> Node {
        Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 0, y: 0))
    }

    /// repo -> first -> second, where second continues first.
    private func chain(continues: NodeID? = "first") -> Flow {
        Flow(name: "chain", nodes: [
            repoNode(),
            Node(id: "first", title: "First", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "Write in {repo}", candidates: [], allowedTools: [], maxTurns: nil)),
                 position: Point(x: 1, y: 0)),
            Node(id: "second", title: "Second", kind: .prompt(PromptConfig(
                model: "opus", prompt: "Polish {code}", candidates: [], allowedTools: [], maxTurns: nil,
                continuesSessionOf: continues)), position: Point(x: 2, y: 0)),
        ], wires: [Wire(from: "repo", to: "first", input: "repo"), Wire(from: "first", to: "second", input: "code")])
    }

    @Test func continuesTheSourcesSessionWithItsOwnPrompt() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Write in") }, events: [.started(sessionID: "s1"), .finished(result("s1", "draft"))])
        h.agent.script({ $0.prompt.hasPrefix("Polish") }, events: [.started(sessionID: "s1"), .finished(result("s1", "polished"))])
        let id = try await h.engine.launch(flow: chain(), location: h.repoLocation, values: ["repo": h.repo.url.path])
        let run = await h.settled(id)
        #expect(run.status == .completed)
        let second = try #require(h.agent.requests.first { $0.prompt.hasPrefix("Polish") })
        #expect(second.resumeSessionID == "s1")
        #expect(second.prompt == "Polish draft")
        #expect(second.model == "opus")
        #expect(h.agent.requests.first { $0.prompt.hasPrefix("Write in") }?.resumeSessionID == nil)
    }

    @Test func laneContinuesItsOwnLanesSession() async throws {
        let h = try Harness()
        let flow = Flow(name: "lanes", nodes: [
            repoNode(),
            Node(id: "fan", title: "Fan", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "Write in {repo}", candidates: ["sonnet", "opus"], allowedTools: [], maxTurns: nil)),
                 position: Point(x: 1, y: 0)),
            Node(id: "step", title: "Step", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "Polish {code}", candidates: [], allowedTools: [], maxTurns: nil,
                continuesSessionOf: "fan")), position: Point(x: 2, y: 0)),
        ], wires: [Wire(from: "repo", to: "fan", input: "repo"), Wire(from: "fan", to: "step", input: "code")])
        for lane in ["a", "b"] {
            h.agent.script({ $0.prompt.hasPrefix("Write in") && $0.workingDirectory.lastPathComponent == lane },
                           events: [.started(sessionID: "s-\(lane)"), .finished(result("s-\(lane)", "draft \(lane)"))])
            h.agent.script({ $0.prompt.hasPrefix("Polish") && $0.workingDirectory.lastPathComponent == lane },
                           events: [.started(sessionID: "s-\(lane)"), .finished(result("s-\(lane)"))])
        }
        let id = try await h.engine.launch(flow: flow, location: h.repoLocation, values: ["repo": h.repo.url.path])
        _ = await h.settled(id)
        for lane in ["a", "b"] {
            let request = try #require(h.agent.requests.first {
                $0.prompt.hasPrefix("Polish") && $0.workingDirectory.lastPathComponent == lane })
            #expect(request.resumeSessionID == "s-\(lane)")
            #expect(request.prompt == "Polish draft \(lane)")
        }
    }

    @Test func retryContinuesAgain() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Write in") }, events: [.started(sessionID: "s1"), .finished(result("s1", "draft"))])
        h.agent.script({ $0.prompt.hasPrefix("Polish") }, events: [.started(sessionID: "s2"), .finished(result("s2", "boom", error: true))])
        let id = try await h.engine.launch(flow: chain(), location: h.repoLocation, values: ["repo": h.repo.url.path])
        let first = await h.settled(id)
        #expect(first.nodes[NodeKey(node: "second")]?.state == .failed("boom"))
        h.agent.script({ $0.prompt.hasPrefix("Polish") }, events: [.started(sessionID: "s1"), .finished(result("s1", "fine"))])
        try await h.engine.retry(id, node: NodeKey(node: "second"))
        let run = await h.settled(id)
        #expect(run.nodes[NodeKey(node: "second")]?.state == .succeeded)
        let polishes = h.agent.requests.filter { $0.prompt.hasPrefix("Polish") }
        #expect(polishes.count == 2)
        #expect(polishes.map(\.resumeSessionID) == ["s1", "s1"])
        #expect(polishes.map(\.prompt) == ["Polish draft", "Polish draft"])
    }

    @Test func ownReplyWinsOverSource() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Write in") }, events: [.started(sessionID: "s1"), .finished(result("s1", "draft"))])
        h.agent.script({ $0.prompt.hasPrefix("Polish") },
                       events: [.started(sessionID: "s2"), .finished(result("s2", "hm\nQUESTION: Which?"))])
        let id = try await h.engine.launch(flow: chain(), location: h.repoLocation, values: ["repo": h.repo.url.path])
        let paused = await h.settled(id)
        let key = NodeKey(node: "second")
        #expect(paused.nodes[key]?.state == .needsYou(.question("Which?")))
        h.agent.script({ $0.prompt == "This one" }, events: [.started(sessionID: "s2"), .finished(result("s2", "ok"))])
        try await h.engine.answer(id, node: key, reply: "This one")
        let run = await h.settled(id)
        #expect(run.nodes[key]?.state == .succeeded)
        let reply = try #require(h.agent.requests.first { $0.prompt == "This one" })
        #expect(reply.resumeSessionID == "s2")
    }

    @Test func missingSessionStartsFresh() async throws {
        let h = try Harness()
        // The source finishes without ever announcing a session.
        h.agent.script({ $0.prompt.hasPrefix("Write in") }, events: [.finished(result("", "draft"))])
        h.agent.script({ $0.prompt.hasPrefix("Polish") }, events: [.started(sessionID: "s2"), .finished(result("s2", "fine"))])
        let id = try await h.engine.launch(flow: chain(), location: h.repoLocation, values: ["repo": h.repo.url.path])
        let run = await h.settled(id)
        #expect(run.nodes[NodeKey(node: "first")]?.sessionID == nil)
        let second = try #require(h.agent.requests.first { $0.prompt.hasPrefix("Polish") })
        #expect(second.resumeSessionID == nil)
        #expect(second.prompt == "Polish draft")
        #expect(run.nodes[NodeKey(node: "second")]?.log.contains("⚠ no session to continue; starting fresh") == true)
    }

    @Test func reviewNeverContinuesEvenIfInvalid() async throws {
        // validate() refuses this flow, so the engine never runs it; the sources list is empty for a Review too.
        var review = ReviewConfig()
        review.agent.continuesSessionOf = "f"
        let flow = Flow(name: "f", nodes: [prompt("f", candidates: ["x", "y"]),
                                           Node(id: "r", title: "R", kind: .review(review), position: Point(x: 0, y: 0))],
                        wires: [wire("f", "r")])
        #expect(flow.sessionSources(for: "r") == [])
    }
}
