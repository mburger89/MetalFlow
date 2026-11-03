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

        // The failed step's Retry reruns it, and the pick is offered when the pass reaches it.
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        try await h.engine.retry(id, node: notes)
        let retried = await waitFor(h, id, "the retry to finish") { self.pickIsOffered($0) && $0.nodes[self.notes]?.state == .succeeded }
        await h.engine.waitForPass(id)
        #expect(retried.nodes[notes]?.output == "summary")
        #expect(retried.pickToRestore == nil)
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
    }

    @Test func retryOfASiblingThatFailsAgainOffersThePickAgain() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        let id = try await atPick(h, flow: notesFlow(h))
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "limit", isError: true))
        h.agent.script({ $0.prompt == "Explain" }, events: finished("sj", "Because.\nRECOMMEND: b"))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        await waitFor(h, id, "the first failure") { self.pickIsOffered($0) && $0.nodes[self.notes]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        let before = h.agent.requests.filter { $0.prompt.hasPrefix("Summarize") }.count

        try await h.engine.retry(id, node: notes)
        let again = await waitFor(h, id, "the second failure") { self.pickIsOffered($0) && $0.nodes[self.notes]?.state.isFailed == true
            && h.agent.requests.filter { $0.prompt.hasPrefix("Summarize") }.count > before }
        await h.engine.waitForPass(id)
        #expect(again.pickToRestore == nil)
        #expect(h.agent.requests.filter { $0.prompt.hasPrefix("Summarize") }.count == before + 1, "the step reran")
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
    }

    @Test func retryOfAFailedFollowUpSiblingSendsTheKeptMessageAndOffersThePickAgain() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        let id = try await atPick(h, flow: notesFlow(h))
        h.agent.script({ $0.prompt == "Shorter" }, events: finished("sn", "limit", isError: true))
        try await h.engine.followUp(id, node: notes, message: "Shorter")
        await waitFor(h, id, "the first failure") { self.pickIsOffered($0) && $0.nodes[self.notes]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        let before = h.agent.requests.count

        try await h.engine.retry(id, node: notes)
        await waitFor(h, id, "the second failure") { self.pickIsOffered($0) && $0.nodes[self.notes]?.state.isFailed == true
            && h.agent.requests.count > before }
        await h.engine.waitForPass(id)
        var sent = h.agent.requests.dropFirst(before).filter { $0.prompt == "Shorter" }
        #expect(sent.count == 1 && sent.first?.resumeSessionID == "sn", "the kept message reached the agent")

        h.agent.script({ $0.prompt == "Shorter" }, events: finished("sn", "short"))
        let again = h.agent.requests.count
        try await h.engine.retry(id, node: notes)
        let run = await waitFor(h, id, "the success") { self.pickIsOffered($0) && $0.nodes[self.notes]?.state == .succeeded }
        sent = h.agent.requests.dropFirst(again).filter { $0.prompt == "Shorter" }
        #expect(sent.count == 1)
        #expect(run.nodes[notes]?.output == "short")
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

    // MARK: - 5. A follow-up's commit says so

    private func writes(_ name: String) -> @Sendable (AgentRequest) throws -> Void {
        { r in try name.write(to: r.workingDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    }

    @Test func followUpCommitIsLabelled() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let laneA = try #require(await h.engine.run(id)?.lanes.first { $0.id == "a" })
        let long = String(repeating: "x", count: 250)
        h.agent.script({ $0.prompt.hasPrefix("Add a file") }, effect: writes("one.txt"), events: finished("s", "added"))
        try await h.engine.followUp(id, node: implementA, message: "Add a file " + long)
        let run = await waitFor(h, id, "the pick") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.output == "added" }
        await h.engine.waitForPass(id)
        let message = try h.repo.git(["log", "-1", "--format=%B", laneA.branch]).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = RunEngine.commitName(runTitle: run.title, flowName: run.flow.name)
        let sent = String(("Add a file " + long).prefix(200))
        #expect(message == "Follow-up: \(name) (a)\n\nNode: \(run.flow.node("implement")!.title)\nMessage: \(sent)")
        #expect(run.nodes[implementA]?.followUpMessage == nil)
    }

    @Test func answerCommitIsNotLabelled() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let laneA = try #require(await h.engine.run(id)?.lanes.first { $0.id == "a" })
        h.agent.script({ $0.prompt == "Tweak" }, effect: writes("one.txt"), events: finished("s", "hmm\nQUESTION: Which?"))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        let asked = await waitFor(h, id, "the question") { $0.nodes[self.implementA]?.state == .needsYou(.question("Which?")) }
        await h.engine.waitForPass(id)
        let labelled = try h.repo.git(["log", "-1", "--format=%B", laneA.branch])
        #expect(labelled.hasPrefix("Follow-up: "))
        #expect(asked.nodes[implementA]?.followUpMessage == nil, "cleared once the turn's commit succeeded")

        h.agent.script({ $0.prompt == "The first" }, effect: writes("two.txt"), events: finished("s", "done"))
        try await h.engine.answer(id, node: implementA, reply: "The first")
        await waitFor(h, id, "the answer to finish") { $0.nodes[self.implementA]?.output == "done" }
        await h.engine.waitForPass(id)
        let answered = try h.repo.git(["log", "-1", "--format=%B", laneA.branch])
        #expect(!answered.contains("Follow-up"))
        #expect(answered.hasPrefix(RunEngine.commitName(runTitle: asked.title, flowName: asked.flow.name) + " (a)"))
    }

    @Test func followUpMessageSurvivesAFailedCommitAndRetry() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let laneA = try #require(await h.engine.run(id)?.lanes.first { $0.id == "a" })
        let failing = OSAllocatedUnfairLock(initialState: true)
        let real = ProcessRunner(resolver: ExecutableResolver(searchPath: ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin"]))
        h.hooks.override({ $0.executable == "git" && CommandHooks.gitArguments($0).first == "commit"
            && $0.arguments.contains { $0.hasSuffix("/a") } }) { c in
            if failing.withLock({ $0 }) { return CommandResult(exitCode: 1, stdout: "", stderr: "no") }
            return try await real.run(c)
        }
        h.agent.script({ $0.prompt == "Tweak" }, effect: writes("one.txt"), events: finished("s", "tweaked"))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        let failed = await waitFor(h, id, "the commit to fail") { $0.nodes[self.implementA]?.state.isFailed == true
            && $0.nodes[self.pick]?.state != .running }
        await h.engine.waitForPass(id)
        #expect(failed.nodes[implementA]?.followUpMessage == "Tweak")
        failing.withLock { $0 = false }
        try await h.engine.retry(id, node: implementA)
        await waitFor(h, id, "the retry to finish") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.state == .succeeded }
        await h.engine.waitForPass(id)
        let message = try h.repo.git(["log", "-1", "--format=%B", laneA.branch])
        #expect(message.contains("Message: Tweak"))
        #expect(await h.engine.run(id)?.nodes[implementA]?.followUpMessage == nil)
    }

    @Test func nonLaneFollowUpMessageClearsOnACleanFinish() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        let id = try await atPick(h, flow: notesFlow(h))
        h.agent.script({ $0.prompt == "Shorter" }, events: finished("sn", "short"))
        try await h.engine.followUp(id, node: notes, message: "Shorter")
        let run = await waitFor(h, id, "notes done") { self.pickIsOffered($0) && $0.nodes[self.notes]?.output == "short" }
        #expect(run.nodes[notes]?.followUpMessage == nil)
    }

    // MARK: - 6. Refuse a follow-up that could not run

    /// What a refused follow-up must leave alone, revision included.
    private func snapshot(_ run: Run) -> [String] {
        run.orderedNodeKeys.map { "\($0) \(run.nodes[$0]!.state) \(run.nodes[$0]!.output ?? "") \(run.nodes[$0]!.pendingReply ?? "")" }
            + ["\(run.status) \(run.revision) \(run.recommendation ?? "-") \(run.followedUp) \(String(describing: run.pickToRestore))"]
    }

    @Test func followUpRefusedWhileALaneQuestionWaits() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        await h.engine.setDirect(id) { $0.nodes[NodeKey(node: "implement", lane: "b")]?.state = .needsYou(.question("Keep?")) }
        let run = try #require(await h.engine.run(id))
        let title = try #require(run.flow.node("implement")?.title)
        let requests = h.agent.requests.count
        await #expect(throws: RunEngineError.followUpBlocked("Answer the question on \"\(title)\" first, then send this.")) {
            try await h.engine.followUp(id, node: judge, message: "Explain")
        }
        let after = try #require(await h.engine.run(id))
        #expect(snapshot(after) == snapshot(run))
        #expect(after.revision == run.revision)
        #expect(h.agent.requests.count == requests)
        #expect(RunEngineError.followUpBlocked("Resume \"X\" first, then send this.").errorDescription == "Resume \"X\" first, then send this.")
    }

    @Test func followUpRefusedWhileAnEarlierStepIsInterrupted() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        let id = try await atPick(h, flow: notesFlow(h))
        await h.engine.setDirect(id) { $0.nodes[self.judge]?.state = .interrupted }
        let run = try #require(await h.engine.run(id))
        let title = try #require(run.flow.node("judge")?.title)
        await #expect(throws: RunEngineError.followUpBlocked("Resume \"\(title)\" first, then send this.")) {
            try await h.engine.followUp(id, node: notes, message: "Shorter")
        }
        let after = try #require(await h.engine.run(id))
        #expect(snapshot(after) == snapshot(run))
    }

    @Test func followUpRefusedBehindAnEarlierFailedStep() async throws {
        let h = try Harness()
        var flow = h.flow()
        // A side step ahead of the candidates in plan order, fed by the plan; the judge comes after it.
        flow.nodes.insert(Node(id: "side", title: "Side", kind: .prompt(PromptConfig(
            model: "sonnet", prompt: "Side {plan}", candidates: [], allowedTools: [], maxTurns: nil)),
                               position: Point(x: 0, y: 0)), at: flow.nodes.firstIndex { $0.id == "implement" }!)
        flow.wires.append(Wire(from: "plan", to: "side", input: "plan"))
        h.agent.script({ $0.prompt.hasPrefix("Side") }, events: finished("ss", "side done"))
        let id = try await atPick(h, flow: flow)
        let side = NodeKey(node: "side")
        h.agent.script({ $0.prompt == "More" }, events: finished("ss", "limit", isError: true))
        try await h.engine.followUp(id, node: side, message: "More")
        await waitFor(h, id, "the failure") { self.pickIsOffered($0) && $0.nodes[side]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        let run = try #require(await h.engine.run(id))

        await #expect(throws: RunEngineError.followUpBlocked("Retry \"Side\" first, then send this.")) {
            try await h.engine.followUp(id, node: judge, message: "Explain")
        }
        let after = try #require(await h.engine.run(id))
        #expect(snapshot(after) == snapshot(run))
        #expect(after.revision == run.revision)

        h.agent.script({ $0.prompt == "More" }, events: finished("ss", "more"))
        try await h.engine.retry(id, node: side)
        await waitFor(h, id, "the retry") { self.pickIsOffered($0) && $0.nodes[side]?.state == .succeeded }
        await h.engine.waitForPass(id)
        h.agent.script({ $0.prompt == "Explain" }, events: finished("sj", "Because.\nRECOMMEND: b"))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        let done = await waitFor(h, id, "the follow-up") { self.pickIsOffered($0) && $0.nodes[self.judge]?.output?.contains("Because.") == true }
        #expect(done.nodes[judge]?.state == .succeeded)
    }

    @Test func followUpAllowedWhenTheQuestionIsDownstream() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        let id = try await atPick(h, flow: notesFlow(h))
        // The step after the judge waits on a question; following up the judge resets it anyway.
        await h.engine.setDirect(id) { $0.nodes[self.notes]?.state = .needsYou(.question("Which part?")) }
        h.agent.script({ $0.prompt == "Explain" }, events: finished("sj", "Because.\nRECOMMEND: b"))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        let run = await waitFor(h, id, "the pick") { self.pickIsOffered($0) && $0.nodes[self.judge]?.output?.contains("Because.") == true }
        #expect(run.nodes[notes]?.state == .succeeded)
    }

    @Test func laneFollowUpNotRefusedByAnotherLanesQuestion() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        await h.engine.setDirect(id) { $0.nodes[NodeKey(node: "implement", lane: "b")]?.state = .needsYou(.question("Keep?")) }
        h.agent.script({ $0.prompt == "Tweak" }, events: finished("s", "tweaked"))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        let run = await waitFor(h, id, "a's turn to finish") { $0.nodes[self.implementA]?.output == "tweaked"
            && $0.nodes[self.implementA]?.state == .succeeded }
        #expect(run.nodes[NodeKey(node: "implement", lane: "b")]?.state == .needsYou(.question("Keep?")))
    }

    // MARK: - 7. An empty follow-up gets the right message

    @Test func emptyFollowUpSaysSo() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let run = try #require(await h.engine.run(id))
        await #expect(throws: RunEngineError.emptyFollowUp) {
            try await h.engine.followUp(id, node: implementA, message: "  \n ")
        }
        // Ahead of the other refusals: a step that cannot take a follow-up still gets the empty-message answer.
        await #expect(throws: RunEngineError.emptyFollowUp) {
            try await h.engine.followUp(id, node: NodeKey(node: "plan"), message: "")
        }
        // But not ahead of the unknown-run check.
        let missing = RunID()
        await #expect(throws: RunEngineError.unknownRun(missing)) {
            try await h.engine.followUp(missing, node: implementA, message: "")
        }
        #expect(RunEngineError.emptyFollowUp.errorDescription == "Type a message to send.")
        let after = try #require(await h.engine.run(id))
        #expect(snapshot(after) == snapshot(run))
    }

    // MARK: - 9. Discard waits for a suspended pass

    /// Holds callers until opened, and does not notice cancellation while they wait, as a running git process does not.
    private final class Gate: Sendable {
        private struct State { var isOpen = false; var waiters: [CheckedContinuation<Void, Never>] = [] }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let entries = OSAllocatedUnfairLock(initialState: 0)
        var entered: Int { entries.withLock { $0 } }
        func wait() async {
            entries.withLock { $0 += 1 }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let open = state.withLock { s -> Bool in
                    if !s.isOpen { s.waiters.append(c) }
                    return s.isOpen
                }
                if open { c.resume() }
            }
        }
        func open() {
            let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.isOpen = true
                defer { s.waiters = [] }
                return s.waiters
            }
            for c in waiting { c.resume() }
        }
    }

    @Test func discardWaitsForASuspendedPass() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        // The follow-up's turn ends in a commit that stays stuck until released, and a stuck commit ignores cancellation.
        let gate = Gate()
        defer { gate.open() }
        let real = ProcessRunner(resolver: ExecutableResolver(searchPath: ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin"]))
        h.hooks.override({ $0.executable == "git" && CommandHooks.gitArguments($0).first == "commit"
            && $0.arguments.contains { $0.hasSuffix("/a") } }) { c in
            await gate.wait()
            return try await real.run(c)
        }
        h.agent.script({ $0.prompt == "Tweak" }, effect: writes("one.txt"), events: finished("s", "tweaked"))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        await waitUntil("the commit to start") { gate.entered == 1 }

        // Cancelling a followed-up run suspends it: saved cut short, the pass still stuck in its commit.
        await h.engine.cancel(id)
        #expect(await h.engine.suspended.contains(id))
        #expect(await h.engine.run(id)?.status == .needsYou)
        let passAlive = await h.engine.tasks[id] != nil

        let done = OSAllocatedUnfairLock(initialState: false)
        let discarding = Task {
            defer { done.withLock { $0 = true } }
            try await h.engine.discard(id)
        }
        // Give discard a bounded time to run ahead of the pass (a discard that does not wait finishes in far less); it must
        // be stuck behind it.
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline, !done.withLock({ $0 }) { await Task.yield() }
        let early = done.withLock { $0 }
        let before = await h.engine.run(id)?.status
        gate.open()
        try await discarding.value
        #expect(passAlive, "the stopped pass is still stuck in its commit")
        #expect(!early, "discard finished before the suspended pass ended")
        #expect(before == .needsYou, "nothing discarded the run early")
        await h.engine.waitForPass(id)
        #expect(await h.engine.run(id)?.status == .discarded)
        #expect(h.store.load(id)?.status == .discarded, "nothing overwrote it")
        #expect(await h.engine.tasks[id] == nil)
    }

    // MARK: - Fix round 3. Picking past a failed step

    private func prompt(_ id: String, _ text: String) -> Node {
        Node(id: NodeID(rawValue: id), title: id.uppercased(), kind: .prompt(PromptConfig(
            model: "sonnet", prompt: text, candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0))
    }

    /// The harness flow with Z1 (fed by the plan) -> Z2 -> pick, an optional Z3 fed by Z1 only, and an Open PR after the pick.
    private func zFlow(_ h: Harness, z3: Bool = false) -> Flow {
        var flow = h.flow()
        let at = flow.nodes.firstIndex { $0.id == "implement" }!
        flow.nodes.insert(contentsOf: [prompt("z1", "Zone1 {plan}"), prompt("z2", "Zone2 {z1}")] + (z3 ? [prompt("z3", "Zone3 {z1}")] : []), at: at)
        flow.wires += [Wire(from: "plan", to: "z1", input: "plan"), Wire(from: "z1", to: "z2", input: "z1"),
                       Wire(from: "z2", to: "pick", input: "z2")]
        if z3 { flow.wires.append(Wire(from: "z1", to: "z3", input: "z1")) }
        flow.nodes.append(Node(id: "openpr", title: "Open PR", kind: .openPR(OpenPRConfig(draft: true)),
                               position: Point(x: 0, y: 0)))
        flow.wires.append(Wire(from: "pick", to: "openpr", input: "approval"))
        return flow
    }

    private static let prURL = "https://github.com/acme/widgets/pull/12"

    /// Runs the Z flow to the pick, follows up Z1 so it fails (the pick is offered again), and picks lane b.
    private func pickedPastFailedZ1(_ h: Harness, z3: Bool) async throws -> (RunID, Run) {
        h.hooks.stubGit("push")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: Self.prURL + "\n", stderr: ""))
        h.agent.script({ $0.prompt.hasPrefix("Zone") }, events: finished("sz", "zone"))
        let id = try await atPick(h, flow: zFlow(h, z3: z3))
        h.agent.script({ $0.prompt == "More" }, events: finished("sz", "limit", isError: true))
        try await h.engine.followUp(id, node: NodeKey(node: "z1"), message: "More")
        await waitFor(h, id, "the pick offered again") { self.pickIsOffered($0) && $0.nodes[NodeKey(node: "z1")]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        #expect(await h.engine.run(id)?.nodes[NodeKey(node: "z2")]?.state == .waiting)
        let result = try await h.engine.pick(id, lane: "b")
        #expect(result == .handedToPullRequest)
        await h.engine.waitUntilSettled(id)
        return (id, try #require(await h.engine.run(id)))
    }

    @Test func pickPastAFailedStepSkipsWhatItFed() async throws {
        let h = try Harness()
        let (_, run) = try await pickedPastFailedZ1(h, z3: false)
        // Z2 ran once, before the follow-up; never again with the failed step's missing output after the pick.
        #expect(h.agent.requests.filter { $0.prompt.hasPrefix("Zone2") }.count == 1)
        #expect(run.nodes[NodeKey(node: "z2")]?.state == .waiting)
        #expect(run.nodes[NodeKey(node: "z2")]?.log.filter { $0 == "Skipped: the pick was made without this step." }.count == 1)
        #expect(run.nodes[NodeKey(node: "z1")]?.state.isFailed == true)
        #expect(run.status == .prOpened("b", url: Self.prURL))
        #expect(run.nodes[NodeKey(node: "openpr")]?.state == .succeeded)
    }

    @Test func pickPastAFailedStepSkipsItsDependentSibling() async throws {
        let h = try Harness()
        let (_, run) = try await pickedPastFailedZ1(h, z3: true)
        #expect(h.agent.requests.filter { $0.prompt.hasPrefix("Zone3") }.count == 1, "only the run before the follow-up")
        #expect(run.nodes[NodeKey(node: "z3")]?.state == .waiting)
        #expect(run.nodes[NodeKey(node: "z3")]?.log.contains("Skipped: the pick was made without this step.") == true)
        #expect(run.status == .prOpened("b", url: Self.prURL))
    }
}
