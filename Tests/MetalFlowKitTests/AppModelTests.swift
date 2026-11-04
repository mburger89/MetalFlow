import Foundation
import Testing
import MetalFlowCore
@testable import MetalFlowKit

@MainActor
@Suite struct AppModelTests {
    func model(_ client: FakeEngineClient = FakeEngineClient()) -> AppModel {
        AppModel(client: client, notifier: NoopNotifier(), clock: { Date(timeIntervalSince1970: 5_000) })
    }

    @Test func applyBucketsRunsByStatus() {
        let m = model()
        let a = makeRun("a", status: .running, createdAt: Date(timeIntervalSince1970: 1))
        let b = makeRun("b", status: .needsYou, createdAt: Date(timeIntervalSince1970: 2))
        let c = makeRun("c", status: .merged("b"), createdAt: Date(timeIntervalSince1970: 3))
        for r in [a, b, c] { m.apply(r) }
        #expect(m.running.map(\.title) == ["a"])
        #expect(m.needsYou.map(\.title) == ["b"])
        #expect(m.finished.map(\.title) == ["c"])
        #expect(m.order == [c.id, b.id, a.id])

        var moved = a
        moved.status = .needsYou
        moved.revision = 1
        m.apply(moved)
        #expect(m.running.isEmpty)
        #expect(m.needsYou.map(\.title) == ["b", "a"])
    }

    @Test func staleRevisionIsIgnored() {
        let m = model()
        var r = makeRun("a", status: .running, revision: 5)
        m.apply(r)
        r.status = .needsYou
        r.revision = 5
        m.apply(r)
        #expect(m.runs[r.id]?.status == .running)
        r.revision = 4
        m.apply(r)
        #expect(m.runs[r.id]?.status == .running)
        r.revision = 6
        m.apply(r)
        #expect(m.runs[r.id]?.status == .needsYou)
        #expect(m.needsYou.count == 1)
    }

    @Test func restoredNeedsYouRunsLandInNeedsYouBucket() async {
        var node = NodeRun(state: .interrupted)
        node.log = ["▸ Edit Foo.swift"]
        let run = makeRun("cut short", status: .needsYou, revision: 3, nodes: [NodeKey(node: "plan"): node])
        let client = FakeEngineClient(restored: [run])
        let m = model(client)
        let task = Task { await m.start() }
        await client.finish()
        await task.value
        #expect(m.needsYou.map(\.id) == [run.id])
        #expect(m.running.isEmpty)
        #expect(m.activity.isEmpty)   // restoring is not news
    }

    @Test func activityRecordsNeedsYouAndGateFailures() {
        let m = model()
        let flow = BuiltinFlows.fixGitHubIssue
        #expect(flow.node("gate") != nil)
        let first = makeRun("fix", status: .running, revision: 1,
                            nodes: [NodeKey(node: "implement", lane: "a"): NodeRun(state: .running, log: ["▸ Edit Foo.swift"])])
        m.apply(first)
        #expect(m.activity.map(\.text) == ["edited Foo.swift", "started"])

        var second = first
        second.revision = 2
        second.nodes[NodeKey(node: "implement", lane: "a")]?.appendLog("▸ Edit Bar.swift")
        m.apply(second)
        #expect(m.activity.first?.text == "edited Bar.swift")

        var third = second
        third.revision = 3
        for lane in ["a", "b", "c"] { third.nodes[NodeKey(node: "gate", lane: lane)] = NodeRun(state: .failed("tests")) }
        m.apply(third)
        #expect(m.activity.first?.text == "gate failed on 3 of 3 candidates")
        #expect(m.activity.first?.kind == .bad)

        var fourth = third
        fourth.revision = 4
        fourth.status = .needsYou
        fourth.nodes[NodeKey(node: "pick")] = NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
        m.apply(fourth)
        #expect(m.activity.first?.text == "judge recommends b — waiting on you")
        #expect(m.activity.first?.kind == .needsYou)
        #expect(m.activity.first?.runTitle == "fix")
    }

