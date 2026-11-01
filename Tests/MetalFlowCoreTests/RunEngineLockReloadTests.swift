import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunEngineLockReloadTests {
    typealias Harness = RunEngineTests.Harness

    @Test func lockAcquisitionReloadsRunFromDisk() async throws {
        let (hold, cont) = AsyncStream<Void>.makeStream()
        defer { cont.finish() }
        let h = try Harness(planHold: hold)
        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == "b" },
                       events: [.started(sessionID: "sb"), .finished(AgentResult(
                        sessionID: "sb", text: "QUESTION: Keep the API?", isError: false, deniedTools: [], costUSD: 0, turns: 1))])
        h.agent.script({ $0.resumeSessionID == "sb" }, effect: { r in
            try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        }, events: [.started(sessionID: "sb"), .finished(AgentResult(
            sessionID: "sb", text: "done", isError: false, deniedTools: [], costUSD: 0, turns: 1))])

        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        for await run in h.engine.updates where run.id == id && run.nodes[NodeKey(node: "plan")]?.state == .running { break }

        // Engine B restores while A holds the lock, so it sees plan still running.
        let runner = RoutingRunner(gh: h.gh)
        let b = RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
        _ = try await b.restore()
        #expect(await b.run(id)?.nodes[NodeKey(node: "plan")]?.state == .running)

        cont.yield()
        _ = await h.settled(id)
        await h.engine.waitForPass(id)

        let key = NodeKey(node: "implement", lane: "b")
        try await b.answer(id, node: key, reply: "Yes")
        var final: Run?
        for await run in b.updates where run.id == id && run.status != .running && run.nodes[key]?.state == .succeeded { final = run; break }
        #expect(final?.nodes[key]?.state == .succeeded)
        #expect(final?.nodes[NodeKey(node: "plan")]?.state == .succeeded)
        #expect(final?.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
    }

    @Test func flowsListsDotFlowsFiles() async throws {
        let h = try Harness()
        #expect(h.engine.flows(in: h.repo.url).isEmpty)
        let dir = h.repo.url.appendingPathComponent(".flows")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["b.flow", "a.flow", "notes.txt"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        #expect(h.engine.flows(in: h.repo.url).map(\.lastPathComponent) == ["a.flow", "b.flow"])
    }

    @Test func reloadDoesNotRollBackNewerMemory() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        let stored = try #require(h.store.load(id))
        // Memory is ahead of disk, as after a failed save.
        await h.engine.setDirect(id) { $0.title = "newer in memory" }
        var older = stored
        older.revision = (await h.engine.run(id)?.revision ?? 1) - 1
        try h.store.save(older)
        let engine = h.engine
        await engine.dropLockForTest(id)
        try await engine.ensureLock(id)
        #expect(await engine.run(id)?.title == "newer in memory")
        await engine.dropLockForTest(id)
    }
}

extension RunEngine {
    func dropLockForTest(_ id: RunID) { locks.removeValue(forKey: id)?.release() }
}
