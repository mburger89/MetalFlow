import Foundation
import MetalFlowCore
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct FinalFixAppTests {
    let pick = NodeKey(node: "pick")
    let implementA = NodeKey(node: "implement", lane: "a")

    func atPick(_ id: RunID = RunID(), revision: Int = 1) -> Run {
        makeRun("pick", status: .needsYou, revision: revision, id: id, nodes: [
            implementA: NodeRun(state: .succeeded, output: "done", sessionID: "s"),
            pick: NodeRun(state: .needsYou(.pickWinner(recommended: "a", allGatesFailed: false)))])
    }

    func following(_ run: Run, revision: Int) -> Run {
        var next = run
        next.revision = revision
        next.status = .running
        next.nodes[pick]?.state = .waiting
        return next
    }

    func offered(_ run: Run, revision: Int) -> Run {
        var next = run
        next.revision = revision
        next.status = .needsYou
        next.nodes[pick]?.state = .needsYou(.pickWinner(recommended: "a", allGatesFailed: false))
        return next
    }

    func model(_ client: FakeEngineClient, pause: @escaping @Sendable () async -> Void = {}) -> AppModel {
        AppModel(client: client, notifier: NoopNotifier(), pause: pause)
    }

    // MARK: - Picking on a stale card

    @Test func stalePickShowsTheNoticeAndUpdates() async {
        let client = FakeEngineClient()
        let m = model(client)
        let shown = atPick(revision: 4)
        m.apply(shown)
        var newer = following(shown, revision: 7)
        newer.title = "changed elsewhere"
        await client.setReload(newer)
        await client.setFailure(RunEngineError.runChanged)
        let result = await m.pick(shown.id, lane: "a")
        #expect(result == nil)
        #expect(await client.pickRevisions == [4], "the app passes the revision it shows")
        #expect(m.notice?.text == "This run changed since you last saw it. Look again before picking.")
        #expect(m.runs[shown.id]?.revision == 7 && m.runs[shown.id]?.title == "changed elsewhere")
        #expect(m.pickOutcomes[shown.id] == nil, "the notice is the message, not a line on a card")
        #expect(m.pickingRun == nil)
    }

    @Test func pollPicksUpAChangeFromAnotherProcess() async {
        let (ticks, tick) = AsyncStream.makeStream(of: Void.self)
        let run = atPick(revision: 1)
        let client = FakeEngineClient(restored: [run])
        let m = model(client, pause: { for await _ in ticks { return } })
        let start = Task { await m.start() }
        await m.waitUntilReady()
        #expect(m.runningElsewhere.isEmpty)
        // Another mflow follows the run up: it is running there, and the pick is withdrawn.
        await client.setReload(following(run, revision: 3))
        await client.setElsewhere([run.id])
        tick.yield()
        await waitUntil("the poll to show the other process's run") {
            m.runs[run.id]?.revision == 3 && m.runningElsewhere == [run.id]
        }
        #expect(m.runs[run.id]?.status == .running)
        #expect(m.runningElsewhere == [run.id])
        #expect(m.running.map(\.id) == [run.id])
        // It finishes there: the pick is offered again and the lock is gone.
        await client.setReload(offered(run, revision: 5))
        await client.setElsewhere([])
        tick.yield()
        await waitUntil("the poll to show the pick again") { m.runs[run.id]?.revision == 5 && m.runningElsewhere.isEmpty }
        #expect(m.runningElsewhere.isEmpty)
        #expect(m.canPick(m.runs[run.id]!))
        await client.finish()
        await start.value
        tick.finish()
    }

    @Test func refreshLeavesFinishedRunsAlone() async {
        let merged = makeRun("merged", status: .merged("a"), revision: 2)
        let open = makeRun("open", status: .completed, revision: 2)
        let client = FakeEngineClient()
        let m = model(client)
        m.apply(merged)
        m.apply(open)
        await m.refreshElsewhere()
        #expect(await client.calls.filter { $0 == "reload" }.count == 1)
    }

    // MARK: - Stale pick outcomes

    @Test func followUpClearsAConflictLine() async {
        let client = FakeEngineClient()
        await client.setPick(.conflict(files: ["a.swift"]))
        let m = model(client)
        let run = atPick()
        m.apply(run)
        await m.pick(run.id, lane: "a")
        #expect(m.pickOutcomes[run.id]?["a"] == .conflict(["a.swift"]))
        // A follow-up withdraws the pick, then offers it again: the old line is about candidates that changed.
        m.apply(following(run, revision: 2))
        #expect(m.pickOutcomes[run.id] == nil)
        m.apply(offered(run, revision: 3))
        #expect(m.pickOutcomes[run.id] == nil)
    }

    @Test func conflictLineStaysWhileNothingChanged() async {
        let client = FakeEngineClient()
        await client.setPick(.conflict(files: ["a.swift"]))
        let m = model(client)
        let run = atPick()
        m.apply(run)
        await m.pick(run.id, lane: "a")
        var same = run
        same.revision = 2
        same.title = "renamed"
        m.apply(same)
        #expect(m.pickOutcomes[run.id]?["a"] == .conflict(["a.swift"]))
    }

    @Test func aLineStaysWhileAPickIsInFlight() async {
        let client = FakeEngineClient()
        let m = model(client)
        let run = atPick()
        m.apply(run)
        m.pickOutcomes[run.id] = ["b": .conflict(["b.swift"])]
        await client.holdPicks()
        let task = Task { await m.pick(run.id, lane: "a") }
        await waitUntil("the pick to start") { m.pickingRun != nil }
        var merging = run
        merging.revision = 2
        merging.nodes[pick]?.state = .succeeded
        m.apply(merging)
        #expect(m.pickOutcomes[run.id]?["b"] == .conflict(["b.swift"]))
        await client.releasePicks()
        _ = await task.value
    }

    // MARK: - Forgetting a run

    @Test func forgettingARunClearsItsDrafts() async {
        let client = FakeEngineClient()
        let m = model(client)
        let run = atPick()
        let other = atPick()
        m.apply(run)
        m.apply(other)
        for r in [run, other] {
            let key = AppModel.draftKey(r.id, implementA)
            m.followUpDrafts[key] = "more"
            m.answerDrafts[key] = "yes"
            m.followingUp.insert(key)
        }
        await client.setVanished([run.id])
        await m.discoverRuns()
        let gone = AppModel.draftKey(run.id, implementA), kept = AppModel.draftKey(other.id, implementA)
        #expect(m.followUpDrafts[gone] == nil && m.answerDrafts[gone] == nil && !m.followingUp.contains(gone))
        #expect(m.followUpDrafts[kept] == "more" && m.answerDrafts[kept] == "yes" && m.followingUp.contains(kept))
    }
}
