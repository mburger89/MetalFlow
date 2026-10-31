import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct DashboardTests {
    let repo = URL(fileURLWithPath: "/repo")
    let flowFile = URL(fileURLWithPath: "/repo/.metalflow/Fix GitHub issue.flow")

    func fixture(_ runs: [Run] = [], gitRepos: Set<String> = []) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: runs, repos: [repo], flowFiles: [flowFile], gitRepoPaths: gitRepos)
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        try await window.runUntilIdle()
        return (model, client, window)
    }

    func press(_ id: String, in window: TestWindow) async throws {
        try window.click(window.element(identifier: id))
        try await window.runUntilIdle()
    }

    @Test func launchBarLaunchesWithSelections() async throws {
        let (model, client, window) = try await fixture()
        #expect(model.launchForm.repo == repo)
        #expect(model.launchForm.flow == flowFile)
        _ = try window.element(identifier: "launch.flow")
        _ = try window.element(identifier: "launch.repo")
        #expect(!model.canLaunch, "Launch waits for an issue")
        #expect(try !window.element(identifier: "launch.go").isEnabled, "the rendered button is disabled")

        try window.click(window.element(identifier: "launch.issue"))
        window.typeText("42")
        try await window.runUntilIdle()
        #expect(model.launchForm.issue == "42")
        #expect(try window.element(identifier: "launch.issue").value == "42")
        #expect(try window.element(identifier: "launch.go").isEnabled)
        try await press("launch.go", in: window)

        #expect(await client.calls.contains("launch(Fix GitHub issue, /repo, 42)"))
        #expect(model.launchForm.issue == "", "launching clears the issue field")
    }

    @Test func addRepoValidatesThePath() async throws {
        let (model, _, _) = try await fixture(gitRepos: ["/other"])
        #expect(await model.addRepo(path: "/nope") == false)
        #expect(model.notice != nil)
        #expect(await model.addRepo(path: "/other"))
        #expect(model.repos.map(\.path) == ["/repo", "/other"])
        #expect(model.launchForm.repo?.path == "/other")
    }

    @Test func needsYouCardsAppearPerKind() async throws {
        let pick = makeRun("pick", status: .needsYou, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))])
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let cut = makeRun("cut", status: .needsYou, nodes: [NodeKey(node: "plan"): NodeRun(state: .interrupted)])
        let bad = makeRun("bad", status: .needsYou, nodes: [NodeKey(node: "gate", lane: "a"): NodeRun(state: .failed("nope"))])
        let (_, _, window) = try await fixture([pick, ask, cut, bad])

        _ = try window.element(identifier: "needs.\(pick.id.rawValue).pick")
        _ = try window.element(identifier: "needs.\(pick.id.rawValue).pick.primary")
        #expect(try window.element(identifier: "needs.\(pick.id.rawValue).pick.primary").label == "Compare & pick")
        _ = try window.element(identifier: "needs.\(ask.id.rawValue).plan")
        _ = try window.element(identifier: "answer.\(ask.id.rawValue).plan.field")
        #expect(try window.element(identifier: "needs.\(cut.id.rawValue).plan.primary").label == "Resume")
        #expect(try window.element(identifier: "needs.\(bad.id.rawValue).gate@a.primary").label == "Retry")
        for run in [pick, ask, cut, bad] {
            let key = run.nodes.keys.first!
            _ = try window.element(identifier: "needs.\(run.id.rawValue).\(key).open")
        }
    }

    @Test func compareAndPickAndOpenRunSelectTheRun() async throws {
        let pick = makeRun("pick", status: .needsYou, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))])
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let (model, _, window) = try await fixture([pick, ask])
        try await press("needs.\(pick.id.rawValue).pick.primary", in: window)
        #expect(model.selectedRun == pick.id)
        model.selectedRun = nil
        try await window.runUntilIdle()
        try await press("needs.\(ask.id.rawValue).plan.open", in: window)
        #expect(model.selectedRun == ask.id)
    }

    @Test func aFailedRunWithAFailedNodeShowsARetryCard() async throws {
        let failed = makeRun("failed", status: .failed("boom"), nodes: [
            NodeKey(node: "plan"): NodeRun(state: .failed("boom"))])
        let (model, client, window) = try await fixture([failed])
        #expect(model.finished.isEmpty)
        #expect(model.needsYou.map(\.id) == [failed.id])
        #expect(try window.element(identifier: "needs.\(failed.id.rawValue).plan.primary").label == "Retry")
        try await press("needs.\(failed.id.rawValue).plan.primary", in: window)
        #expect(await client.calls.contains("retry(plan)"))
    }

    @Test func doubleSubmitLaunchesOnce() async throws {
        let (model, client, _) = try await fixture()
        model.launchForm.issue = "42"
        async let a = model.launchFromForm()
        async let b = model.launchFromForm()
        _ = await (a, b)
        let launches = await client.calls.filter { $0.hasPrefix("launch(") }
        #expect(launches.count == 1)
    }

    @Test func textTypedDuringALaunchSurvives() async throws {
        let (model, client, _) = try await fixture()
        await client.holdLaunches()
        model.launchForm.issue = "42"
        let task = Task { await model.launchFromForm() }
        await waitUntil("the launch to be in flight") { model.isLaunching }
        #expect(model.isLaunching)
        #expect(!model.canLaunch)
        model.launchForm.issue = "43"
        await client.releaseLaunches()
        _ = await task.value
        #expect(model.launchForm.issue == "43")
        #expect(!model.isLaunching)

        model.launchForm.issue = "44"
        _ = await model.launchFromForm()
        #expect(model.launchForm.issue == "", "an unchanged field is cleared")
    }

    @Test func repoPathTextTypedDuringValidationSurvives() async throws {
        let (model, _, _) = try await fixture(gitRepos: ["/other"])
        model.launchForm.newRepoPath = "/other"
        #expect(await model.addRepo(path: model.launchForm.newRepoPath))
        #expect(model.launchForm.newRepoPath == "")
        model.launchForm.newRepoPath = "/x"
        #expect(await model.addRepo(path: "/other"))
        #expect(model.launchForm.newRepoPath == "/x", "text that is not the validated path stays")
    }

    @Test func retryAndResumeCallTheClient() async throws {
        let cut = makeRun("cut", status: .needsYou, nodes: [NodeKey(node: "plan"): NodeRun(state: .interrupted)])
        let bad = makeRun("bad", status: .needsYou, nodes: [NodeKey(node: "gate", lane: "a"): NodeRun(state: .failed("nope"))])
        let (_, client, window) = try await fixture([cut, bad])
        try await press("needs.\(cut.id.rawValue).plan.primary", in: window)
        try await press("needs.\(bad.id.rawValue).gate@a.primary", in: window)
        let calls = await client.calls
        #expect(calls.contains("resume"))
        #expect(calls.contains("retry(gate@a)"))
    }

    @Test func answerFromDashboardCallsClient() async throws {
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let (_, client, window) = try await fixture([ask])
        try window.click(window.element(identifier: "answer.\(ask.id.rawValue).plan.field"))
        window.typeText("Use A.swift")
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "answer.\(ask.id.rawValue).plan.field").value == "Use A.swift")
        try await press("answer.\(ask.id.rawValue).plan.send", in: window)
        #expect(await client.calls.contains("answer(plan, Use A.swift, [])"))
    }

    @Test func runLockedByAnotherProcessIsLabelledAndHasNoCancel() async throws {
        let mine = makeRun("mine", status: .running), theirs = makeRun("theirs", status: .running)
        let client = FakeEngineClient(restored: [mine, theirs], repos: [repo], flowFiles: [flowFile])
        await client.setElsewhere([theirs.id])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        try await window.runUntilIdle()
        #expect(model.runningElsewhere == [theirs.id])
        #expect(model.drivenRunning.map(\.id) == [mine.id])
        _ = try window.element(identifier: "run.\(mine.id.rawValue).cancel")
        #expect((try? window.element(identifier: "run.\(theirs.id.rawValue).cancel")) == nil)
        #expect(try window.element(identifier: "run.\(theirs.id.rawValue).elsewhere").value == "Running in another mflow")
        // Only the run this app drives is stopped by quitting.
        #expect(model.requestTerminate() == .later)
        #expect(model.quitMessage == "1 run is still running. Quitting stops it — you can resume later.")
        // An update from this app's own engine means it drives the run now.
        var taken = theirs
        taken.revision = 1
        model.apply(taken)
        #expect(model.runningElsewhere.isEmpty)
    }

    @Test func quitWithOnlyOtherProcessRunsQuitsNow() async throws {
        let theirs = makeRun("theirs", status: .running)
        let client = FakeEngineClient(restored: [theirs], repos: [repo])
        await client.setElsewhere([theirs.id])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        #expect(model.requestTerminate() == .now)
    }

    @Test func failedAnswerKeepsTheReply() async throws {
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let (model, client, window) = try await fixture([ask])
        await client.setFailure(FakeFailure())
        try window.click(window.element(identifier: "answer.\(ask.id.rawValue).plan.field"))
        window.typeText("Use A.swift")
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "answer.\(ask.id.rawValue).plan.field").value == "Use A.swift")
        try await press("answer.\(ask.id.rawValue).plan.send", in: window)
        #expect(await client.calls.contains("answer(plan, Use A.swift, [])"))
        #expect(model.answerDrafts[AppModel.draftKey(ask.id, NodeKey(node: "plan"))] == "Use A.swift", "kept for another try")
        #expect(model.notice?.text == "engine said no")
        // A successful answer clears it.
        await client.setFailure(nil)
        try await press("answer.\(ask.id.rawValue).plan.send", in: window)
        #expect(model.answerDrafts[AppModel.draftKey(ask.id, NodeKey(node: "plan"))] == nil)
    }

    @Test func newlineOnlyReplyCannotBeSent() async throws {
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let (model, _, window) = try await fixture([ask])
        model.answerDrafts[AppModel.draftKey(ask.id, NodeKey(node: "plan"))] = " \n "
        try await window.runUntilIdle()
        #expect(try !window.element(identifier: "answer.\(ask.id.rawValue).plan.send").isEnabled)
    }

    @Test func allowOnTheDashboardSendsTheSameReplyAsTheDetail() async throws {
        let run = makeRun("denied", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.deniedTools(["Edit"])))])
        let (_, client, window) = try await fixture([run])
        try await press("needs.\(run.id.rawValue).plan.primary", in: window)
        #expect(await client.calls.contains("answer(plan, Continue., [\"Edit\"])"))
    }

    @Test func runningCardShowsStepPillsAndLastLog() async throws {
        let started = Date().addingTimeInterval(-150)
        let run = makeRun("#63 Word diff", status: .running, createdAt: started, nodes: [
            NodeKey(node: "issue"): NodeRun(state: .succeeded),
            NodeKey(node: "repo"): NodeRun(state: .succeeded),
            NodeKey(node: "plan"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "a"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "b"): NodeRun(state: .running, log: ["▸ Edit DiffView.swift"], startedAt: started),
        ])
        let (_, _, window) = try await fixture([run])
        let id = run.id.rawValue
        #expect(try window.element(identifier: "run.\(id).title").value == "#63 Word diff")
        #expect(try window.element(identifier: "run.\(id).log").value == "▸ Edit DiffView.swift")
        let pillIDs = try window.elements { ($0.identifier ?? "").hasPrefix("pill.") }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }.compactMap(\.identifier)
        let names = pillIDs.map { String($0.split(separator: ".")[1]) }
        #expect(names == (try run.flow.validate().order.map(\.rawValue)))
        #expect(names.firstIndex(of: "plan")! < names.firstIndex(of: "implement")!)
        #expect(names.firstIndex(of: "implement")! < names.firstIndex(of: "gate")!)
        _ = try window.element(identifier: "pill.plan.done")
        _ = try window.element(identifier: "pill.implement.run")
        _ = try window.element(identifier: "pill.gate.wait")
        _ = try window.element(identifier: "pill.pick.wait")

        #expect(try window.element(identifier: "run.\(id).elapsed").value == "2m")
        // The timeline's wake sleeps in real time, so the test moves the clock and dirties the window itself.
        // The first build at a nonzero timestamp anchors the timeline clock to real time: do that first.
        window.advance(by: 1)
        window.window.setNeedsRedraw()
        window.tick()
        window.advance(by: 60)
        window.window.setNeedsRedraw()
        window.tick()
        #expect(try window.element(identifier: "run.\(id).elapsed").value == "3m")
    }

    @Test func cancelFromRunCard() async throws {
        let run = makeRun("go", status: .running)
        let (_, client, window) = try await fixture([run])
        try await press("run.\(run.id.rawValue).cancel", in: window)
        #expect(await client.calls.contains("cancel"))
    }

    @Test func finishedListsMergedRuns() async throws {
        let old = makeRun("#39 old", status: .merged("a"), createdAt: Date(timeIntervalSince1970: 1_000))
        let new = makeRun("#40 new", status: .discarded, createdAt: Date(timeIntervalSince1970: 2_000))
        let (model, _, window) = try await fixture([old, new])
        #expect(model.finished.map(\.title) == ["#40 new", "#39 old"])
        let rows = try window.elements { ($0.identifier ?? "").hasPrefix("finished.") && ($0.identifier ?? "").hasSuffix(".title") }
            .sorted { $0.frame.origin.y < $1.frame.origin.y }.compactMap(\.value)
        #expect(rows == ["#40 new", "#39 old"], "rendered newest first")
        #expect(try window.element(identifier: "finished.\(old.id.rawValue).result").value == "Merged A")
        #expect(try window.element(identifier: "finished.\(new.id.rawValue).result").value == "Discarded")
    }

    @Test func finishedListCapsAtTwenty() async throws {
        let runs = (0..<25).map { makeRun("r\($0)", status: .completed, createdAt: Date(timeIntervalSince1970: Double(1_000 + $0))) }
        let (_, _, window) = try await fixture(runs)
        let rows = try window.elements { ($0.identifier ?? "").hasPrefix("finished.") && ($0.identifier ?? "").hasSuffix(".title") }
            .sorted { $0.frame.origin.y < $1.frame.origin.y }.compactMap(\.value)
        #expect(rows == (5..<25).reversed().map { "r\($0)" }, "the 20 newest, newest first")
    }

    @Test func workingChipOpensAndDismisses() async throws {
        let run = makeRun("#7 x", status: .running)
        let (model, _, window) = try await fixture([run])
        model.open(run: run.id)
        try await window.runUntilIdle()
        model.selectedRun = nil
        try await window.runUntilIdle()
        try await press("working.run.\(run.id.rawValue).open", in: window)
        #expect(model.selectedRun == run.id)
        model.selectedRun = nil
        try await window.runUntilIdle()
        try await press("working.run.\(run.id.rawValue).dismiss", in: window)
        #expect(model.workingOn.isEmpty)
    }

    @Test func activityFeedShowsItems() async throws {
        let run = makeRun("#9 feed", status: .running)
        let (model, _, window) = try await fixture()
        model.apply(run)
        try await window.runUntilIdle()
        #expect(try window.elements { $0.identifier == "activity.item" }.count == 1)
    }

    @Test func idsSitOnTheRealContainers() async throws {
        let run = makeRun("#1 card", status: .running)
        let (_, _, window) = try await fixture([run])
        let screen = try window.element(identifier: "dashboard").frame
        #expect(screen.size.width > 1000 && screen.size.height > 500, "the screen, not a zero-size marker")
        let card = try window.element(identifier: "run.\(run.id.rawValue)").frame
        let cancel = try window.element(identifier: "run.\(run.id.rawValue).cancel").frame
        #expect(card.size.width > 200 && card.size.height > 80)
        #expect(cancel.origin.x >= card.origin.x && cancel.origin.y >= card.origin.y)
        #expect(cancel.origin.x + cancel.size.width <= card.origin.x + card.size.width)
        #expect(cancel.origin.y + cancel.size.height <= card.origin.y + card.size.height, "the card's frame holds its buttons")
    }

    @Test func activityFeedBuildsOnlyTheVisibleRows() async throws {
        let (model, _, window) = try await fixture()
        for i in 0..<150 { model.apply(makeRun("run \(i)", status: .running, createdAt: Date(timeIntervalSince1970: Double(i)))) }
        try await window.runUntilIdle()
        #expect(model.activity.count == 150)
        let rows = try window.elements { $0.identifier == "activity.item" }.count
        #expect(rows > 0 && rows < 60, "\(rows) rows built for 150 items")
    }

    @Test func workingChipIDsAreUniqueAcrossRepos() async throws {
        let (model, _, window) = try await fixture()
        model.open(flow: URL(fileURLWithPath: "/a/x.flow"))
        model.open(flow: URL(fileURLWithPath: "/b/x.flow"))
        model.screen = .dashboard
        try await window.runUntilIdle()
        let chips = try window.elements { ($0.identifier ?? "").hasPrefix("working.flow.") && !($0.identifier ?? "").hasSuffix("title") && !($0.identifier ?? "").hasSuffix("open") && !($0.identifier ?? "").hasSuffix("dismiss") }
        #expect(Set(chips.compactMap(\.identifier)).count == 2)
        let titles = try window.elements { ($0.identifier ?? "").hasPrefix("working.flow.") && ($0.identifier ?? "").hasSuffix(".title") }
        #expect(Set(titles.compactMap(\.identifier)).count == 2)
    }

    @Test func agesFollowTheModelClock() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let run = makeRun("old", status: .completed, createdAt: now.addingTimeInterval(-7_200))
        let client = FakeEngineClient(restored: [run], repos: [repo], flowFiles: [flowFile])
        let model = AppModel(client: client, notifier: NoopNotifier(), clock: { now })
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "finished.\(run.id.rawValue).age").value == "2h")
    }

    @Test func changingRepoClearsTheFlowUntilTheScanReturns() async throws {
        let (model, client, _) = try await fixture(gitRepos: ["/other"])
        model.launchForm.issue = "42"
        try #require(model.canLaunch)
        client.scanGate.hold()
        let task = Task { await model.selectRepo(URL(fileURLWithPath: "/other")) }
        await client.scanGate.waitForEntry()
        #expect(model.launchForm.flow == nil)
        #expect(model.repoFlows.isEmpty)
        #expect(!model.canLaunch)
        client.scanGate.release()
        await task.value
        #expect(model.canLaunch)
    }

    @Test func isLaunchingResetsAfterALaunchThrows() async throws {
        let (model, client, _) = try await fixture()
        await client.setFailure(FakeFailure())
        model.launchForm.issue = "42"
        #expect(await model.launchFromForm() == nil)
        #expect(!model.isLaunching)
        #expect(model.launchForm.issue == "42", "a failed launch keeps the text")
        #expect(model.notice != nil)
    }
}