    @Test func firstLogLineWithRunningTransitionIsReported() {
        let m = model()
        let key = NodeKey(node: "implement", lane: "a")
        m.apply(makeRun("fix", revision: 1, nodes: [key: NodeRun(state: .waiting)]))
        m.apply(makeRun("fix", revision: 2, id: m.order[0], nodes: [key: NodeRun(state: .running, log: ["▸ Edit Foo.swift"])]))
        #expect(m.activity.first?.text == "edited Foo.swift")
    }

    @Test func startRunsOnlyOnce() async {
        let client = FakeEngineClient()
        let m = model(client)
        let task = Task { await m.start() }
        await client.finish()
        await task.value
        await m.start()
        #expect(await client.calls == ["restore"])
    }

    @Test func activityIsARingBuffer() {
        let m = model()
        for i in 0..<250 { m.apply(makeRun("r\(i)", createdAt: Date(timeIntervalSince1970: Double(i)))) }
        #expect(m.activity.count == AppModel.activityLimit)
        #expect(m.activity.first?.runTitle == "r249")
    }

    @Test func applyManyUpdatesIsCheap() {
        let m = model()
        var runs = (0..<20).map { makeRun("r\($0)", createdAt: Date(timeIntervalSince1970: Double($0))) }
        for r in runs { m.apply(r) }
        let base = m.rebuildCount
        for revision in 1...200 {
            for i in runs.indices {
                runs[i].revision = revision
                m.apply(runs[i])
            }
        }
        let updates = 20 * 200
        // Each same-bucket update writes exactly one bucket; none rebuilds the others.
        #expect(m.rebuildCount - base == updates)
        #expect(m.running.count == 20)
        #expect(m.running.allSatisfy { $0.revision == 200 })

        // A stale snapshot touches nothing.
        let before = m.rebuildCount
        m.apply(runs[0])
        #expect(m.rebuildCount == before)
    }

    @Test func actionErrorsBecomeNotice() async {
        let client = FakeEngineClient()
        let m = model(client)
        await client.setFailure(FakeFailure())
        let id = RunID()
        await m.resume(id)
        #expect(m.notice?.text == "engine said no")
        m.notice = nil
        await m.discard(id)
        #expect(m.notice?.text == "engine said no")
        m.notice = nil
        #expect(await m.launch(flow: BuiltinFlows.fixGitHubIssue, location: .builtin, values: ["issue": "1", "repo": "/r"]) == nil)
        #expect(m.notice?.kind == .error)
        m.notice = nil
        await m.pick(id, lane: "a")
        #expect(m.notice == nil, "a pick error shows on the card, not as a notice")
        #expect(m.pickOutcomes[id]?["a"] == .failed("engine said no"))
    }

    @Test func followUpForwardsToTheClient() async {
        let client = FakeEngineClient()
        let m = model(client)
        let ok = await m.followUp(RunID(), node: NodeKey(node: "implement", lane: "a"), message: "also add tests")
        #expect(ok)
        #expect(await client.calls == ["followUp(implement@a, also add tests)"])
        #expect(m.notice == nil)
    }

    @Test func followUpReturnsFalseWhenTheClientThrows() async {
        let client = FakeEngineClient()
        let m = model(client)
        await client.setFailure(FakeFailure())
        let ok = await m.followUp(RunID(), node: NodeKey(node: "implement", lane: "a"), message: "again")
        #expect(!ok)
        #expect(m.notice?.text == "engine said no")
    }

    @Test func conflictingPickBecomesOutcome() async {
        let client = FakeEngineClient()
        await client.setPick(.conflict(files: ["a.swift"]))
        let m = model(client)
        let id = RunID()
        await m.pick(id, lane: "a")
        #expect(m.notice == nil)
        #expect(m.pickOutcomes[id]?["a"] == .conflict(["a.swift"]))
    }

    @Test func workingOnTracksOpenAndDismiss() {
        let m = model()
        let id = RunID()
        m.open(run: id)
        m.open(run: id)
        #expect(m.workingOn == [.run(id)])
        #expect(m.selectedRun == id)
        m.dismiss(.run(id))
        #expect(m.workingOn.isEmpty)
        #expect(m.selectedRun == nil)
    }
}
