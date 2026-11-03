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
        #expect(failed.nodes[implementA]?.state == .failed(Self.lostMessage + " and the message it was sent."))
        #expect(failed.nodes[implementA]?.sessionID == nil)
        #expect(failed.nodes[implementA]?.pendingReply == "Tweak")
        #expect(!failed.canFollowUp(implementA))
        #expect(session == "s")

        h.agent.script({ $0.prompt.hasSuffix("\n\nA message about this step:\nTweak") },
                       events: finished("fresh", "tweaked"))
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: implementA)
        let run = await waitFor(h, id, "the retry to finish") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.state == .succeeded }
        let sent = h.agent.requests.dropFirst(before).filter { $0.workingDirectory.lastPathComponent == "a" }
        #expect(sent.count == 1)
        #expect(sent.first?.resumeSessionID == nil)
        #expect(sent.first?.prompt.contains("Fix this GitHub issue") == true)
        #expect(sent.first?.prompt.hasSuffix("\n\nA message about this step:\nTweak") == true)
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
        #expect(failed.nodes[second]?.state == .failed(Self.lostMessage + " and the message it was sent."))
        #expect(failed.nodes[first]?.sessionID == nil && failed.nodes[second]?.sessionID == nil)

        h.agent.script({ $0.prompt.hasPrefix("Polish") }, events: finished("fresh", "polished again"))
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: second)
        let run = await waitFor(h, id, "the retry to finish") { $0.nodes[second]?.state == .succeeded && $0.status != .running }
        let sent = try #require(h.agent.requests.dropFirst(before).first)
        #expect(sent.resumeSessionID == nil)
        #expect(sent.prompt == "Polish draft\n\nA message about this step:\nAgain")
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
        #expect(await h.engine.run(id)?.nodes[NodeKey(node: "second")]?.ranInSession == nil)
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
        #expect(held.nodes[second]?.ranInSession == "s1")
        release.finish()
        let run = await waitFor(h, id, "second done") { $0.status != .running && $0.nodes[second]?.state == .succeeded }
        let sent = try #require(h.agent.requests.last { $0.prompt.contains("Polish") })
        #expect(sent.prompt == Self.rerunPrefix + "Polish draft two")
        #expect(sent.resumeSessionID == "s1")
        #expect(run.nodes[second]?.ranInSession == nil)
    }

    @Test func retriedFailedContinuerKeepsThePrefix() async throws {
        let h = try Harness()
        let id = try await chainDone(h)
        let second = NodeKey(node: "second")
        h.agent.script({ $0.prompt == "Redo" }, events: finished("s1", "draft two"))
        h.agent.script({ $0.prompt.contains("Polish") }, events: finished("s1", "limit", isError: true))
        try await h.engine.followUp(id, node: NodeKey(node: "first"), message: "Redo")
        let failed = await waitFor(h, id, "second fails") { $0.status != .running && $0.nodes[second]?.state.isFailed == true }
        #expect(failed.nodes[second]?.ranInSession == "s1")
        h.agent.script({ $0.prompt.contains("Polish") }, events: finished("s1", "polished two"))
        try await h.engine.retry(id, node: second)
        let run = await waitFor(h, id, "second done") { $0.status != .running && $0.nodes[second]?.state == .succeeded }
        let sent = try #require(h.agent.requests.last { $0.prompt.contains("Polish") })
        #expect(sent.prompt == Self.rerunPrefix + "Polish draft two")
        #expect(run.nodes[second]?.ranInSession == nil)
    }

    @Test func rerunSessionCodableDefaultsAndStaysOutOfFilesWhenNil() throws {
        var node = NodeRun()
        let plain = String(decoding: try JSONEncoder().encode(node), as: UTF8.self)
        #expect(!plain.contains("ranInSession"))
        #expect(try JSONDecoder().decode(NodeRun.self, from: Data(plain.utf8)).ranInSession == nil)
        node.ranInSession = "s1"
        #expect(try JSONDecoder().decode(NodeRun.self, from: JSONEncoder().encode(node)).ranInSession == "s1")
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

    // MARK: - Fix round 4. Resuming an interrupted follow-up

    /// A follow-up whose turn was cut short by Cancel (which suspends), resumed with the nudge.
    private func interruptedFollowUp(_ h: Harness) async throws -> (RunID, String) {
        let id = try await atPick(h)
        let session = try #require(await h.engine.run(id)?.nodes[implementA]?.sessionID)
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        h.agent.script({ $0.prompt == "Tweak" }, hold: hold, events: finished(session, "tweaked"))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        await waitFor(h, id, "the turn to start") { $0.nodes[self.implementA]?.replyInFlight == "Tweak" }
        await h.engine.cancel(id)
        await h.engine.waitForPass(id)
        let stopped = try #require(await h.engine.run(id))
        #expect(stopped.nodes[implementA]?.state == .interrupted)
        #expect(stopped.nodes[implementA]?.replyInFlight == "Tweak")
        return (id, session)
    }

    @Test func resumedFollowUpWithALostSessionKeepsTheMessage() async throws {
        let h = try Harness()
        let (id, _) = try await interruptedFollowUp(h)
        h.agent.script({ $0.prompt == "Continue where you left off." }, events: lostSession())
        try await h.engine.resumeInterrupted(id)
        let failed = await waitFor(h, id, "the lost session") { $0.nodes[self.implementA]?.state.isFailed == true
            && $0.nodes[self.pick]?.state != .running && $0.status != .running }
        await h.engine.waitForPass(id)
        #expect(failed.nodes[implementA]?.pendingReply == "Tweak")
        #expect(failed.nodes[implementA]?.sessionID == nil)
        #expect(failed.nodes[implementA]?.followUpMessage == "Tweak")

        h.agent.script({ $0.prompt.hasSuffix("\n\nA message about this step:\nTweak") }, events: finished("fresh", "tweaked"))
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: implementA)
        await waitFor(h, id, "the retry") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.state == .succeeded }
        let sent = try #require(h.agent.requests.dropFirst(before).first { $0.workingDirectory.lastPathComponent == "a" })
        #expect(sent.resumeSessionID == nil)
        #expect(sent.prompt.hasSuffix("\n\nA message about this step:\nTweak"))
    }

    @Test func resumedFollowUpThatFailsRetriesWithTheMessage() async throws {
        let h = try Harness()
        let (id, session) = try await interruptedFollowUp(h)
        h.agent.script({ $0.prompt == "Continue where you left off." }, events: finished(session, "limit", isError: true))
        try await h.engine.resumeInterrupted(id)
        let failed = await waitFor(h, id, "the failure") { $0.nodes[self.implementA]?.state.isFailed == true
            && $0.nodes[self.pick]?.state != .running && $0.status != .running }
        await h.engine.waitForPass(id)
        #expect(failed.nodes[implementA]?.pendingReply == "Tweak", "the message, not the nudge, goes again")
        h.agent.script({ $0.prompt == "Tweak" }, events: finished(session, "tweaked"))
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: implementA)
        let run = await waitFor(h, id, "the retry") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.state == .succeeded }
        let sent = try #require(h.agent.requests.dropFirst(before).first { $0.workingDirectory.lastPathComponent == "a" })
        #expect(sent.prompt == "Tweak" && sent.resumeSessionID == session)
        #expect(run.nodes[implementA]?.pendingReply == nil && run.nodes[implementA]?.replyInFlight == nil)
    }

    @Test func interruptedPlainStepStillResumesWithTheNudge() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let session = try #require(await h.engine.run(id)?.nodes[implementA]?.sessionID)
        await h.engine.setDirect(id) { $0.nodes[self.implementA]?.state = .interrupted }
        h.agent.script({ $0.prompt == "Continue where you left off." }, events: finished(session, "carried on"))
        let before = h.agent.requests.count
        try await h.engine.resumeInterrupted(id)
        let run = await waitFor(h, id, "the resume") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.output == "carried on" }
        let sent = try #require(h.agent.requests.dropFirst(before).first { $0.workingDirectory.lastPathComponent == "a" })
        #expect(sent.prompt == "Continue where you left off." && sent.resumeSessionID == session)
        #expect(run.nodes[implementA]?.pendingReply == nil && run.nodes[implementA]?.replyInFlight == nil)
    }

    // MARK: - Fix round 5. The rerun notice is only for the same conversation

    @Test func continuerOfAResetSourceGetsNoNotice() async throws {
        let h = try Harness()
        let flow = Flow(name: "xpc", nodes: [
            Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 0, y: 0)),
            prompt("x", "Think in {repo}"),
            prompt("p", "Write {thought}"),
            Node(id: "c", title: "C", kind: .prompt(PromptConfig(
                model: "opus", prompt: "Polish {code}", candidates: [], allowedTools: [], maxTurns: nil,
                continuesSessionOf: "p")), position: Point(x: 3, y: 0)),
        ], wires: [Wire(from: "repo", to: "x", input: "repo"), Wire(from: "x", to: "p", input: "thought"),
                   Wire(from: "p", to: "c", input: "code")])
        h.agent.script({ $0.prompt.hasPrefix("Think") }, events: finished("sx", "idea"))
        h.agent.script({ $0.prompt.hasPrefix("Write") }, events: finished("sp", "draft"))
        h.agent.script({ $0.prompt.contains("Polish") }, events: finished("sp", "polished"))
        let id = try await h.engine.launch(flow: flow, location: h.repoLocation, values: ["repo": h.repo.url.path])
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        // Following up X restarts P in a new conversation, so C is not rerunning anything in its old one.
        h.agent.script({ $0.prompt == "Redo" }, events: finished("sx", "idea two"))
        h.agent.script({ $0.prompt.hasPrefix("Write") }, events: finished("sp2", "draft two"))
        h.agent.script({ $0.prompt.contains("Polish") }, events: finished("sp2", "polished two"))
        try await h.engine.followUp(id, node: NodeKey(node: "x"), message: "Redo")
        await waitFor(h, id, "the rerun") { $0.status != .running && $0.nodes[NodeKey(node: "c")]?.state == .succeeded
            && $0.nodes[NodeKey(node: "c")]?.output == "polished two" }
        let polish = try #require(h.agent.requests.last { $0.prompt.contains("Polish") })
        #expect(polish.prompt == "Polish draft two")
        #expect(polish.resumeSessionID == "sp2")
    }

    @Test func continuerAfterALostSessionGetsNoNotice() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.hasPrefix("Write in") }, events: finished("s1", "draft"))
        h.agent.script({ $0.prompt.contains("Polish") }, events: finished("s1", "polished"))
        let id = try await h.engine.launch(flow: chainFlow(), location: h.repoLocation, values: ["repo": h.repo.url.path])
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        let first = NodeKey(node: "first"), second = NodeKey(node: "second")
        // The source's conversation is lost on its follow-up; its retry starts a new one the continuer was never in.
        h.agent.script({ $0.prompt == "Redo" }, events: lostSession())
        try await h.engine.followUp(id, node: first, message: "Redo")
        await waitFor(h, id, "the loss") { $0.nodes[first]?.state.isFailed == true && $0.status != .running }
        h.agent.script({ $0.prompt.hasSuffix("\n\nA message about this step:\nRedo") }, events: finished("s9", "draft two"))
        h.agent.script({ $0.prompt.contains("Polish") }, events: finished("s9", "polished two"))
        try await h.engine.retry(id, node: first)
        await waitFor(h, id, "the retry") { $0.status != .running && $0.nodes[second]?.output == "polished two" }
        let polish = try #require(h.agent.requests.last { $0.prompt.contains("Polish") })
        #expect(polish.prompt == "Polish draft two")
        #expect(polish.resumeSessionID == "s9")
    }

    // MARK: - Fix round 6. Not every kept message is the user's

    @Test func lostSessionOnAResumedPlainStepSaysNothingAboutAMessage() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        await h.engine.setDirect(id) { $0.nodes[self.implementA]?.state = .interrupted }
        h.agent.script({ $0.prompt == "Continue where you left off." }, events: lostSession())
        try await h.engine.resumeInterrupted(id)
        let failed = await waitFor(h, id, "the loss") { $0.nodes[self.implementA]?.state.isFailed == true && $0.status != .running }
        #expect(failed.nodes[implementA]?.state == .failed(Self.lostMessage + "."), "the nudge is not a message")
    }

    // MARK: - Fix round 7. The failure banner names the last failed step

    @Test func openPRFailureAfterAPickPastAFailedStepNamesOpenPR() async throws {
        let h = try Harness()
        h.hooks.stubGit("push", exit: 1, stderr: "remote said no")
        h.agent.script({ $0.prompt.hasPrefix("Zone") }, events: finished("sz", "zone"))
        let id = try await atPick(h, flow: zFlow(h))
        h.agent.script({ $0.prompt == "More" }, events: finished("sz", "limit", isError: true))
        try await h.engine.followUp(id, node: NodeKey(node: "z1"), message: "More")
        await waitFor(h, id, "the pick offered again") { self.pickIsOffered($0) && $0.nodes[NodeKey(node: "z1")]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        guard case .failed(let openPRMessage)? = run.nodes[NodeKey(node: "openpr")]?.state else {
            Issue.record("Open PR should have failed, got \(String(describing: run.nodes[NodeKey(node: "openpr")]?.state))"); return
        }
        #expect(openPRMessage != "limit")
        #expect(run.status == .failed(openPRMessage), "the banner names Open PR, the last failed step")
    }

    // MARK: - Fix round 8. A gate's fix after the pick

    /// The harness flow with A (fed by the plan) feeding the pick and a gate G that passes once fixed.txt exists, then
    /// Open PR. With `viaShell`, A feeds the pick and G through a shell step F instead of directly.
    private func gateAfterPickFlow(_ h: Harness, viaShell: Bool = false) -> Flow {
        var flow = h.flow()
        let at = flow.nodes.firstIndex { $0.id == "implement" }!
        flow.nodes.insert(prompt("a", "Alpha {plan}"), at: at)
        flow.wires.append(Wire(from: "plan", to: "a", input: "plan"))
        if viaShell {
            flow.nodes.insert(Node(id: "f", title: "F", kind: .shell(ShellConfig(command: "echo FED {a}")),
                                   position: Point(x: 0, y: 0)), at: at + 1)
            flow.wires += [Wire(from: "a", to: "f", input: "a"), Wire(from: "f", to: "pick", input: "f")]
        } else {
            flow.wires.append(Wire(from: "a", to: "pick", input: "a"))
        }
        flow.nodes.append(Node(id: "g", title: "G", kind: .gate(ShellConfig(command: "test -f fixed.txt", fixAttempts: 2)),
                               position: Point(x: 0, y: 0)))
        flow.wires += [Wire(from: viaShell ? "f" : "a", to: "g", input: "code"), Wire(from: "judge", to: "g", input: "rec")]
        flow.nodes.append(Node(id: "openpr", title: "Open PR", kind: .openPR(OpenPRConfig(draft: true)),
                               position: Point(x: 0, y: 0)))
        flow.wires.append(Wire(from: "pick", to: "openpr", input: "approval"))
        flow.wires.append(Wire(from: "g", to: "openpr", input: "checked"))
        return flow
    }

    private func gateFixThroughThePick(_ h: Harness, viaShell: Bool) async throws -> Run {
        h.hooks.stubGit("push")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: Self.prURL + "\n", stderr: ""))
        h.agent.script({ $0.prompt.hasPrefix("Alpha") }, events: finished("sa", "alpha"))
        h.agent.script({ $0.prompt.contains("test -f fixed.txt") }, effect: { r in
            try "ok".write(to: r.workingDirectory.appendingPathComponent("fixed.txt"), atomically: true, encoding: .utf8)
        }, events: finished("sa", "alpha fixed"))
        let id = try await atPick(h, flow: gateAfterPickFlow(h, viaShell: viaShell))
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        return try #require(await h.engine.run(id))
    }

    @Test func gateFixAfterThePickStillRunsItsAgent() async throws {
        let h = try Harness()
        let run = try await gateFixThroughThePick(h, viaShell: false)
        #expect(h.agent.requests.filter { $0.prompt.contains("test -f fixed.txt") }.count == 1, "the agent got the fix message")
        #expect(run.nodes[NodeKey(node: "g")]?.state == .succeeded)
        #expect(run.nodes[NodeKey(node: "g")]?.fixAttemptsUsed == 1, "the gate passed on its second run")
        #expect(run.status == .prOpened("b", url: Self.prURL))
        #expect(run.nodes[NodeKey(node: "openpr")]?.state == .succeeded)
    }

    @Test func stepThatFedThePickWithNoFailedAncestorStillRuns() async throws {
        let h = try Harness()
        let run = try await gateFixThroughThePick(h, viaShell: true)
        #expect(run.nodes[NodeKey(node: "f")]?.output?.contains("FED alpha fixed") == true, "F reran on the fixed output")
        #expect(run.nodes[NodeKey(node: "f")]?.log.contains("Skipped: the pick was made without this step.") != true)
        #expect(run.nodes[NodeKey(node: "g")]?.state == .succeeded)
        #expect(run.status == .prOpened("b", url: Self.prURL))
    }

    // MARK: - Fix round 8. A follow-up after the pick

    @Test func followUpAfterThePickIsNotBlockedByAFailedStep() async throws {
        let h = try Harness()
        var flow = zFlow(h)
        let openAt = flow.nodes.firstIndex { $0.id == "openpr" }!
        flow.nodes.insert(prompt("t", "Tee {pick}"), at: openAt)
        flow.wires += [Wire(from: "pick", to: "t", input: "pick"), Wire(from: "t", to: "openpr", input: "t")]
        h.hooks.stubGit("push", exit: 1, stderr: "remote said no")
        h.agent.script({ $0.prompt.hasPrefix("Zone") }, events: finished("sz", "zone"))
        h.agent.script({ $0.prompt.hasPrefix("Tee") }, events: finished("st", "tee"))
        let id = try await atPick(h, flow: flow)
        h.agent.script({ $0.prompt == "More" }, events: finished("sz", "limit", isError: true))
        try await h.engine.followUp(id, node: NodeKey(node: "z1"), message: "More")
        await waitFor(h, id, "the pick offered again") { self.pickIsOffered($0) && $0.nodes[NodeKey(node: "z1")]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        let t = NodeKey(node: "t"), openPR = NodeKey(node: "openpr")
        let failed = try #require(await h.engine.run(id))
        #expect(failed.nodes[openPR]?.state.isFailed == true && failed.nodes[t]?.state == .succeeded)

        h.hooks.stubGit("push")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: Self.prURL + "\n", stderr: ""))
        h.agent.script({ $0.prompt == "Again" }, events: finished("st", "tee two"))
        try await h.engine.followUp(id, node: t, message: "Again")
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        #expect(h.agent.requests.contains { $0.prompt == "Again" && $0.resumeSessionID == "st" })
        #expect(run.nodes[t]?.output == "tee two")
        #expect(run.nodes[NodeKey(node: "z1")]?.state.isFailed == true, "Z1 was not retried")
        #expect(run.nodes[openPR]?.state == .succeeded)
        #expect(run.status == .prOpened("b", url: Self.prURL))
    }

    // MARK: - Fix round 8. A resumed plain step keeps its session on Retry

    @Test func resumedPlainStepThatFailsRetriesInTheSameSession() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let session = try #require(await h.engine.run(id)?.nodes[implementA]?.sessionID)
        await h.engine.setDirect(id) { $0.nodes[self.implementA]?.state = .interrupted }
        h.agent.script({ $0.prompt == "Continue where you left off." }, events: finished(session, "limit", isError: true))
        try await h.engine.resumeInterrupted(id)
        let failed = await waitFor(h, id, "the failure") { $0.nodes[self.implementA]?.state.isFailed == true
            && $0.nodes[self.pick]?.state != .running && $0.status != .running }
        await h.engine.waitForPass(id)
        #expect(failed.nodes[implementA]?.pendingReply == "Continue where you left off.", "the retry resumes the session")
        h.agent.script({ $0.prompt == "Continue where you left off." }, events: finished(session, "carried on"))
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: implementA)
        let run = await waitFor(h, id, "the retry") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.state == .succeeded }
        let sent = try #require(h.agent.requests.dropFirst(before).first { $0.workingDirectory.lastPathComponent == "a" })
        #expect(sent.prompt == "Continue where you left off." && sent.resumeSessionID == session)
        #expect(run.nodes[implementA]?.pendingReply == nil && run.nodes[implementA]?.replyInFlight == nil)
    }

    // MARK: - Fix round 8. A judge can't recommend a failed candidate

    /// Runs the harness flow with candidate b failing; the judge replies `reply`.
    private func atPickWithFailedB(_ h: Harness, reply: String) async throws -> Run {
        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == "b" },
                       events: finished("sb", "limit", isError: true))
        h.agent.script({ $0.prompt.contains("judging candidate") }, events: finished("sj", reply))
        let id = try await atPick(h)
        let run = try #require(await h.engine.run(id))
        #expect(run.nodes[NodeKey(node: "implement", lane: "b")]?.state.isFailed == true)
        return run
    }

    @Test func judgeRecommendingAFailedCandidateLeavesNone() async throws {
        let h = try Harness()
        let run = try await atPickWithFailedB(h, reply: "b is best.\nRECOMMEND: b")
        #expect(run.recommendation == nil)
        #expect(run.nodes[pick]?.state == .needsYou(.pickWinner(recommended: nil, allGatesFailed: false)))
        #expect(run.nodes[judge]?.log.contains("⚠ recommended b, which failed; no recommendation") == true)
        _ = try await h.engine.pick(run.id, lane: "b")
        #expect(await h.engine.run(run.id)?.status == .merged("b"))
    }

    @Test func judgeRecommendingAGoodCandidateAlongsideAFailedOneStands() async throws {
        let h = try Harness()
        let run = try await atPickWithFailedB(h, reply: "a is best.\nRECOMMEND: a")
        #expect(run.recommendation == "a")
        #expect(run.nodes[pick]?.state == .needsYou(.pickWinner(recommended: "a", allGatesFailed: false)))
        #expect(run.nodes[judge]?.log.contains { $0.contains("which failed") } != true)
    }

    // MARK: - Fix round 9. A pull request never opens past a failing gate

    private let gateG = NodeKey(node: "g")
    private let openPR = NodeKey(node: "openpr")

    /// `gateAfterPickFlow` with the gate's command and attempts changed.
    private func gateFlow(_ h: Harness, command: String, attempts: Int, viaShell: Bool = false) -> Flow {
        var flow = gateAfterPickFlow(h, viaShell: viaShell)
        let i = flow.nodes.firstIndex { $0.id == "g" }!
        flow.nodes[i].kind = .gate(ShellConfig(command: command, fixAttempts: attempts))
        return flow
    }

    private func stubPR(_ h: Harness) {
        h.hooks.stubGit("push")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: Self.prURL + "\n", stderr: ""))
    }

    private func noPullRequest(_ h: Harness) -> Bool {
        h.hooks.gitCalls("push").isEmpty && h.gh.calls.allSatisfy { !$0.arguments.starts(with: ["pr", "create"]) }
    }

    @Test func gateOutOfFixesAfterThePickStopsBeforeOpenPR() async throws {
        let h = try Harness()
        stubPR(h)
        h.agent.script({ $0.prompt.hasPrefix("Alpha") }, events: finished("sa", "alpha"))
        h.agent.script({ $0.prompt.contains("test -f fixed.txt") }, events: finished("sa", "tried"))
        let id = try await atPick(h, flow: gateFlow(h, command: "echo GATE-OUT; test -f fixed.txt", attempts: 1))
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        #expect(noPullRequest(h))
        #expect(run.nodes[gateG]?.state == .failed("Gate failed: exit 1"))
        #expect(run.nodes[gateG]?.fixAttemptsUsed == 1)
        #expect((run.nodes[openPR]?.state ?? .waiting) == .waiting)
        #expect(run.status == .failed("Gate failed: exit 1"))
        #expect(run.nodes[gateG]?.log.contains { $0.contains("GATE-OUT") } == true)
    }

    @Test func retryOfAFailedGateThatNowPassesOpensThePR() async throws {
        let h = try Harness()
        stubPR(h)
        h.agent.script({ $0.prompt.hasPrefix("Alpha") }, events: finished("sa", "alpha"))
        h.agent.script({ $0.prompt.contains("test -f fixed.txt") }, events: finished("sa", "tried"))
        let id = try await atPick(h, flow: gateFlow(h, command: "test -f fixed.txt", attempts: 1))
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        let failed = try #require(await h.engine.run(id))
        #expect(failed.nodes[gateG]?.state.isFailed == true && noPullRequest(h))
        try "ok".write(to: failed.worktree.appendingPathComponent("fixed.txt"), atomically: true, encoding: .utf8)
        try await h.engine.retry(id, node: gateG)
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        #expect(run.nodes[gateG]?.state == .succeeded)
        #expect(run.nodes[openPR]?.state == .succeeded)
        #expect(run.status == .prOpened("b", url: Self.prURL))
    }

    @Test func gateWithNothingToFixStopsBeforeOpenPR() async throws {
        let h = try Harness()
        stubPR(h)
        var flow = gateAfterPickFlow(h)
        // Only the judge feeds this gate, so there is no agent to send back.
        flow.nodes.append(Node(id: "lone", title: "Lone", kind: .gate(ShellConfig(command: "exit 2", fixAttempts: 3)),
                               position: Point(x: 0, y: 0)))
        flow.wires += [Wire(from: "judge", to: "lone", input: "rec"), Wire(from: "lone", to: "openpr", input: "checked2")]
        h.agent.script({ $0.prompt.hasPrefix("Alpha") }, events: finished("sa", "alpha"))
        h.agent.script({ $0.prompt.contains("test -f fixed.txt") }, effect: { r in
            try "ok".write(to: r.workingDirectory.appendingPathComponent("fixed.txt"), atomically: true, encoding: .utf8)
        }, events: finished("sa", "fixed"))
        let id = try await atPick(h, flow: flow)
        if let offered = await h.engine.run(id), pickIsOffered(offered) { _ = try await h.engine.pick(id, lane: "b") }
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        #expect(noPullRequest(h))
        #expect(run.nodes[NodeKey(node: "lone")]?.state == .failed("Gate failed: exit 2"))
        #expect((run.nodes[openPR]?.state ?? .waiting) == .waiting)
        #expect(run.status == .failed("Gate failed: exit 2"))
    }

    @Test func laneGateFailureStillLeavesTheCandidatePickable() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let run = try #require(await h.engine.run(id))
        #expect(run.lanes.map(\.gatePassed) == [true, true, false])
        #expect(pickIsOffered(run))
        let result = try await h.engine.pick(id, lane: "c")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
    }

    @Test func gateRunnerErrorAfterThePickStopsBeforeOpenPR() async throws {
        let h = try Harness()
        stubPR(h)
        struct Boom: Error, LocalizedError { var errorDescription: String? { "runner broke" } }
        h.hooks.override({ $0.executable == "/bin/sh" && $0.arguments.last == "true" }) { _ in throw Boom() }
        h.agent.script({ $0.prompt.hasPrefix("Alpha") }, events: finished("sa", "alpha"))
        let id = try await atPick(h, flow: gateFlow(h, command: "true", attempts: 1))
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        #expect(noPullRequest(h))
        #expect(run.nodes[gateG]?.state == .failed("runner broke"))
        #expect((run.nodes[openPR]?.state ?? .waiting) == .waiting)
        #expect(run.status == .failed("runner broke"))
    }

    /// The gate flow where A, which feeds the pick and the gate, has its follow-up fail, so picking goes past A and the
    /// gate is skipped.
    private func pickedPastFailedAWithAGate(_ h: Harness, flow: Flow) async throws -> RunID {
        stubPR(h)
        h.agent.script({ $0.prompt.hasPrefix("Alpha") }, events: finished("sa", "alpha"))
        let id = try await atPick(h, flow: flow)
        h.agent.script({ $0.prompt == "More" }, events: finished("sa", "limit", isError: true))
        try await h.engine.followUp(id, node: NodeKey(node: "a"), message: "More")
        await waitFor(h, id, "the pick offered again") { self.pickIsOffered($0) && $0.nodes[NodeKey(node: "a")]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        return id
    }

    @Test func gateSkippedAfterThePickStopsOpenPR() async throws {
        let h = try Harness()
        let id = try await pickedPastFailedAWithAGate(h, flow: gateFlow(h, command: "true", attempts: 1))
        let run = try #require(await h.engine.run(id))
        #expect(run.nodes[gateG]?.state == .waiting)
        #expect(noPullRequest(h))
        #expect(run.nodes[openPR]?.state == .failed("The gate \"G\" has not passed, so no pull request was opened."))
        #expect(run.status == .failed("The gate \"G\" has not passed, so no pull request was opened."))
    }

    @Test func retryAfterAGateWasSkippedReachesThePR() async throws {
        let h = try Harness()
        let id = try await pickedPastFailedAWithAGate(h, flow: gateFlow(h, command: "true", attempts: 1))
        #expect(await h.engine.run(id)?.nodes[openPR]?.state.isFailed == true)
        h.agent.script({ $0.prompt == "More" }, events: finished("sa", "more"))
        try await h.engine.retry(id, node: NodeKey(node: "a"))
        await waitFor(h, id, "the pick offered again") { self.pickIsOffered($0) && $0.nodes[NodeKey(node: "a")]?.state == .succeeded }
        await h.engine.waitForPass(id)
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        #expect(run.nodes[gateG]?.state == .succeeded)
        #expect(run.status == .prOpened("b", url: Self.prURL))
    }

    // MARK: - Fix round 9. The follow-up blocker refuses what the pass would skip

    /// The gate flow with T (fed by A, and by the pick when `afterPick`) feeding Open PR. The gate fails once and A's
    /// fix turn errors, so after the pick A is failed and the gate waits. Returns the run in that state.
    private func gateStrandedByFailedA(_ h: Harness, afterPick: Bool) async throws -> RunID {
        stubPR(h)
        var flow = gateFlow(h, command: "test -f fixed.txt", attempts: 1)
        let at = flow.nodes.firstIndex { $0.id == "g" }!
        flow.nodes.insert(prompt("t", "Tee {a}"), at: at)
        flow.wires += [Wire(from: "a", to: "t", input: "a"), Wire(from: "t", to: "openpr", input: "t")]
        if afterPick { flow.wires.append(Wire(from: "pick", to: "t", input: "pick")) }
        h.agent.script({ $0.prompt.hasPrefix("Alpha") }, events: finished("sa", "alpha"))
        h.agent.script({ $0.prompt.hasPrefix("Tee") }, events: finished("st", "tee"))
        h.agent.script({ $0.prompt.contains("test -f fixed.txt") }, events: finished("sa", "limit", isError: true))
        let id = try await atPick(h, flow: flow)
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        #expect(run.nodes[NodeKey(node: "a")]?.state.isFailed == true)
        #expect(run.nodes[gateG]?.state == .waiting)
        return id
    }

    @Test func followUpRefusedWhenItsOwnStepWouldBeSkipped() async throws {
        let h = try Harness()
        let id = try await gateStrandedByFailedA(h, afterPick: false)
        let t = NodeKey(node: "t")
        let run = try #require(await h.engine.run(id))
        guard run.canFollowUp(t) else { Issue.record("T should be followable here: \(String(describing: run.nodes[t]))"); return }
        await #expect(throws: RunEngineError.followUpBlocked("Retry \"A\" first, then send this.")) {
            try await h.engine.followUp(id, node: t, message: "Again")
        }
        let after = try #require(await h.engine.run(id))
        #expect(snapshot(after) == snapshot(run))
        #expect(after.revision == run.revision)
        #expect(h.agent.requests.allSatisfy { $0.prompt != "Again" })

        h.agent.script({ $0.prompt.contains("test -f fixed.txt") }, effect: { r in
            try "ok".write(to: r.workingDirectory.appendingPathComponent("fixed.txt"), atomically: true, encoding: .utf8)
        }, events: finished("sa", "fixed"))
        h.agent.script({ $0.prompt == "Again" }, events: finished("st", "tee two"))
        try await h.engine.retry(id, node: NodeKey(node: "a"))
        await waitFor(h, id, "the pick offered again") { self.pickIsOffered($0) && $0.nodes[t]?.state == .succeeded }
        await h.engine.waitForPass(id)
        try await h.engine.followUp(id, node: t, message: "Again")
        await waitFor(h, id, "the follow-up") { self.pickIsOffered($0) && $0.nodes[t]?.output == "tee two" }
        #expect(h.agent.requests.contains { $0.prompt == "Again" && $0.resumeSessionID == "st" })
    }

    @Test func followUpRefusedWhenAGateWouldBeSkipped() async throws {
        let h = try Harness()
        let id = try await gateStrandedByFailedA(h, afterPick: true)
        let t = NodeKey(node: "t")
        let run = try #require(await h.engine.run(id))
        guard run.canFollowUp(t) else { Issue.record("T should be followable here: \(String(describing: run.nodes[t]))"); return }
        await #expect(throws: RunEngineError.followUpBlocked("Retry \"A\" first, then send this.")) {
            try await h.engine.followUp(id, node: t, message: "Again")
        }
        let after = try #require(await h.engine.run(id))
        #expect(snapshot(after) == snapshot(run))
        #expect(after.revision == run.revision)

        // Retry A, pick again; Open PR's push fails so T is left finished and the run failed, where a follow-up works.
        h.agent.script({ $0.prompt.contains("test -f fixed.txt") }, effect: { r in
            try "ok".write(to: r.workingDirectory.appendingPathComponent("fixed.txt"), atomically: true, encoding: .utf8)
        }, events: finished("sa", "fixed"))
        h.hooks.stubGit("push", exit: 1, stderr: "remote said no")
        try await h.engine.retry(id, node: NodeKey(node: "a"))
        await waitFor(h, id, "the pick offered again") { self.pickIsOffered($0) }
        await h.engine.waitForPass(id)
        _ = try await h.engine.pick(id, lane: "b")
        await h.engine.waitUntilSettled(id)
        h.hooks.stubGit("push")
        h.agent.script({ $0.prompt == "Again" }, events: finished("st", "tee two"))
        try await h.engine.followUp(id, node: t, message: "Again")
        await h.engine.waitUntilSettled(id)
        let done = try #require(await h.engine.run(id))
        #expect(done.nodes[t]?.output == "tee two")
        #expect(done.status == .prOpened("b", url: Self.prURL))
    }
}
