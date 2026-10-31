import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct RunDetailTests {
    func lanes() -> [Lane] {
        [Lane(id: "a", model: "sonnet", branch: "mf/x-a", worktree: URL(fileURLWithPath: "/wt/a"), gatePassed: true, added: 12, removed: 3),
         Lane(id: "b", model: "opus", branch: "mf/x-b", worktree: URL(fileURLWithPath: "/wt/b"), gatePassed: false, added: 40, removed: 9),
         Lane(id: "c", model: "haiku", branch: "mf/x-c", worktree: URL(fileURLWithPath: "/wt/c"), gatePassed: nil)]
    }

    func pickRun(allGatesFailed: Bool = false, extra: [NodeKey: NodeRun] = [:]) -> Run {
        var run = makeRun("pick", status: .needsYou, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: allGatesFailed))),
            NodeKey(node: "judge"): NodeRun(state: .succeeded, output: "B is the most complete.")
        ].merging(extra) { a, _ in a })
        run.lanes = lanes()
        run.recommendation = "b"
        return run
    }

    func fixture(_ run: Run, others: [Run] = []) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: [run] + others, repos: [URL(fileURLWithPath: "/repo")])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.open(run: run.id)
        try await window.runUntilIdle()
        return (model, client, window)
    }

    func press(_ id: String, in window: TestWindow) async throws {
        try window.click(window.element(identifier: id))
        try await window.runUntilIdle()
    }

    @Test func candidatesShowRecommendation() async throws {
        let (_, _, window) = try await fixture(pickRun())
        _ = try window.element(identifier: "detail")
        for lane in ["a", "b", "c"] { _ = try window.element(identifier: "cand.\(lane)") }
        _ = try window.element(identifier: "cand.b.recommended")
        #expect((try? window.element(identifier: "cand.a.recommended")) == nil)
        #expect(try window.element(identifier: "cand.a.gate").value == "Tests passed")
        #expect(try window.element(identifier: "cand.b.gate").value == "Tests failed")
        #expect(try window.element(identifier: "cand.c.gate").value == "No gate")
        #expect(try window.element(identifier: "cand.a.added").value == "+12")
        #expect(try window.element(identifier: "cand.b.model").value == "opus")
        #expect(try window.element(identifier: "detail.judge").value == "B is the most complete.")
        #expect((try? window.element(identifier: "detail.allGatesFailed")) == nil)
        #expect(try window.element(identifier: "cand.b.pick").isEnabled)
    }

    @Test func allGatesFailedShowsBanner() async throws {
        let (_, _, window) = try await fixture(pickRun(allGatesFailed: true))
        #expect(try window.element(identifier: "detail.allGatesFailed").value == "No candidate passed the tests")
    }

    @Test func pickCallsClientOnlyOnClick() async throws {
        let (model, client, window) = try await fixture(pickRun())
        #expect(await !client.calls.contains { $0.hasPrefix("pick") }, "opening the detail never picks")
        try await press("cand.a.pick", in: window)
        #expect(await client.calls.filter { $0 == "pick(a)" }.count == 1)
        #expect(model.pickOutcomes.values.first?["a"] == .merged)
    }

    @Test func mergedReturnsToDashboard() async throws {
        let run = pickRun()
        let (model, _, window) = try await fixture(run)
        try await press("cand.b.pick", in: window)
        #expect(model.selectedRun == nil)
        _ = try window.element(identifier: "dashboard")
        #expect(model.workingOn.contains(.run(run.id)), "going back keeps the run open")
    }

    @Test func pickBlockedShowsReason() async throws {
        let (model, client, window) = try await fixture(pickRun())
        await client.setPick(.blockedDirty(checkout: URL(fileURLWithPath: "/repo")))
        try await press("cand.a.pick", in: window)
        #expect(try window.element(identifier: "cand.a.result").value
            == "Your checkout at /repo has uncommitted changes — commit or stash, then pick again.")
        #expect(model.selectedRun != nil)
        #expect(model.notice == nil)
    }

    @Test func conflictShowsFiles() async throws {
        let (_, client, window) = try await fixture(pickRun())
        await client.setPick(.conflict(files: ["a.swift", "b.swift"]))
        try await press("cand.a.pick", in: window)
        #expect(try window.element(identifier: "cand.a.result").value == "Conflicts in: a.swift, b.swift — nothing was merged.")
    }

    @Test func pickErrorShowsInline() async throws {
        let (model, client, window) = try await fixture(pickRun())
        await client.setFailure(FakeFailure())
        try await press("cand.a.pick", in: window)
        #expect(try window.element(identifier: "cand.a.result").value == "engine said no")
        #expect(model.notice == nil)
        // A new attempt clears the old outcome.
        await client.setFailure(nil)
        await client.setPick(.conflict(files: ["x"]))
        try await press("cand.a.pick", in: window)
        #expect(try window.element(identifier: "cand.a.result").value == "Conflicts in: x — nothing was merged.")
    }

    @Test func pickIgnoresSecondClickWhileInFlight() async throws {
        let run = pickRun()
        let (model, client, _) = try await fixture(run)
        await client.holdPicks()
        let first = Task { await model.pick(run.id, lane: "a") }
        await waitUntil("the pick to be in flight") { model.pickingRun != nil }
        // The second call must return at once with the first still held. The fake holds only the first call,
        // so a broken guard shows up as a recorded pick-start(b) instead of a hang.
        let second = Task { await model.pick(run.id, lane: "b") }
        let result = await second.value
        let started = await client.calls.filter { $0.hasPrefix("pick-start") }
        await client.releasePicks()
        _ = await first.value
        #expect(result == nil, "the second pick is a no-op")
        #expect(started == ["pick-start(a)"], "the second pick never reached the client")
        #expect(model.pickingRun == nil)
    }

    @Test func aNewPickClearsTheLanesOldOutcome() async throws {
        let (model, client, window) = try await fixture(pickRun())
        await client.setPick(.conflict(files: ["x"]))
        try await press("cand.a.pick", in: window)
        _ = try window.element(identifier: "cand.a.result")
        await client.holdPicks()
        let again = Task { await model.pick(model.selectedRun!, lane: "a") }
        await waitUntil("the pick to be in flight") { model.pickingRun != nil }
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "cand.a.result")) == nil, "cleared while the new attempt runs")
        await client.releasePicks()
        _ = await again.value
        try await window.runUntilIdle()
        _ = try window.element(identifier: "cand.a.result")
    }

    @Test func pickButtonsDisableWhileInFlight() async throws {
        let run = pickRun()
        let (model, client, window) = try await fixture(run)
        await client.holdPicks()
        let task = Task { await model.pick(run.id, lane: "a") }
        await waitUntil("the pick to be in flight") { model.pickingRun != nil }
        try await window.runUntilIdle()
        for lane in ["a", "b", "c"] {
            #expect(try !window.element(identifier: "cand.\(lane).pick").isEnabled)
        }
        await client.releasePicks()
        _ = await task.value
    }

    @Test func branchFromHereAsksForName() async throws {
        let run = pickRun()
        let (model, client, window) = try await fixture(run)
        #expect((try? window.element(identifier: "cand.a.branch.name")) == nil)
        try await press("cand.a.branch", in: window)
        _ = try window.element(identifier: "cand.a.branch.name")
        #expect(try !window.element(identifier: "cand.a.branch.ok").isEnabled)
        try window.click(window.element(identifier: "cand.a.branch.name"))
        window.typeText("   ")
        try await window.runUntilIdle()
        #expect(try !window.element(identifier: "cand.a.branch.ok").isEnabled, "whitespace is not a name")
        window.typeText("keep-me")
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "cand.a.branch.name").value == "   keep-me")
        #expect(try window.element(identifier: "cand.a.branch.ok").isEnabled)
        #expect(await !client.calls.contains { $0.hasPrefix("branch") })
        try await press("cand.a.branch.ok", in: window)
        #expect(await client.calls.contains("branch(a, keep-me)"))
        #expect(!model.isBranchOpen(run.id, "a"))
    }

    @Test func discardNeedsConfirmation() async throws {
        let run = pickRun()
        let (model, client, window) = try await fixture(run)
        try await press("detail.discard", in: window)
        let alert = try #require(window.presentedAlert)
        #expect(alert.title == "Discard this run?")
        #expect(await !client.calls.contains("discard"), "nothing happens before the confirmation")
        try window.respondToAlert(button: "Cancel")
        try await window.runUntilIdle()
        #expect(await !client.calls.contains("discard"))
        #expect(model.selectedRun == run.id)

        try await press("detail.discard", in: window)
        try window.respondToAlert(button: "Discard")
        try await window.runUntilIdle()
        #expect(await client.calls.contains("discard"))
        #expect(model.selectedRun == nil)
    }

    @Test func backReturnsToDashboardKeepingTheRun() async throws {
        let run = pickRun()
        let (model, _, window) = try await fixture(run)
        try await press("detail.back", in: window)
        #expect(model.selectedRun == nil)
        #expect(model.workingOn.contains(.run(run.id)))
        _ = try window.element(identifier: "dashboard")
    }

    @Test func runningRunOffersCancelNotDiscard() async throws {
        let run = makeRun("busy", status: .running, nodes: [NodeKey(node: "plan"): NodeRun(state: .running)])
        let (_, client, window) = try await fixture(run)
        #expect((try? window.element(identifier: "detail.discard")) == nil)
        try await press("detail.cancel", in: window)
        #expect(await client.calls.contains("cancel"))
    }

    @Test func settledRunOffersDiscardNotCancel() async throws {
        let (_, _, window) = try await fixture(pickRun())
        _ = try window.element(identifier: "detail.discard")
        #expect((try? window.element(identifier: "detail.cancel")) == nil)
    }

    @Test func runLockedElsewhereHasNeitherCancelNorDiscard() async throws {
        let run = makeRun("theirs", status: .running)
        let client = FakeEngineClient(restored: [run], repos: [URL(fileURLWithPath: "/repo")])
        await client.setElsewhere([run.id])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.open(run: run.id)
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "detail.cancel")) == nil)
        #expect((try? window.element(identifier: "detail.discard")) == nil)
        #expect(try window.element(identifier: "detail.status").value == "Running in another mflow")
    }

    @Test func deniedToolsAllowContinues() async throws {
        let run = makeRun("denied", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.deniedTools(["Bash(git:*)", "Edit"])))])
        let (_, client, window) = try await fixture(run)
        try await press("detail.node.plan.allow", in: window)
        #expect(await client.calls.contains("answer(plan, Continue., [\"Bash(git:*)\", \"Edit\"])"))
    }

    @Test func questionNodeShowsAnswerBox() async throws {
        let run = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let (_, _, window) = try await fixture(run)
        _ = try window.element(identifier: "answer.\(run.id.rawValue).plan.field")
    }

    @Test func viewDiffLoadsAndShowsOneAtATime() async throws {
        let run = pickRun()
        let (model, client, window) = try await fixture(run)
        await client.setDiff("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
        try await press("cand.a.diff", in: window)
        #expect(model.openDiff == DiffKey(run: run.id, lane: "a"))
        _ = try window.element(identifier: "diff.hunk.0")
        _ = try window.element(identifier: "diff.hunk.1")
        try await press("cand.b.diff", in: window)
        #expect(model.openDiff == DiffKey(run: run.id, lane: "b"))
        #expect(await client.calls.filter { $0.hasPrefix("diff") } == ["diff(a)", "diff(b)"])
    }

    @Test func stepListShowsEveryFlowNodeInPlanOrder() async throws {
        let (_, _, window) = try await fixture(pickRun())
        // Only "pick" and "judge" have entries; the rest have not started.
        for id in ["issue", "repo", "plan", "implement", "gate"] {
            #expect(try window.element(identifier: "detail.node.\(id).state").value == "Waiting", "\(id)")
        }
        #expect(try window.element(identifier: "detail.node.judge.state").value == "Done")
        let order = try window.elements { ($0.identifier ?? "").hasPrefix("detail.node.") && !($0.identifier ?? "").hasSuffix(".state") }
            .filter { ($0.identifier ?? "").split(separator: ".").count == 3 }
            .sorted { $0.frame.origin.y < $1.frame.origin.y }.compactMap(\.identifier)
        let expected = try BuiltinFlows.fixGitHubIssue.validate().order.map { "detail.node.\($0.rawValue)" }
        #expect(order == expected)
    }

    @Test func confirmationBelongsToOneRun() async throws {
        let a = pickRun()
        let b = makeRun("other", status: .needsYou, createdAt: Date(timeIntervalSince1970: 2_000))
        let (model, _, window) = try await fixture(a, others: [b])
        try await press("detail.discard", in: window)
        #expect(model.confirmingDiscard == a.id)
        #expect(window.presentedAlert != nil)
        model.open(run: b.id)
        try await window.runUntilIdle()
        #expect(window.presentedAlert == nil, "run A's confirmation does not show on run B")
        #expect(model.confirmingDiscard != b.id)
    }

    @Test func candidateShowsBranchChipAndRemovedCount() async throws {
        let (_, _, window) = try await fixture(pickRun())
        #expect(try window.element(identifier: "cand.b.removed").value == "−9")
        _ = try window.elements { $0.value == "mf/x-b" }.first.map { $0 } ?? { throw TestHarnessError.nothingPresented("branch chip") }()
    }

    @Test func resumeAndRetryInTheDetailCallTheModel() async throws {
        let run = makeRun("cut", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .interrupted),
            NodeKey(node: "gate", lane: "a"): NodeRun(state: .failed("nope"))])
        let (_, client, window) = try await fixture(run)
        try await press("detail.node.plan.resume", in: window)
        try await press("detail.node.gate@a.retry", in: window)
        let calls = await client.calls
        #expect(calls.contains("resume"))
        #expect(calls.contains("retry(gate@a)"))
    }

    @Test func loadingLineShowsWhileTheDiffLoads() async throws {
        let (_, client, window) = try await fixture(pickRun())
        await client.holdDiffs()
        try window.click(window.element(identifier: "cand.a.diff"))
        await client.waitForDiffStart()
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "diff.loading").value == "Loading diff…")
        await client.releaseDiffs()
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "diff.loading")) == nil)
    }

    @Test func reopeningWhileALoadRunsCallsTheClientOnce() async throws {
        let run = pickRun()
        let (model, client, _) = try await fixture(run)
        await client.holdDiffs()
        await client.setDiff("@@ -1 +1 @@\n+x\n")
        let first = Task { await model.toggleDiff(run.id, lane: "a") }
        await client.waitForDiffStart()
        await model.toggleDiff(run.id, lane: "a")   // close
        await model.toggleDiff(run.id, lane: "a")   // reopen
        await client.releaseDiffs()
        await first.value
        #expect(await client.calls.filter { $0.hasPrefix("diff") }.count == 1)
        #expect(model.openDiff == DiffKey(run: run.id, lane: "a"))
        #expect(model.diffChunks[DiffKey(run: run.id, lane: "a")] != nil)
    }

    @Test func aCachedDiffIsReloadedAfterTheRunChanges() async throws {
        let run = pickRun()
        let (model, client, _) = try await fixture(run)
        await model.toggleDiff(run.id, lane: "a")
        await model.toggleDiff(run.id, lane: "a")   // close
        await model.toggleDiff(run.id, lane: "a")   // reopen: cached, same revision
        #expect(await client.calls.filter { $0.hasPrefix("diff") }.count == 1)
        await model.toggleDiff(run.id, lane: "a")   // close
        var changed = run
        changed.revision += 1
        model.apply(changed)
        await model.toggleDiff(run.id, lane: "a")   // reopen after the run changed
        #expect(await client.calls.filter { $0.hasPrefix("diff") }.count == 2)
    }
}
