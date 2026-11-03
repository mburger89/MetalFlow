import Foundation
import Testing
import os
@testable import MetalFlowCore

/// Gaps found after the follow-up work: later steps failing, commits, lost sessions, refusals.
@Suite struct RunEngineGapsTests {
    typealias Harness = RunEngineTests.Harness

    private let implementA = NodeKey(node: "implement", lane: "a")
    private let judge = NodeKey(node: "judge")
    private let pick = NodeKey(node: "pick")
    private let notes = NodeKey(node: "notes")

    private func finished(_ session: String, _ text: String, isError: Bool = false) -> [AgentEvent] {
        [.started(sessionID: session), .finished(AgentResult(
            sessionID: session, text: text, isError: isError, deniedTools: [], costUSD: 0, turns: 1))]
    }

    /// The fix-issue flow with a Prompt after the judge that does not feed the pick.
    private func notesFlow(_ h: Harness) -> Flow {
        var flow = h.flow()
        flow.nodes.insert(Node(id: "notes", title: "Notes", kind: .prompt(PromptConfig(
            model: "sonnet", prompt: "Summarize {rec}", candidates: [], allowedTools: [], maxTurns: nil)),
                               position: Point(x: 0, y: 0)), at: flow.nodes.firstIndex { $0.id == "pick" }!)
        flow.wires.append(Wire(from: "judge", to: "notes", input: "rec"))
        return flow
    }

    private func atPick(_ h: Harness, flow: Flow? = nil) async throws -> RunID {
        let id = try await h.engine.launch(flow: flow ?? h.flow(), location: .builtin,
                                           values: ["issue": "7", "repo": h.repo.url.path])
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        return id
    }

    @discardableResult
    private func waitFor(_ h: Harness, _ id: RunID, _ what: String, _ done: (Run) -> Bool) async -> Run {
        await waitUntil(what) { await h.engine.run(id).map(done) ?? false }
        return await h.engine.run(id)!
    }

    private func pickIsOffered(_ run: Run) -> Bool {
        run.status == .needsYou && run.nodes[pick]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false))
    }

    // MARK: - 1. A later step failing after a good follow-up

    @Test func laterStepFailingAfterAJudgeFollowUpStillOffersThePick() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        let id = try await atPick(h, flow: notesFlow(h))
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "limit", isError: true))
        h.agent.script({ $0.prompt == "Explain" }, events: finished("sj", "Because.\nRECOMMEND: b"))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        let run = await waitFor(h, id, "the pick to be offered") { self.pickIsOffered($0) && $0.nodes[self.notes]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        #expect(run.pickToRestore == nil)
        #expect(run.nodes[judge]?.state == .succeeded)

        // The failed step's Retry is accepted before the pick (it does not rerun the step while the pick is on offer:
        // see the report), and the pick still works.
        try await h.engine.retry(id, node: notes)
        await h.engine.waitForPass(id)
        let retried = try #require(await h.engine.run(id))
        #expect(pickIsOffered(retried))
        #expect(retried.pickToRestore == nil)
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
    }

    @Test func laterStepQuestionThenFailureStillOffersThePick() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        let id = try await atPick(h, flow: notesFlow(h))
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "hmm\nQUESTION: Which part?"))
        h.agent.script({ $0.prompt == "Explain" }, events: finished("sj", "Because.\nRECOMMEND: b"))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        let asked = await waitFor(h, id, "the question") {
            $0.status == .needsYou && $0.nodes[self.notes]?.state == .needsYou(.question("Which part?")) }
        await h.engine.waitForPass(id)
        #expect(asked.pickToRestore == judge, "a parked later step leaves the pick to restore set")
        #expect(asked.nodes[pick]?.state == .waiting)

        h.agent.script({ $0.prompt == "The intro" }, events: finished("sn", "limit", isError: true))
        try await h.engine.answer(id, node: notes, reply: "The intro")
        let run = await waitFor(h, id, "the pick to be offered") { self.pickIsOffered($0) && $0.nodes[self.notes]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        #expect(run.pickToRestore == nil)
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
    }

    @Test func cleanFollowUpClearsPickToRestore() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        let id = try await atPick(h, flow: notesFlow(h))
        h.agent.script({ $0.prompt == "Explain" }, events: finished("sj", "Because.\nRECOMMEND: b"))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        let run = await waitFor(h, id, "the pick to be offered") { self.pickIsOffered($0) && $0.nodes[self.notes]?.state == .succeeded }
        await h.engine.waitForPass(id)
        #expect(run.pickToRestore == nil)
        #expect(run.nodes.values.allSatisfy { !$0.state.isFailed })
    }

    // MARK: - 2. A commit failure keeps the follow-up's message

    private func addsAFile(_ r: AgentRequest) throws {
        try "x".write(to: r.workingDirectory.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
    }

    @Test func failedCommitRetriesWithTheSameSessionAndMessage() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let session = try #require(await h.engine.run(id)?.nodes[implementA]?.sessionID)
        let failing = OSAllocatedUnfairLock(initialState: true)
        let real = ProcessRunner(resolver: ExecutableResolver(searchPath: ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin"]))
        h.hooks.override({ $0.executable == "git" && CommandHooks.gitArguments($0).first == "commit"
            && $0.arguments.contains { $0.hasSuffix("/a") } }) { c in
            if failing.withLock({ $0 }) { return CommandResult(exitCode: 1, stdout: "", stderr: "hook said no") }
            return try await real.run(c)
        }
        h.agent.script({ $0.prompt == "Add a file" }, effect: { try self.addsAFile($0) }, events: finished(session, "added"))
        try await h.engine.followUp(id, node: implementA, message: "Add a file")
        let failed = await waitFor(h, id, "the commit to fail") { $0.nodes[self.implementA]?.state.isFailed == true
            && $0.nodes[self.pick]?.state != .running }
        await h.engine.waitForPass(id)
        #expect(failed.nodes[implementA]?.pendingReply == "Add a file")
        #expect(failed.nodes[implementA]?.replyInFlight == nil)

        failing.withLock { $0 = false }
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: implementA)
        let run = await waitFor(h, id, "the retry to finish") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.state == .succeeded }
        let sent = h.agent.requests.dropFirst(before).filter { $0.workingDirectory.lastPathComponent == "a" }
        #expect(sent.count == 1)
        #expect(sent.first?.prompt == "Add a file")
        #expect(sent.first?.resumeSessionID == session)
        #expect(run.nodes[implementA]?.pendingReply == nil && run.nodes[implementA]?.replyInFlight == nil)
    }

    @Test func cleanCommitClearsTheReply() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let session = try #require(await h.engine.run(id)?.nodes[implementA]?.sessionID)
        h.agent.script({ $0.prompt == "Add a file" }, effect: { try self.addsAFile($0) }, events: finished(session, "added"))
        try await h.engine.followUp(id, node: implementA, message: "Add a file")
        let run = await waitFor(h, id, "the pick") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.output == "added" }
        await h.engine.waitForPass(id)
        #expect(run.nodes[implementA]?.pendingReply == nil && run.nodes[implementA]?.replyInFlight == nil)
    }
}
