import Foundation
import Testing
@testable import MetalFlowCore

/// Follow-up edge cases: cancelling, failing, the judge's verdict, and the pick.
@Suite struct RunEngineFinalFixTests {
    typealias Harness = RunEngineTests.Harness

    private let implementA = NodeKey(node: "implement", lane: "a")
    private let judge = NodeKey(node: "judge")
    private let pick = NodeKey(node: "pick")
    private struct Boom: Error, LocalizedError { var errorDescription: String? { "usage limit" } }

    private func finished(_ session: String, _ text: String, isError: Bool = false) -> [AgentEvent] {
        [.started(sessionID: session), .finished(AgentResult(
            sessionID: session, text: text, isError: isError, deniedTools: [], costUSD: 0, turns: 1))]
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

    private func pickIsOffered(_ run: Run, recommended: LaneID? = "b") -> Bool {
        run.status == .needsYou && run.nodes[pick]?.state == .needsYou(.pickWinner(recommended: recommended, allGatesFailed: false))
    }

    // MARK: - Cancelling a follow-up

    @Test func cancellingAFollowUpLeavesItResumable() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        h.agent.script({ $0.prompt == "Tweak" }, hold: hold, events: finished("s", "tweaked"))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        await waitFor(h, id, "the turn to start") { $0.nodes[self.implementA]?.replyInFlight == "Tweak" }

        await h.engine.cancel(id)
        let stopped = try #require(await h.engine.run(id))
        #expect(stopped.status == .needsYou)
        #expect(stopped.nodes[implementA]?.state == .interrupted)
        await h.engine.waitForPass(id)

        h.agent.script({ $0.prompt == "Continue where you left off." }, events: finished("s", "tweaked"))
        try await h.engine.resumeInterrupted(id)
        let run = await waitFor(h, id, "the run to reach the pick again") { self.pickIsOffered($0) }
        #expect(run.nodes[implementA]?.state == .succeeded)
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
    }

    @Test func cancellingARunWithNoFollowUpStillCancels() async throws {
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let h = try Harness(planHold: hold)
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        await waitFor(h, id, "plan running") { $0.nodes[NodeKey(node: "plan")]?.state == .running }
        #expect(await h.engine.run(id)?.followedUp == false)
        await h.engine.cancel(id)
        #expect(await h.engine.run(id)?.status == .cancelled)
        await h.engine.waitForPass(id)
    }

