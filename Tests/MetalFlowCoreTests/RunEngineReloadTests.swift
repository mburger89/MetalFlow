import Foundation
import Testing
@testable import MetalFlowCore

/// `reload`: picking up another process's progress on a run this engine does not drive.
@Suite struct RunEngineReloadTests {
    typealias Harness = RunEngineTests.Harness

    private func secondEngine(_ h: Harness) -> RunEngine {
        let runner = RoutingRunner(gh: h.gh)
        return RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
    }

    /// Launches a run and holds it in its first node, so the first engine keeps the lock and the saved state.
    private func heldRun(_ h: Harness) async throws -> RunID {
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        for await run in h.engine.updates where run.id == id && run.nodes[NodeKey(node: "plan")]?.state == .running { break }
        return id
    }

    @Test func reloadReturnsWhatTheOtherProcessSaved() async throws {
        let (hold, cont) = AsyncStream<Void>.makeStream()
        defer { cont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await heldRun(h)

        let other = secondEngine(h)
        _ = try await other.restore()
        let seen = try #require(await other.run(id))
        // The driving process saves a newer state.
        var newer = try #require(h.store.load(id))
        newer.revision = seen.revision + 3
        newer.title = "moved on"
        try h.store.save(newer)

        let reloaded = await other.reload(id)
        #expect(reloaded?.title == "moved on")
        #expect(reloaded?.revision == seen.revision + 3)
        #expect(await other.run(id)?.title == "moved on", "the cache holds the newer state")
    }

    @Test func reloadKeepsAnOlderDiskStateOut() async throws {
        let (hold, cont) = AsyncStream<Void>.makeStream()
        defer { cont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await heldRun(h)
        let other = secondEngine(h)
        _ = try await other.restore()
        let seen = try #require(await other.run(id))
        var older = seen
        older.revision = max(0, seen.revision - 1)
        older.title = "older"
        try h.store.save(older)
        #expect(await other.reload(id) == seen)
    }

    @Test func reloadDoesNotOverwriteARunThisEngineHolds() async throws {
        let (hold, cont) = AsyncStream<Void>.makeStream()
        defer { cont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await heldRun(h)
        let mine = try #require(await h.engine.run(id))
        var other = mine
        other.revision = mine.revision + 5
        other.title = "from disk"
        try h.store.save(other)
        let reloaded = try #require(await h.engine.reload(id))
        #expect(reloaded.title == mine.title)
        #expect(reloaded.revision < other.revision)
    }

    @Test func reloadOfAnUnknownRunIsNil() async throws {
        let h = try Harness()
        #expect(await h.engine.reload(RunID()) == nil)
    }
}
