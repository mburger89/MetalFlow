import Foundation
import Testing
@testable import MetalFlowCore

/// Run locks, branch-name validation, shell quoting and restore-time cleanup.
@Suite struct RunEngineSafetyTests {
    typealias Harness = RunEngineTests.Harness

    private func secondEngine(_ h: Harness) -> RunEngine {
        let runner = RoutingRunner(gh: h.gh)
        return RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
    }

    @Test func secondEngineCannotDriveALockedRun() async throws {
        let (hold, holdCont) = AsyncStream<Void>.makeStream()
        defer { holdCont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        for await run in h.engine.updates where run.id == id && run.nodes[NodeKey(node: "plan")]?.state == .running { break }

        let other = secondEngine(h)
        let restored = try await other.restore()
        // The run is driven elsewhere: its saved state is shown as saved, not as interrupted.
        #expect(restored.first { $0.id == id }?.status == .running)
        #expect(restored.first { $0.id == id }?.nodes[NodeKey(node: "plan")]?.state == .running)
        #expect(await other.isRunningElsewhere(id))
        #expect(await h.engine.isRunningElsewhere(id) == false)
        await #expect(throws: RunEngineError.runBusy(id)) { try await other.resumeInterrupted(id) }
        await #expect(throws: RunEngineError.runBusy(id)) { try await other.discard(id) }
        await #expect(throws: RunEngineError.runBusy(id)) { try await other.pick(id, lane: "a") }
        await #expect(throws: RunEngineError.runBusy(id)) { try await other.branchFromHere(id, lane: "a", name: "keep-me") }
        await other.cancel(id)
        #expect(await other.run(id)?.status == .running)

        holdCont.finish()
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        #expect(await other.isRunningElsewhere(id) == false)
        // The lock is free again, so the second engine may reload the run and act on it.
        _ = try await other.restore()
        #expect(await other.run(id)?.status == .needsYou)
        try await other.discard(id)
        #expect(await other.run(id)?.status == .discarded)
    }

    @Test func invalidBranchNamesAreRejected() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        _ = await h.settled(id)
        for name in ["-bad", "a b", "x..y", "", "@{-1}", "end/"] {
            await #expect(throws: RunEngineError.invalidBranchName(name)) {
                try await h.engine.branchFromHere(id, lane: "a", name: name)
            }
        }
        try await h.engine.branchFromHere(id, lane: "a", name: "keep/good-name")
        #expect(try h.repo.git(["branch", "--list", "keep/good-name"]).contains("keep/good-name"))
    }

    @Test func placeholderValuesCannotInjectShellCommands() async throws {
        let h = try Harness()
        let flow = Flow(name: "quote", nodes: [
            Node(id: "issue", title: "Issue", kind: .flowInput(FlowInputConfig(name: "issue", source: .text)), position: Point(x: 0, y: 0)),
            Node(id: "show", title: "Show", kind: .shell(ShellConfig(command: "echo {issue}")), position: Point(x: 1, y: 0)),
        ], wires: [Wire(from: "issue", to: "show", input: "issue")])
        let text = "$(touch pwned) it's `touch pwned2`"
        let id = try await h.engine.launch(flow: flow, repo: h.repo.url, input: text)
        let run = await h.settled(id)
        #expect(run.status == .completed)
        #expect(run.nodes[NodeKey(node: "show")]?.output?.contains(text) == true)
        #expect(!FileManager.default.fileExists(atPath: run.worktree.appendingPathComponent("pwned").path))
        #expect(!FileManager.default.fileExists(atPath: run.worktree.appendingPathComponent("pwned2").path))
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(Template.shellQuote("a'b") == "'a'\\''b'")
        #expect(Template.shellQuote("") == "''")
    }

    @Test func restoreFinishesCleanupOfDiscardedRun() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        var run = await h.settled(id)
        await h.engine.waitForPass(id)
        let directory = h.store.worktreesDirectory.appendingPathComponent(id.rawValue)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        // The process died after marking the run discarded but before cleanup.
        run.status = .discarded
        try h.store.save(run)

        let engine = secondEngine(h)
        _ = try await engine.restore()
        await engine.waitForRestoreCleanups()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try h.repo.git(["branch", "--list", "flow/*"]).isEmpty)
    }
}
