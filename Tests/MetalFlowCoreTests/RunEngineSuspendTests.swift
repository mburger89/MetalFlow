import Foundation
import Testing
@testable import MetalFlowCore

/// Suspending runs for quit: stopped like a cancel, but left resumable.
@Suite struct RunEngineSuspendTests {
    typealias Harness = RunEngineTests.Harness

    private func startPlan(_ h: Harness) async throws -> RunID {
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
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
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        let run = await h.settled(id)
        await h.engine.waitForPass(id)
        await h.engine.suspend(id)
        #expect(await h.engine.run(id)?.revision == run.revision)
    }
}
