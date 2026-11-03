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

    // MARK: - 3. A lost session

    /// repo -> first -> second, where second continues first.
    private func chainFlow() -> Flow {
        Flow(name: "chain", nodes: [
            Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 0, y: 0)),
            Node(id: "first", title: "First", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "Write in {repo}", candidates: [], allowedTools: [], maxTurns: nil)),
                 position: Point(x: 1, y: 0)),
            Node(id: "second", title: "Second", kind: .prompt(PromptConfig(
                model: "opus", prompt: "Polish {code}", candidates: [], allowedTools: [], maxTurns: nil,
                continuesSessionOf: "first")), position: Point(x: 2, y: 0)),
        ], wires: [Wire(from: "repo", to: "first", input: "repo"), Wire(from: "first", to: "second", input: "code")])
    }

    private static let lostText = "No conversation found with session ID: 00000000-0000-4000-8000-000000000000"
    private func lostSession() -> [AgentEvent] {
        // The real CLI prints no init event, so the turn never reports a session.
        [.finished(AgentResult(sessionID: "00000000-0000-4000-8000-000000000000", text: Self.lostText, isError: true,
                               deniedTools: [], costUSD: 0, turns: 0, sessionLost: true))]
    }

    private static let lostMessage = "The agent's conversation can no longer be found. Retry starts this step again from its original prompt"

    @Test func lostSessionFailsReadablyThenRetriesFreshWithTheMessage() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let session = try #require(await h.engine.run(id)?.nodes[implementA]?.sessionID)
        h.agent.script({ $0.prompt == "Tweak" }, events: lostSession())
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        let failed = await waitFor(h, id, "the turn to fail") { $0.nodes[self.implementA]?.state.isFailed == true
            && $0.nodes[self.pick]?.state != .running }
        await h.engine.waitForPass(id)
        #expect(failed.nodes[implementA]?.state == .failed(Self.lostMessage + " and your message."))
        #expect(failed.nodes[implementA]?.sessionID == nil)
        #expect(failed.nodes[implementA]?.pendingReply == "Tweak")
        #expect(!failed.canFollowUp(implementA))
        #expect(session == "s")

        h.agent.script({ $0.prompt.hasSuffix("\n\nThe user's message about this step:\nTweak") },
                       events: finished("fresh", "tweaked"))
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: implementA)
        let run = await waitFor(h, id, "the retry to finish") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.state == .succeeded }
        let sent = h.agent.requests.dropFirst(before).filter { $0.workingDirectory.lastPathComponent == "a" }
        #expect(sent.count == 1)
        #expect(sent.first?.resumeSessionID == nil)
        #expect(sent.first?.prompt.contains("Fix this GitHub issue") == true)
        #expect(sent.first?.prompt.hasSuffix("\n\nThe user's message about this step:\nTweak") == true)
        #expect(run.nodes[implementA]?.sessionID == "fresh")
        #expect(run.nodes[implementA]?.pendingReply == nil && run.nodes[implementA]?.replyInFlight == nil)
    }

    @Test func lostSessionWithoutAMessageSaysNothingAboutOne() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Write in") }, events: finished("s1", "draft"))
        h.agent.script({ $0.prompt.hasPrefix("Polish") }, events: lostSession())
        let id = try await h.engine.launch(flow: chainFlow(), location: h.repoLocation, values: ["repo": h.repo.url.path])
        let run = await h.settled(id)
        #expect(run.nodes[NodeKey(node: "second")]?.state == .failed(Self.lostMessage + "."))
        #expect(run.nodes[NodeKey(node: "first")]?.sessionID == nil && run.nodes[NodeKey(node: "second")]?.sessionID == nil)
    }

    @Test func otherErrorsKeepTheSession() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        h.agent.script({ $0.prompt == "Tweak" }, events: finished("s", "usage limit", isError: true))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        let failed = await waitFor(h, id, "the turn to fail") { $0.nodes[self.implementA]?.state.isFailed == true
            && $0.nodes[self.pick]?.state != .running }
        await h.engine.waitForPass(id)
        #expect(failed.nodes[implementA]?.state == .failed("usage limit"))
        #expect(failed.nodes[implementA]?.sessionID == "s")
        #expect(failed.nodes[implementA]?.pendingReply == "Tweak")
    }

    @Test func lostSessionOnAContinuerClearsBothAndRetryStartsFresh() async throws {
        let h = try Harness()
        let flow = chainFlow()
        h.agent.script({ $0.prompt.hasPrefix("Write in") }, events: finished("s1", "draft"))
        h.agent.script({ $0.prompt.hasPrefix("Polish") }, events: finished("s1", "polished"))
        let id = try await h.engine.launch(flow: flow, location: h.repoLocation, values: ["repo": h.repo.url.path])
        let done = await h.settled(id)
        let first = NodeKey(node: "first"), second = NodeKey(node: "second")
        #expect(done.nodes[first]?.sessionID == "s1" && done.nodes[second]?.sessionID == "s1")

        h.agent.script({ $0.prompt == "Again" }, events: lostSession())
        try await h.engine.followUp(id, node: second, message: "Again")
        let failed = await waitFor(h, id, "the turn to fail") { $0.nodes[second]?.state.isFailed == true && $0.status != .running }
        #expect(failed.nodes[second]?.state == .failed(Self.lostMessage + " and your message."))
        #expect(failed.nodes[first]?.sessionID == nil && failed.nodes[second]?.sessionID == nil)

        h.agent.script({ $0.prompt.hasPrefix("Polish") }, events: finished("fresh", "polished again"))
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: second)
        let run = await waitFor(h, id, "the retry to finish") { $0.nodes[second]?.state == .succeeded && $0.status != .running }
        let sent = try #require(h.agent.requests.dropFirst(before).first)
        #expect(sent.resumeSessionID == nil)
        #expect(sent.prompt == "Polish draft\n\nThe user's message about this step:\nAgain")
        #expect(run.nodes[second]?.sessionID == "fresh")
    }

    // MARK: - 4. A rerun continuer is told it is a rerun

    private static let rerunPrefix = "This step already ran earlier in this conversation, and the work it builds on has changed since. Do it again for the work as it stands now, and keep what is still right.\n\n"

    private func chainDone(_ h: Harness) async throws -> RunID {
        h.agent.script({ $0.prompt.hasPrefix("Write in") }, events: finished("s1", "draft"))
        h.agent.script({ $0.prompt.contains("Polish") }, events: finished("s1", "polished"))
        let id = try await h.engine.launch(flow: chainFlow(), location: h.repoLocation, values: ["repo": h.repo.url.path])
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        return id
    }

    @Test func firstRunContinuerHasNoPrefix() async throws {
        let h = try Harness()
        let id = try await chainDone(h)
        let polish = try #require(h.agent.requests.first { $0.prompt.contains("Polish") })
        #expect(polish.prompt == "Polish draft")
        #expect(polish.resumeSessionID == "s1")
        #expect(await h.engine.run(id)?.nodes[NodeKey(node: "second")]?.rerunsInSession == false)
    }

    @Test func rerunContinuerIsToldItIsARerun() async throws {
        let h = try Harness()
        let id = try await chainDone(h)
        let second = NodeKey(node: "second")
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        h.agent.script({ $0.prompt == "Redo" }, hold: hold, events: finished("s1", "draft two"))
        try await h.engine.followUp(id, node: NodeKey(node: "first"), message: "Redo")
        let held = await waitFor(h, id, "first running") { $0.nodes[NodeKey(node: "first")]?.state == .running }
        #expect(held.nodes[second]?.rerunsInSession == true)
        release.finish()
        let run = await waitFor(h, id, "second done") { $0.status != .running && $0.nodes[second]?.state == .succeeded }
        let sent = try #require(h.agent.requests.last { $0.prompt.contains("Polish") })
        #expect(sent.prompt == Self.rerunPrefix + "Polish draft two")
        #expect(sent.resumeSessionID == "s1")
        #expect(run.nodes[second]?.rerunsInSession == false)
    }

    @Test func retriedFailedContinuerKeepsThePrefix() async throws {
        let h = try Harness()
        let id = try await chainDone(h)
        let second = NodeKey(node: "second")
        h.agent.script({ $0.prompt == "Redo" }, events: finished("s1", "draft two"))
        h.agent.script({ $0.prompt.contains("Polish") }, events: finished("s1", "limit", isError: true))
        try await h.engine.followUp(id, node: NodeKey(node: "first"), message: "Redo")
        let failed = await waitFor(h, id, "second fails") { $0.status != .running && $0.nodes[second]?.state.isFailed == true }
        #expect(failed.nodes[second]?.rerunsInSession == true)
        h.agent.script({ $0.prompt.contains("Polish") }, events: finished("s1", "polished two"))
        try await h.engine.retry(id, node: second)
        let run = await waitFor(h, id, "second done") { $0.status != .running && $0.nodes[second]?.state == .succeeded }
        let sent = try #require(h.agent.requests.last { $0.prompt.contains("Polish") })
        #expect(sent.prompt == Self.rerunPrefix + "Polish draft two")
        #expect(run.nodes[second]?.rerunsInSession == false)
    }

    @Test func rerunFlagCodableDefaultsAndStaysOutOfFilesWhenFalse() throws {
        var node = NodeRun()
        let plain = String(decoding: try JSONEncoder().encode(node), as: UTF8.self)
        #expect(!plain.contains("rerunsInSession"))
        #expect(try JSONDecoder().decode(NodeRun.self, from: Data(plain.utf8)).rerunsInSession == false)
        node.rerunsInSession = true
        #expect(try JSONDecoder().decode(NodeRun.self, from: JSONEncoder().encode(node)).rerunsInSession)
    }
}