    @Test func followedUpDecodesWhenAbsentAndIsOnlyWrittenWhenTrue() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        var run = try #require(await h.engine.run(id))
        let plain = try JSONEncoder().encode(run)
        #expect(!String(decoding: plain, as: UTF8.self).contains("followedUp"))
        #expect(try JSONDecoder().decode(Run.self, from: plain).followedUp == false)
        run.followedUp = true
        #expect(try JSONDecoder().decode(Run.self, from: JSONEncoder().encode(run)).followedUp)
    }

    // MARK: - A failed turn keeps its message

    @Test(arguments: [false, true])
    func failedFollowUpRetriesWithTheSameSessionAndMessage(thrown: Bool) async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let session = try #require(await h.engine.run(id)?.nodes[implementA]?.sessionID)
        if thrown {
            h.agent.script({ $0.prompt == "Tweak" }, events: [.started(sessionID: session)], thenThrowing: Boom())
        } else {
            h.agent.script({ $0.prompt == "Tweak" }, events: finished(session, "usage limit", isError: true))
        }
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        let failed = await waitFor(h, id, "the turn to fail") { $0.nodes[self.implementA]?.state.isFailed == true
            && $0.nodes[self.pick]?.state != .running }
        await h.engine.waitForPass(id)
        #expect(failed.nodes[implementA]?.pendingReply == "Tweak")
        #expect(failed.nodes[implementA]?.replyInFlight == nil)

        h.agent.script({ $0.prompt == "Tweak" }, events: finished(session, "tweaked"))
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: implementA)
        let run = await waitFor(h, id, "the retry to finish") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.state == .succeeded }
        let sent = h.agent.requests.dropFirst(before).filter { $0.workingDirectory.lastPathComponent == "a" }
        #expect(sent.count == 1)
        #expect(sent.first?.prompt == "Tweak")
        #expect(sent.first?.resumeSessionID == session)
        #expect(run.nodes[implementA]?.pendingReply == nil && run.nodes[implementA]?.replyInFlight == nil)
    }

    @Test func interruptedFollowUpStillContinues() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let session = try #require(await h.engine.run(id)?.nodes[implementA]?.sessionID)
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        h.agent.script({ $0.prompt == "Tweak" }, hold: hold, events: finished(session, "tweaked"))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        await waitFor(h, id, "the turn to start") { $0.nodes[self.implementA]?.replyInFlight == "Tweak" }
        await h.engine.suspend(id)
        await h.engine.waitForPass(id)
        let cut = try #require(await h.engine.run(id))
        #expect(cut.nodes[implementA]?.state == .interrupted)
        #expect(cut.nodes[implementA]?.pendingReply == nil)

        h.agent.script({ $0.prompt == "Continue where you left off." }, events: finished(session, "tweaked"))
        let before = h.agent.requests.count
        try await h.engine.resumeInterrupted(id)
        let run = await waitFor(h, id, "the pick") { self.pickIsOffered($0) }
        let sent = h.agent.requests.dropFirst(before).filter { $0.workingDirectory.lastPathComponent == "a" }
        #expect(sent.map(\.prompt) == ["Continue where you left off."])
        #expect(sent.first?.resumeSessionID == session)
        #expect(run.nodes[implementA]?.replyInFlight == nil)
    }

    @Test func followUpIsLogged() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        h.agent.script({ $0.prompt.hasPrefix("Tweak") }, events: finished("s", "tweaked"))
        let long = "Tweak " + String(repeating: "x", count: 300)
        try await h.engine.followUp(id, node: implementA, message: long)
        let run = await waitFor(h, id, "the pick") { self.pickIsOffered($0) }
        #expect(run.nodes[implementA]?.log.contains("↩ follow-up: " + String(long.prefix(200))) == true)
        #expect(run.nodes[implementA]?.log.contains { $0.hasPrefix("↩ follow-up: ") && $0.count > 213 } == false)
    }

    @Test func retryAfterACleanFinishStillStartsFresh() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        h.agent.script({ $0.prompt == "Tweak" }, events: finished("s", "tweaked"))
        try await h.engine.followUp(id, node: implementA, message: "Tweak")
        await waitFor(h, id, "the pick") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.output == "tweaked" }
        await h.engine.waitForPass(id)
        await h.engine.setDirect(id) { $0.nodes[self.implementA]?.state = .failed("later trouble") }
        let before = h.agent.requests.count
        try await h.engine.retry(id, node: implementA)
        await waitFor(h, id, "the retry to finish") { self.pickIsOffered($0) && $0.nodes[self.implementA]?.state == .succeeded }
        let sent = h.agent.requests.dropFirst(before).filter { $0.workingDirectory.lastPathComponent == "a" }
        #expect(sent.count == 1)
        #expect(sent.first?.resumeSessionID == nil)
        #expect(sent.first?.prompt.contains("Fix this GitHub issue") == true)
    }

    // MARK: - The judge keeps its verdict

    @Test func judgeFollowUpWithoutARecommendationKeepsIt() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let verdict = try #require(await h.engine.run(id)?.nodes[judge]?.output)
        #expect(await h.engine.run(id)?.recommendation == "b")
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        h.agent.script({ $0.prompt == "RECOMMEND: a? Explain more" }, hold: hold, events: finished("s", "More words, no pick."))
        try await h.engine.followUp(id, node: judge, message: "RECOMMEND: a? Explain more")
        let held = await waitFor(h, id, "the judge to run") { $0.nodes[self.judge]?.state == .running }
        #expect(held.recommendation == "b", "asking a question does not withdraw the recommendation")
        release.finish()
        let run = await waitFor(h, id, "the pick") { self.pickIsOffered($0) }
        await h.engine.waitForPass(id)
        #expect(run.recommendation == "b")
        #expect(run.nodes[judge]?.output == verdict + "\n\nFollow-up: RECOMMEND: a? Explain more\n\nMore words, no pick.")
        #expect(run.nodes[judge]?.followUpBase == nil)
    }

    @Test func judgeFollowUpWithANewRecommendationUpdatesIt() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        h.agent.script({ $0.prompt == "Reconsider" }, events: finished("s", "On reflection.\nRECOMMEND: a"))
        try await h.engine.followUp(id, node: judge, message: "Reconsider")
        let run = await waitFor(h, id, "the pick") { self.pickIsOffered($0, recommended: "a") }
        #expect(run.recommendation == "a")
        #expect(run.nodes[judge]?.output == "On reflection.\nRECOMMEND: a")
        #expect(run.nodes[judge]?.followUpBase == nil)
    }

    @Test func failedJudgeFollowUpRetriesWithTheVerdictStillAttached() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        let verdict = try #require(await h.engine.run(id)?.nodes[judge]?.output)
        h.agent.script({ $0.prompt == "Explain" }, events: finished("s", "limit", isError: true))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        await waitFor(h, id, "the judge to fail") { $0.nodes[self.judge]?.state.isFailed == true && $0.status != .running }
        await h.engine.waitForPass(id)
        h.agent.script({ $0.prompt == "Explain" }, events: finished("s", "Because."))
        try await h.engine.retry(id, node: judge)
        let run = await waitFor(h, id, "the pick") { self.pickIsOffered($0) && $0.nodes[self.judge]?.state == .succeeded }
        #expect(run.nodes[judge]?.output == verdict + "\n\nFollow-up: Explain\n\nBecause.")
        #expect(run.recommendation == "b")
    }

    // MARK: - A failed follow-up does not lock the pick

    @Test func failedJudgeFollowUpStillOffersThePick() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        h.agent.script({ $0.prompt == "Explain" }, events: finished("s", "limit", isError: true))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        let run = await waitFor(h, id, "the pick to be offered") { self.pickIsOffered($0) && $0.nodes[self.judge]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        #expect(run.pickToRestore == nil)
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
    }

    @Test func aFailedJudgeCanStillBeRetriedWhileThePickIsOffered() async throws {
        let h = try Harness()
        let id = try await atPick(h)
        h.agent.script({ $0.prompt == "Explain" }, events: finished("s", "limit", isError: true))
        try await h.engine.followUp(id, node: judge, message: "Explain")
        await waitFor(h, id, "the pick to be offered") { self.pickIsOffered($0) && $0.nodes[self.judge]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        // The retry fails again: the pick comes back again.
        try await h.engine.retry(id, node: judge)
        await waitFor(h, id, "the second failure") { self.pickIsOffered($0) && $0.nodes[self.judge]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        h.agent.script({ $0.prompt == "Explain" }, events: finished("s", "Because."))
        try await h.engine.retry(id, node: judge)
        let run = await waitFor(h, id, "the retry to succeed") { self.pickIsOffered($0) && $0.nodes[self.judge]?.state == .succeeded }
        #expect(run.nodes[judge]?.output?.hasSuffix("Because.") == true)
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
    }

    @Test func aFailedPromptAfterTheJudgeStillOffersThePick() async throws {
        let h = try Harness()
        var flow = h.flow()
        flow.nodes.insert(Node(id: "notes", title: "Notes", kind: .prompt(PromptConfig(
            model: "sonnet", prompt: "Summarize {rec}", candidates: [], allowedTools: [], maxTurns: nil)),
                               position: Point(x: 0, y: 0)), at: flow.nodes.firstIndex { $0.id == "pick" }!)
        flow.wires.append(Wire(from: "judge", to: "notes", input: "rec"))
        h.agent.script({ $0.prompt.hasPrefix("Summarize") }, events: finished("sn", "summary"))
        let id = try await atPick(h, flow: flow)
        let notes = NodeKey(node: "notes")
        #expect(pickIsOffered(try #require(await h.engine.run(id))))
        h.agent.script({ $0.prompt == "Shorter" }, events: finished("sn", "limit", isError: true))
        try await h.engine.followUp(id, node: notes, message: "Shorter")
        let run = await waitFor(h, id, "the pick to be offered") { self.pickIsOffered($0) && $0.nodes[notes]?.state.isFailed == true }
        await h.engine.waitForPass(id)
        #expect(run.pickToRestore == nil)
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
    }
}
