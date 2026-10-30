import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunEngineDecideTests {
    typealias Harness = RunEngineTests.Harness

    func pausedOnQuestion(_ h: Harness, denied: [String] = []) async throws -> RunID {
        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == "b" },
                       events: [.started(sessionID: "sb"), .finished(AgentResult(
                        sessionID: "sb", text: denied.isEmpty ? "hmm\nQUESTION: Keep the API?" : "need tools",
                        isError: false, deniedTools: denied, costUSD: 0, turns: 1))])
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        _ = await h.settled(id)
        return id
    }

    func resumeScript(_ h: Harness) {
        h.agent.script({ $0.resumeSessionID == "sb" }, effect: { r in
            try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        }, events: [.started(sessionID: "sb"), .finished(AgentResult(
            sessionID: "sb", text: "done", isError: false, deniedTools: [], costUSD: 0, turns: 1))])
    }

    func picked(_ h: Harness) async throws -> RunID {
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        _ = await h.settled(id)
        return id
    }

    @Test func answerResumesSameSession() async throws {
        let h = try Harness()
        let id = try await pausedOnQuestion(h)
        resumeScript(h)
        let key = NodeKey(node: "implement", lane: "b")
        try await h.engine.answer(id, node: key, reply: "Yes")
        let run = await h.settled(id)
        let resumed = h.agent.requests.filter { $0.resumeSessionID == "sb" }
        #expect(resumed.count == 1)
        #expect(resumed.first?.prompt == "Yes")
        #expect(run.status == .needsYou)
        #expect(run.nodes[key]?.state == .succeeded)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
    }

    @Test func deniedToolsAnswerAddsTools() async throws {
        let h = try Harness()
        let id = try await pausedOnQuestion(h, denied: ["Bash(make:*)"])
        resumeScript(h)
        let key = NodeKey(node: "implement", lane: "b")
        #expect(await h.engine.run(id)?.nodes[key]?.state == .needsYou(.deniedTools(["Bash(make:*)"])))
        try await h.engine.answer(id, node: key, reply: "ok", allowTools: ["Bash(make:*)", "Bash(make:*)"])
        _ = await h.settled(id)
        let resumed = h.agent.requests.first { $0.resumeSessionID == "sb" }
        #expect(resumed?.allowedTools.contains("Bash(make:*)") == true)
        #expect(await h.engine.run(id)?.nodes[key]?.extraAllowedTools == ["Bash(make:*)"])
    }

    @Test func answerRejectsWrongNode() async throws {
        let h = try Harness()
        let id = try await pausedOnQuestion(h)
        await #expect(throws: RunEngineError.notAnswerable(NodeKey(node: "plan"))) {
            try await h.engine.answer(id, node: NodeKey(node: "plan"), reply: "x")
        }
        await #expect(throws: RunEngineError.unknownRun(RunID(rawValue: "nope"))) {
            try await h.engine.answer(RunID(rawValue: "nope"), node: NodeKey(node: "plan"), reply: "x")
        }
    }

    @Test func pickMergesAndCleansUp() async throws {
        let h = try Harness()
        let id = try await picked(h)
        let run = try #require(await h.engine.run(id))
        let laneB = try #require(run.lanes.first { $0.id == "b" })
        let head = try h.repo.git(["rev-parse", laneB.branch]).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected merged, got \(result)"); return }
        let final = try #require(await h.engine.run(id))
        #expect(final.status == .merged("b"))
        #expect(final.nodes[NodeKey(node: "pick")]?.state == .succeeded)
        let parents = try h.repo.git(["log", "-1", "--format=%P", "main"])
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        #expect(parents.count == 2)
        #expect(parents.last == head)
        #expect(try h.repo.git(["branch", "--list", "flow/*"]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.store.worktreesDirectory.appendingPathComponent(id.rawValue).path))
        #expect(FileManager.default.fileExists(atPath: h.repo.url.appendingPathComponent("ok.txt").path))
        #expect(try h.repo.git(["worktree", "list"]).split(separator: "\n").count == 1)
    }

    @Test func pickBlockedWhenBaseCheckoutDirty() async throws {
        let h = try Harness()
        let id = try await picked(h)
        let before = try h.repo.git(["rev-parse", "main"])
        try h.repo.write("scratch.txt", "mine")
        let result = try await h.engine.pick(id, lane: "b")
        #expect(result == .blockedDirty(checkout: h.repo.url))
        #expect(try h.repo.git(["rev-parse", "main"]) == before)
        let run = try #require(await h.engine.run(id))
        #expect(run.status == .needsYou)
        for lane in run.lanes { #expect(FileManager.default.fileExists(atPath: lane.worktree.path)) }
    }

    @Test func pickConflictAborts() async throws {
        let h = try Harness()
        let id = try await picked(h)
        try h.repo.write("ok.txt", "different")
        try h.repo.commit("user change")
        let before = try h.repo.git(["rev-parse", "main"])
        let result = try await h.engine.pick(id, lane: "b")
        #expect(result == .conflict(files: ["ok.txt"]))
        #expect(try h.repo.git(["rev-parse", "main"]) == before)
        #expect(try h.repo.gitStatus(["status", "--porcelain"]).out.isEmpty)
        #expect(try h.repo.gitStatus(["rev-parse", "-q", "--verify", "MERGE_HEAD"]).exit != 0)
        #expect(await h.engine.run(id)?.status == .needsYou)
    }

    @Test func pickRejectsUnknownLaneAndWrongState() async throws {
        let h = try Harness()
        let id = try await picked(h)
        await #expect(throws: RunEngineError.notPickable) { _ = try await h.engine.pick(id, lane: "zz") }
        _ = try await h.engine.pick(id, lane: "a")
        await #expect(throws: RunEngineError.notPickable) { _ = try await h.engine.pick(id, lane: "b") }
    }

    @Test func resumeInterruptedSkipsFinishedNodes() async throws {
        let h = try Harness()
        let id = try await picked(h)
        var run = try #require(await h.engine.run(id))
        let key = NodeKey(node: "implement", lane: "a")
        run.nodes[key]?.state = .interrupted
        run.nodes[key]?.sessionID = "sa"
        run.nodes[NodeKey(node: "gate", lane: "a")] = nil
        run.nodes[NodeKey(node: "judge")] = nil
        run.nodes[NodeKey(node: "pick")] = nil
        run.status = .needsYou
        run.recommendation = nil
        try h.store.save(run)

        let runner = RoutingRunner(gh: h.gh)
        let engine = RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
        _ = try await engine.restore()
        let before = h.agent.requests.count
        h.agent.script({ $0.resumeSessionID == "sa" }, events: [.started(sessionID: "sa"), .finished(AgentResult(
            sessionID: "sa", text: "done", isError: false, deniedTools: [], costUSD: 0, turns: 1))])
        try await engine.resumeInterrupted(id)
        for await r in engine.updates where r.id == id && r.status != .running { break }
        let new = Array(h.agent.requests.dropFirst(before))
        #expect(!new.contains { $0.prompt.contains("short numbered plan") })
        let implement = new.filter { $0.prompt.contains("Fix this GitHub issue") || $0.resumeSessionID != nil }
        #expect(implement.count == 1)
        #expect(implement.first?.resumeSessionID == "sa")
        #expect(implement.first?.prompt == "Continue where you left off.")
        await #expect(throws: RunEngineError.self) { try await engine.resumeInterrupted(id) }
    }

    @Test func branchFromHereSurvivesDiscard() async throws {
        let h = try Harness()
        let id = try await picked(h)
        try await h.engine.branchFromHere(id, lane: "c", name: "try-c")
        let run = try #require(await h.engine.run(id))
        let laneC = try #require(run.lanes.first { $0.id == "c" })
        #expect(try h.repo.git(["rev-parse", "try-c"]) == (try h.repo.git(["rev-parse", laneC.branch])))
        try await h.engine.discard(id)
        let branches = try h.repo.git(["branch", "--format=%(refname:short)"]).split(separator: "\n").map(String.init)
        #expect(branches.contains("try-c"))
        #expect(!branches.contains { $0.hasPrefix("flow/") })
        #expect(await h.engine.run(id)?.status == .discarded)
        #expect(!FileManager.default.fileExists(atPath: h.store.worktreesDirectory.appendingPathComponent(id.rawValue).path))
        await #expect(throws: RunEngineError.notBranchable) {
            try await h.engine.branchFromHere(id, lane: "c", name: "again")
        }
    }

    @Test func discardWhileRunningThrows() async throws {
        let (hold, cont) = AsyncStream<Void>.makeStream()
        defer { cont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        await #expect(throws: RunEngineError.notDiscardable) { try await h.engine.discard(id) }
        await h.engine.cancel(id)
        try await h.engine.discard(id)
        #expect(await h.engine.run(id)?.status == .discarded)
    }
}
