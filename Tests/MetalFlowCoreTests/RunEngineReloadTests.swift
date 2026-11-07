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
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
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

    @Test func discoverFindsRunSavedByAnotherStore() async throws {
        let h = try Harness()
        let theirs = RunStore(root: h.store.root)
        let run = Run(flow: h.flow(), title: "from mflow", repo: h.repo.url, baseBranch: "main", branch: "mf/x",
                      worktree: h.repo.url, createdAt: Date(timeIntervalSince1970: 5), status: .running, nodes: [:])
        try theirs.save(run)
        let found = await h.engine.discover().found
        #expect(found.map(\.id) == [run.id])
        #expect(await h.engine.run(run.id)?.title == "from mflow")
        #expect(store(h).isLocked(run.id) == false, "discovering takes no lock")
    }

    @Test func discoverTakesANewerSavedStateOfAKnownRun() async throws {
        let h = try Harness()
        let theirs = RunStore(root: h.store.root)
        var run = Run(flow: h.flow(), title: "before", repo: h.repo.url, baseBranch: "main", branch: "mf/y",
                      worktree: h.repo.url, createdAt: Date(timeIntervalSince1970: 5), status: .needsYou, nodes: [:])
        try theirs.save(run)
        _ = await h.engine.discover()
        // Another process follows up on the run and saves a newer state.
        run.title = "after"
        run.revision += 3
        try theirs.save(run)
        let found = await h.engine.discover().found
        #expect(found.map(\.title) == ["after"])
        #expect(await h.engine.run(run.id)?.title == "after")
    }

    @Test func discoverIgnoresKnownRuns() async throws {
        let (hold, cont) = AsyncStream<Void>.makeStream()
        defer { cont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await heldRun(h)
        let mine = try #require(await h.engine.run(id))
        var other = mine
        other.revision += 9
        other.title = "from disk"
        try h.store.save(other)
        #expect(await h.engine.discover() == .init())
        #expect(await h.engine.run(id)?.title == mine.title)
    }

    @Test func discoverSkipsUnreadableFile() async throws {
        let h = try Harness()
        let id = RunID()
        let dir = h.store.root.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id.rawValue).json")
        try "{ half".write(to: file, atomically: true, encoding: .utf8)
        #expect(await h.engine.discover().found.isEmpty)
        #expect(await h.engine.run(id) == nil)
        // Once the file is whole, a later pass finds it.
        let run = Run(id: id, flow: h.flow(), title: "late", repo: h.repo.url, baseBranch: "main", branch: "mf/y",
                      worktree: h.repo.url, createdAt: Date(timeIntervalSince1970: 6), status: .running, nodes: [:])
        try h.store.save(run)
        #expect(await h.engine.discover().found.map(\.id) == [id])
    }

    @Test func discoverReportsDeletedRun() async throws {
        let h = try Harness()
        let theirs = RunStore(root: h.store.root)
        let run = Run(flow: h.flow(), title: "from mflow", repo: h.repo.url, baseBranch: "main", branch: "mf/x",
                      worktree: h.repo.url, createdAt: Date(timeIntervalSince1970: 5), status: .completed, nodes: [:])
        try theirs.save(run)
        #expect(await h.engine.discover().found.map(\.id) == [run.id])
        try theirs.delete(run.id)
        let again = await h.engine.discover()
        #expect(again.vanished == [run.id])
        #expect(again.found.isEmpty)
        #expect(await h.engine.run(run.id) == nil, "dropped from the cache")
        #expect(await h.engine.discover() == .init(), "reported once")
    }

    @Test func discoverKeepsHeldRunWhoseFileVanished() async throws {
        let (hold, cont) = AsyncStream<Void>.makeStream()
        defer { cont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await heldRun(h)
        try h.store.delete(id)
        #expect(await h.engine.discover() == .init())
        #expect(await h.engine.run(id) != nil)
    }

    private func store(_ h: Harness) -> RunStore { h.store }
}
