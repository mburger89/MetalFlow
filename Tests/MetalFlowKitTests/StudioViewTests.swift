import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct StudioViewTests {
    let repo = URL(fileURLWithPath: "/repo")

    func fixture(runs: [Run] = [], repos: [URL]? = nil) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: runs, repos: repos ?? [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        return (model, client, window)
    }

    func showStudio(_ model: AppModel, _ window: TestWindow) async throws {
        model.screen = .studio
        try await window.runUntilIdle()
    }

    func press(_ id: String, in window: TestWindow) async throws {
        try window.click(window.element(identifier: id))
        try await window.runUntilIdle()
    }

    func tempRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mf-studio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func laneRun(gateC: NodeState = .failed("tests")) -> Run {
        var run = makeRun("#7 lanes", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "a"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "b"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "c"): NodeRun(state: .succeeded),
            NodeKey(node: "gate", lane: "a"): NodeRun(state: .succeeded),
            NodeKey(node: "gate", lane: "b"): NodeRun(state: .running),
            NodeKey(node: "gate", lane: "c"): NodeRun(state: gateC),
        ])
        run.lanes = [
            Lane(id: "a", model: "sonnet", branch: "mf/x-a", worktree: URL(fileURLWithPath: "/wt/a"), gatePassed: true),
            Lane(id: "b", model: "opus", branch: "mf/x-b", worktree: URL(fileURLWithPath: "/wt/b"), gatePassed: nil),
            Lane(id: "c", model: "haiku", branch: "mf/x-c", worktree: URL(fileURLWithPath: "/wt/c"), gatePassed: false),
        ]
        return run
    }

    @Test func studioShowsBuiltinFlowNodes() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        _ = try window.element(identifier: "studio")
        for node in BuiltinFlows.fixGitHubIssue.nodes {
            #expect(try window.element(identifier: "node.\(node.id.rawValue)").value == node.title)
        }
        #expect(model.draft?.repo == repo)
        #expect(model.draft?.url == nil)
        #expect(try window.element(identifier: "studio.name").value == "Fix GitHub issue")
    }

    @Test func emptyStudioWithoutRepo() async throws {
        let (model, _, window) = try await fixture(repos: [])
        try await showStudio(model, window)
        _ = try window.element(identifier: "studio")
        #expect(try window.element(identifier: "studio.empty").value == "Add a repo on the dashboard to open a flow.")
        #expect(model.draft == nil)
    }

    @Test func clickSelectsNode() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        #expect(model.draft?.selection == nil)
        _ = try window.element(identifier: "inspector.empty")
        try await press("node.plan", in: window)
        #expect(model.draft?.selection == "plan")
        // The title is an editable field (its identifier is on the field's container, which has no value).
        _ = try window.element(identifier: "inspector.title")
        #expect(try window.element(identifier: "inspector.id").value == "plan")
        #expect(model.draft?.flow.node("plan")?.title == "Plan")
        try await press("node.judge", in: window)
        #expect(model.draft?.selection == "judge")
        #expect(try window.element(identifier: "inspector.id").value == "judge")
        #expect(model.draft?.flow.node("judge")?.title == "Recommend")
    }

    @Test func canvasFitsOnFirstShowAndFitButtonRestores() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        let draft = try #require(model.draft)
        let size = try #require(draft.canvasSize)
        #expect(draft.geometry == CanvasGeometry().fit(draft.flow, in: size))
        #expect(draft.geometry != CanvasGeometry())
        let fitted = draft.geometry
        draft.geometry.pan = ScreenPoint(x: Pixels(5), y: Pixels(5))
        draft.geometry.zoom = 2
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "canvas.zoom").value == "200%")
        try await press("canvas.fit", in: window)
        #expect(draft.geometry == fitted)
        #expect(try window.element(identifier: "canvas.zoom").value == "\(Int((fitted.zoom * 100).rounded()))%")
    }

    @Test func wheelPansTheCanvas() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        let draft = try #require(model.draft)
        let node = try window.element(identifier: "node.plan").frame
        let at = Point(x: node.origin.x + node.size.width / 2, y: node.origin.y + node.size.height / 2)
        let before = draft.geometry
        window.scroll(at: at, byDeltaX: 0, deltaY: 30)
        try await window.runUntilIdle()
        #expect(draft.geometry.zoom == before.zoom)
        #expect(draft.geometry.pan != before.pan)
    }

    @Test func runOverlayShowsLaneStates() async throws {
        let run = laneRun()
        let (model, _, window) = try await fixture(runs: [run])
        try await showStudio(model, window)
        #expect((try? window.element(identifier: "node.gate.status")) == nil, "definition only shows no states")
        model.studioRun = run.id
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "node.gate.status").value == "A ✓ B ● C ✕")
        #expect(try window.element(identifier: "node.implement.status").value == "A ✓ B ✓ C ✓")
        #expect(try window.element(identifier: "node.plan.status").value == "Done")
        #expect(try window.element(identifier: "node.pick.status").value == "Waiting")
        // The candidates strip reuses the run detail's cards.
        for lane in ["a", "b", "c"] { _ = try window.element(identifier: "cand.\(lane)") }
    }

    @Test func viewDiffInTheCandidatesStripShowsTheDiff() async throws {
        let run = laneRun()
        let (model, client, window) = try await fixture(runs: [run])
        await client.setDiff("@@ -1 +1 @@\n+added\n")
        try await showStudio(model, window)
        model.studioRun = run.id
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "diff.hunk.0")) == nil)
        try await press("cand.a.diff", in: window)
        await waitUntil("the diff to load") { model.diffChunks[DiffKey(run: run.id, lane: "a")] != nil }
        try await window.runUntilIdle()
        _ = try window.element(identifier: "diff.hunk.0")
        try await press("cand.a.diff", in: window)
        #expect((try? window.element(identifier: "diff.hunk.0")) == nil, "Hide diff closes it")
    }

    @Test func studioRunPickerListsOnlyMatchingRuns() async throws {
        let newest = laneRun()
        var older = makeRun("older", status: .completed, createdAt: Date(timeIntervalSince1970: 500))
        older.status = .completed
        var otherRepo = makeRun("other repo", createdAt: Date(timeIntervalSince1970: 2_000))
        otherRepo.repo = URL(fileURLWithPath: "/elsewhere")
        var otherFlow = makeRun("other flow", createdAt: Date(timeIntervalSince1970: 3_000))
        otherFlow.flow.name = "Something else"
        let (model, _, window) = try await fixture(runs: [older, newest, otherRepo, otherFlow])
        try await showStudio(model, window)
        _ = try window.element(identifier: "studio.runPicker")
        #expect(model.studioRuns.map(\.title) == ["#7 lanes", "older"])
        // The rendered menu lists the definition and only the runs of this flow and repo, newest first.
        try window.click(window.element(identifier: "studio.runPicker"))
        let menu = try #require(window.presentedMenu)
        #expect(menu.items.map(\.title) == ["Definition only", "Showing #7 lanes", "Showing older"])
        try window.chooseMenuItem("Showing #7 lanes")
        try await window.runUntilIdle()
        #expect(model.studioRun == newest.id)
    }

    @Test func overlayLaneScopingComesFromTheRunNotTheDraft() async throws {
        let run = laneRun(gateC: .failed("x"))
        let (model, _, window) = try await fixture(runs: [run])
        try await showStudio(model, window)
        model.draft?.edit("unwire") { $0.wires.removeAll() }
        #expect(model.draftIsValid == false)
        model.studioRun = run.id
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "node.gate.status").value == "A ✓ B ● C ✕")
    }

    @Test func studioRunClearsWhenDraftOrRepoChanges() async throws {
        let other = URL(fileURLWithPath: "/other")
        let run = laneRun()
        let (model, _, window) = try await fixture(runs: [run], repos: [repo, other])
        try await showStudio(model, window)
        model.studioRun = run.id
        await model.selectRepo(other)
        #expect(model.studioRun == nil, "retargeting the draft to another repo")
        model.studioRun = run.id
        model.draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, url: nil, repo: other)
        #expect(model.studioRun == nil, "replacing the draft")
        model.studioRun = run.id
        model.draft?.repo = repo
        #expect(model.studioRun == nil, "changing the draft's repo")
    }

    @Test func fitButtonKeepsTheSelection() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        try await press("node.plan", in: window)
        #expect(model.draft?.selection == "plan")
        try await press("canvas.fit", in: window)
        #expect(model.draft?.selection == "plan")
    }

    @Test func openFlowLoadsDraftAndSwitchesToStudio() async throws {
        let (model, _, window) = try await fixture()
        let url = repo.appendingPathComponent(".flows/fix.flow")
        model.open(flow: url)
        try await window.runUntilIdle()
        #expect(model.screen == .studio)
        #expect(model.draft?.url == url)
        #expect(model.draft?.repo == repo)
        _ = try window.element(identifier: "studio")
        #expect(try window.element(identifier: "studio.file").value == "fix.flow")
        // The same flow again keeps the draft and its history.
        let draft = try #require(model.draft)
        draft.edit("rename") { $0.name = "Renamed" }
        model.screen = .dashboard
        model.open(flow: url)
        #expect(model.draft === draft)
        #expect(draft.undoStack.count == 1)
        #expect(model.screen == .studio)
    }

    @Test func openFlowLoadErrorKeepsScreenAndNotifies() async throws {
        let (model, client, window) = try await fixture()
        client.files.failLoad = true
        model.open(flow: repo.appendingPathComponent(".flows/bad.flow"))
        try await window.runUntilIdle()
        #expect(model.screen == .dashboard)
        #expect(model.draft == nil)
        #expect(model.notice?.text == "engine said no")
    }

    @Test func flowChipOpenLoadsDraft() async throws {
        let (model, _, window) = try await fixture()
        let url = repo.appendingPathComponent(".flows/fix.flow")
        model.open(flow: url)
        model.screen = .dashboard
        model.draft = nil
        try await window.runUntilIdle()
        try await press("working.flow.\(url.path).open", in: window)
        #expect(model.screen == .studio)
        #expect(model.draft?.url == url)
        _ = try window.element(identifier: "node.plan")
    }

    @Test func saveUntitledWritesIntoRepoFlowsDir() async throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, client, window) = try await fixture(repos: [dir])
        try await showStudio(model, window)
        let expected = dir.appendingPathComponent(".flows/fix-github-issue.flow")
        try await press("studio.save", in: window)
        #expect(client.files.saved.map(\.url) == [expected])
        #expect(client.files.saved.first?.flow == BuiltinFlows.fixGitHubIssue)
        #expect(model.draft?.url == expected)
        #expect(model.draft?.isDirty == false)
        // Saving again writes the same file.
        try await press("studio.save", in: window)
        #expect(client.files.saved.map(\.url) == [expected, expected])
    }

    @Test func saveNeverOverwritesAnExistingFile() async throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let flows = dir.appendingPathComponent(".flows")
        try FileManager.default.createDirectory(at: flows, withIntermediateDirectories: true)
        for name in ["fix-github-issue.flow", "fix-github-issue-2.flow"] {
            try Data("{}".utf8).write(to: flows.appendingPathComponent(name))
        }
        let (model, client, window) = try await fixture(repos: [dir])
        try await showStudio(model, window)
        try await press("studio.save", in: window)
        #expect(client.files.saved.map(\.url) == [flows.appendingPathComponent("fix-github-issue-3.flow")])
    }

    @Test func slugs() {
        #expect(AppModel.slug("Fix GitHub issue") == "fix-github-issue")
        #expect(AppModel.slug("  Ünï — a/b!! ") == "n-a-b")
        #expect(AppModel.slug("???") == "flow")
    }

    @Test func saveDisabledWhenInvalid() async throws {
        let (model, client, window) = try await fixture()
        try await showStudio(model, window)
        #expect(try window.element(identifier: "studio.save").isEnabled)
        #expect((try? window.element(identifier: "studio.validation")) == nil)
        let draft = try #require(model.draft)
        draft.edit("unwire") { $0.wires.removeAll() }
        model.studioIssue = "42"
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "studio.save").isEnabled == false)
        #expect(try window.element(identifier: "studio.launch").isEnabled == false)
        _ = try window.element(identifier: "studio.validation")
        #expect(await model.saveDraft() == false)
        #expect(await model.launchFromStudio() == nil)
        #expect(client.files.saved.isEmpty)
        #expect(await !client.calls.contains { $0.hasPrefix("launch") })
    }

    @Test func launchFromStudioUsesDraftFlowAndRepo() async throws {
        let (model, client, window) = try await fixture()
        try await showStudio(model, window)
        #expect(try window.element(identifier: "studio.launch").isEnabled == false, "needs an issue")
        model.studioIssue = "  #42 \n"
        try await window.runUntilIdle()
        try await press("studio.launch", in: window)
        #expect(await client.calls.contains("launch(Fix GitHub issue, /repo, #42)"))
        #expect(model.studioIssue == "")
        #expect(model.isLaunching == false)
    }

    @Test func draftUndoRedoAndValidation() {
        let draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, url: nil, repo: URL(fileURLWithPath: "/r"))
        #expect(draft.plan != nil && !draft.isDirty)
        draft.edit("unwire") { $0.wires.removeAll() }
        #expect(draft.plan == nil && draft.isDirty && draft.undoStack.count == 1)
        draft.undo()
        #expect(draft.plan != nil && draft.redoStack.count == 1)
        draft.redo()
        #expect(draft.plan == nil)
        for i in 0..<120 { draft.edit("n\(i)") { $0.name = "n\(i)" } }
        #expect(draft.undoStack.count == FlowDraft.historyLimit)
    }
}
