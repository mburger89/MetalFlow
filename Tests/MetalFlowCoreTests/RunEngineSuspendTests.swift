import Foundation
import Testing
@testable import MetalFlowCore

/// Suspending runs for quit: stopped like a cancel, but left resumable.
@Suite struct RunEngineSuspendTests {
    typealias Harness = RunEngineTests.Harness

    private func startPlan(_ h: Harness) async throws -> RunID {
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        for await run in h.engine.updates where run.id == id && run.nodes[NodeKey(node: "plan")]?.state == .running { break }
        return id
    }

    @Test func suspendLeavesRunResumable() async throws {
        let (hold, holdCont) = AsyncStream<Void>.makeStream()
        defer { holdCont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await startPlan(h)
        await h.engine.suspend(id)
        let run = await h.engine.run(id)
        #expect(run?.status == .needsYou)
        #expect(run?.nodes[NodeKey(node: "plan")]?.state == .interrupted)
        #expect(h.store.load(id)?.status == .needsYou)
        await h.engine.waitForPass(id)
        #expect(await h.engine.tasks[id] == nil)
        #expect(await h.engine.locks[id] == nil)

        holdCont.finish()
        try await h.engine.resumeInterrupted(id)
        var final: Run?
        for await r in h.engine.updates where r.id == id && r.nodes[NodeKey(node: "pick")]?.state != nil
            && r.status == .needsYou { final = r; break }
        #expect(final?.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
        #expect(final?.nodes[NodeKey(node: "plan")]?.state == .succeeded)
    }

    @Test func suspendedPassCannotOverwrite() async throws {
        let (hold, holdCont) = AsyncStream<Void>.makeStream()
        defer { holdCont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await startPlan(h)
        await h.engine.suspend(id)
        // Let the cancelled pass wind down: it must not rewrite the node or the status.
        await h.engine.waitForPass(id)
        let run = await h.engine.run(id)
        #expect(run?.status == .needsYou)
        #expect(run?.nodes[NodeKey(node: "plan")]?.state == .interrupted)
        #expect(h.store.load(id)?.nodes[NodeKey(node: "plan")]?.state == .interrupted)
    }

    @Test func suspendOnSettledRunIsNoOp() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        let run = await h.settled(id)
        await h.engine.waitForPass(id)
        await h.engine.suspend(id)
        #expect(await h.engine.run(id)?.revision == run.revision)
    }

    // MARK: - Follow-ups

    /// Puts the engine in the state "suspended, old pass still winding down" without racing the real pass.
    private func windDown(_ h: Harness, _ id: RunID) async -> AsyncStream<Void>.Continuation {
        let (stream, cont) = AsyncStream<Void>.makeStream()
        await h.engine.simulateWindDown(id, hold: stream)
        return cont
    }

    private func suspendedRun(_ h: Harness) async throws -> RunID {
        let id = try await startPlan(h)
        await h.engine.suspend(id)
        await h.engine.waitForPass(id)
        return id
    }

    @Test func resumeWhileOldPassWindsDownThrowsRunBusy() async throws {
        let (hold, holdCont) = AsyncStream<Void>.makeStream()
        defer { holdCont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await suspendedRun(h)
        let release = await windDown(h, id)
        defer { release.finish() }
        await #expect(throws: RunEngineError.runBusy(id)) { try await h.engine.resumeInterrupted(id) }
        let key = NodeKey(node: "plan")
        await #expect(throws: RunEngineError.runBusy(id)) { try await h.engine.answer(id, node: key, reply: "go") }
        #expect(await h.engine.suspended.contains(id), "still suspended: the old pass's writes stay ignored")
        #expect(await h.engine.run(id)?.nodes[key]?.state == .interrupted)
        // Once the old pass is gone, resume works.
        release.finish()
        await h.engine.waitForPass(id)
        await h.engine.endWindDown(id)
        holdCont.finish()
        try await h.engine.resumeInterrupted(id)
        #expect(await h.engine.run(id)?.status == .running)
    }

    @Test func retryClearsSuspension() async throws {
        let (hold, holdCont) = AsyncStream<Void>.makeStream()
        defer { holdCont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await suspendedRun(h)
        let key = NodeKey(node: "plan")
        await h.engine.setDirect(id) { $0.nodes[key]?.state = .failed("x") }
        holdCont.finish()
        try await h.engine.retry(id, node: key)
        #expect(await h.engine.suspended.contains(id) == false)
        #expect(await h.engine.run(id)?.status == .running, "mutate was not a silent no-op")
    }

    @Test func retryWhileOldPassWindsDownThrowsRunBusy() async throws {
        let (hold, holdCont) = AsyncStream<Void>.makeStream()
        defer { holdCont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await suspendedRun(h)
        let key = NodeKey(node: "plan")
        await h.engine.setDirect(id) { $0.nodes[key]?.state = .failed("x") }
        let release = await windDown(h, id)
        defer { release.finish() }
        await #expect(throws: RunEngineError.runBusy(id)) { try await h.engine.retry(id, node: key) }
    }

    @Test func ensureLanesDoesNotWriteWhileSuspended() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        let settled = await h.settled(id)
        await h.engine.waitForPass(id)
        await h.engine.setDirect(id) { $0.lanes = [] }
        let before = try #require(await h.engine.run(id))
        await h.engine.markSuspended(id)
        let plan = try before.flow.validate()
        try await h.engine.ensureLanes(id, plan: plan)
        let after = try #require(await h.engine.run(id))
        #expect(after.lanes.isEmpty)
        #expect(after.revision == before.revision)
        #expect(h.store.load(id)?.revision == before.revision)
        _ = settled
    }
}

extension RunEngine {
    /// Test seam: the run is suspended and its old pass is still alive until `hold` ends.
    func simulateWindDown(_ id: RunID, hold: AsyncStream<Void>) {
        suspended.insert(id)
        tasks[id] = Task { for await _ in hold {} }
    }
    /// Test seam: the old pass has ended.
    func endWindDown(_ id: RunID) { tasks[id] = nil }
    func markSuspended(_ id: RunID) { suspended.insert(id) }
}
