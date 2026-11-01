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
            #expect(try window.element(identifier: "node.\(node.id.rawValue).title").value == node.title)
        }
        #expect(model.draft?.location == .builtin)
        #expect(model.draft?.url == nil)
        #expect(model.draft?.flow.name == "Fix GitHub issue")
        #expect(try window.element(identifier: "studio.name").value == "Fix GitHub issue")
    }

    @Test func toolbarNameIsAnEditableUndoableField() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        let draft = try #require(model.draft)
        let field = try window.element(identifier: "studio.name")
        window.click(at: ScreenPoint(x: field.frame.origin.x + field.frame.size.width - 4,
                                     y: field.frame.origin.y + field.frame.size.height / 2))
        window.typeText("!")
        try await window.runUntilIdle()
        #expect(draft.flow.name == "Fix GitHub issue!")
        #expect(try window.element(identifier: "studio.name").value == "Fix GitHub issue!")
        window.typeText("?")
        try await window.runUntilIdle()
        #expect(draft.flow.name == "Fix GitHub issue!?")
        #expect(try window.element(identifier: "studio.name").value == "Fix GitHub issue!?")
        #expect(draft.isDirty)
        draft.undo()
        #expect(draft.flow.name == "Fix GitHub issue", "one typing session is one undo step")
    }

    func entry(_ name: String) -> FlowEntry {
        let file = URL(fileURLWithPath: "/lib/\(name).flow")
        return FlowEntry(id: file.path, name: name, location: .library(file: file), file: file)
    }

    @Test func untitledFlowsGetUniqueNamesAcrossTheCatalog() async throws {
        let (model, client, _) = try await fixture()
        client.catalog.entries += [entry("Untitled flow"), entry("Untitled flow 2")]
        await model.refreshCatalog()
        await model.newFlow()
        #expect(model.draft?.flow.name == "Untitled flow 3")
        client.catalog.entries = [entry("Other")]
        await model.refreshCatalog()
        await model.newFlow()
        #expect(model.draft?.flow.name == "Untitled flow")
        client.catalog.entries = [entry("Untitled flow")]
        await model.refreshCatalog()
        await model.newFlow()
        #expect(model.draft?.flow.name == "Untitled flow 2")
    }

    @Test func studioOpensWithoutRepo() async throws {
        let (model, _, window) = try await fixture(repos: [])
        try await showStudio(model, window)
        _ = try window.element(identifier: "studio")
        #expect((try? window.element(identifier: "studio.empty")) == nil)
        let draft = try #require(model.draft)
        #expect(draft.location == .builtin)
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
        _ = try window.element(identifier: "node.plan")
        #expect(try window.element(identifier: "studio.file").value == "Unsaved")
    }

    @Test func clickSelectsNode() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        #expect(model.draft?.selection == nil)
        _ = try window.element(identifier: "inspector.empty")
        try await press("node.plan", in: window)
        #expect(model.draft?.selection == "plan")
        #expect(try window.element(identifier: "inspector.title").value == "Plan")
        #expect(try window.element(identifier: "inspector.id").value == "plan")
        #expect(model.draft?.flow.node("plan")?.title == "Plan")
        try await press("node.judge", in: window)
        #expect(model.draft?.selection == "judge")
        #expect(try window.element(identifier: "inspector.id").value == "judge")
        #expect(try window.element(identifier: "inspector.title").value == "Recommend")
        #expect(model.draft?.flow.node("judge")?.title == "Recommend")
    }

    @Test func studioLaysOutPaletteCanvasAndInspectorAsSplitPanes() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        let palette = try window.element(identifier: "palette.prompt").frame
        let canvas = try window.element(identifier: "canvas").frame
        let inspector = try window.element(identifier: "inspector.empty").frame
        // Left to right, each pane inside its limits.
        #expect(palette.maxX <= canvas.minX)
        #expect(canvas.maxX <= inspector.minX)
        #expect(canvas.size.width >= 400)
        #expect(palette.size.width <= 280)
        #expect(inspector.size.width <= 420)
        // The canvas still receives clicks through the split view.
        #expect(model.draft?.selection == nil)
        try await press("node.plan", in: window)
        #expect(model.draft?.selection == "plan")
    }

    @Test func nodeCardBorderIsRounded() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        let draft = try #require(model.draft)
        draft.geometry.zoom = 2
        try await window.runUntilIdle()
        for selected in [false, true] {
            draft.selection = selected ? "plan" : nil
            try await window.runUntilIdle()
            let card = try window.element(identifier: "node.plan").frame
            let x = card.origin.x.value, y = card.origin.y.value, width = card.size.width.value
            let border = try #require(window.scene.rects.first { (rect: MUIRect) in
                rect.borderWidths.left > 0
                    && abs(rect.bounds.origin.x - x) < 1 && abs(rect.bounds.origin.y - y) < 1
                    && abs(rect.bounds.size.width - width) < 1
            })
            #expect(border.cornerRadii.topLeft == 20, "10 canvas units at 200%")
            #expect(border.borderWidths.left == (selected ? 2 : 1))
        }
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

    @Test func panDoesNotRebuildNodeCards() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        let draft = try #require(model.draft)
        let nodes = draft.flow.nodes.count
        #expect(nodes > 1)
        let before = NodeCardView.bodyCount
        for step in 1...5 {
            draft.geometry.pan = ScreenPoint(x: draft.geometry.pan.x + 7, y: draft.geometry.pan.y + 3)
            try await window.runUntilIdle()
            #expect(NodeCardView.bodyCount - before == 0, "pan step \(step) rebuilt cards: \(NodeCardView.bodyCount - before)")
        }
        // A zoom does rebuild them (the text is laid out at the new size, so it stays sharp), once each.
        let beforeZoom = NodeCardView.bodyCount
        draft.geometry.zoom(to: draft.geometry.zoom * 1.25, about: ScreenPoint(x: Pixels(100), y: Pixels(100)))
        try await window.runUntilIdle()
        #expect(NodeCardView.bodyCount - beforeZoom == nodes)
        // Selecting a node rebuilds only that card.
        let beforeSelect = NodeCardView.bodyCount
        draft.selection = draft.flow.nodes[0].id
        try await window.runUntilIdle()
        #expect(NodeCardView.bodyCount - beforeSelect == 1)
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
        try await window.runUntil { model.diffChunks[DiffKey(run: run.id, lane: "a")] != nil }
        _ = try window.element(identifier: "diff.hunk.0")
        try await press("cand.a.diff", in: window)
        #expect((try? window.element(identifier: "diff.hunk.0")) == nil, "Hide diff closes it")
    }

    @Test func studioRunPickerListsOnlyMatchingRuns() async throws {
        let newest = laneRun()
        var older = makeRun("older", status: .completed, createdAt: Date(timeIntervalSince1970: 500))
        older.status = .completed
        var otherFlow = makeRun("other flow", createdAt: Date(timeIntervalSince1970: 3_000))
        otherFlow.flow.name = "Something else"
        let (model, _, window) = try await fixture(runs: [older, newest, otherFlow])
        try await showStudio(model, window)
        _ = try window.element(identifier: "studio.runPicker")
        #expect(model.studioRuns.map(\.title) == ["#7 lanes", "older"])
        // The rendered menu lists the definition and only the runs of this flow (by name), newest first.
        try window.click(window.element(identifier: "studio.runPicker"))
        let menu = try #require(window.presentedMenu)
        #expect(menu.items.map(\.title) == ["Definition only", "Showing #7 lanes", "Showing older"])
        try window.chooseMenuItem("Showing #7 lanes")
        try await window.runUntilIdle()
        #expect(model.studioRun == newest.id)
    }

    @Test func studioRunsSeparateSameNamedFlowFiles() async throws {
        let fileA = URL(fileURLWithPath: "/lib/a/fix.flow"), fileB = URL(fileURLWithPath: "/lib/b/fix.flow")
        var runA = makeRun("from a", createdAt: Date(timeIntervalSince1970: 1)); runA.flowFile = fileA
        var runB = makeRun("from b", createdAt: Date(timeIntervalSince1970: 2)); runB.flowFile = fileB
        let legacy = makeRun("legacy", createdAt: Date(timeIntervalSince1970: 3))
        let (model, _, _) = try await fixture(runs: [runA, runB, legacy])
        model.draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, location: .library(file: fileA))
        #expect(model.studioRuns.map(\.title) == ["legacy", "from a"], "own file plus legacy runs of the same name")
        model.draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, location: .library(file: fileB))
        #expect(model.studioRuns.map(\.title) == ["legacy", "from b"])
        model.draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, location: .builtin)
        #expect(model.studioRuns.map(\.title) == ["legacy"], "no file: only runs without one")
    }

    @Test func pickerAndOverlayLeaveOutDiscardedRuns() async throws {
        let live = laneRun()
        var gone = makeRun("gone", status: .discarded, createdAt: Date(timeIntervalSince1970: 900))
        gone.status = .discarded
        let (model, _, window) = try await fixture(runs: [live, gone])
        try await showStudio(model, window)
        #expect(model.studioRuns.map(\.title) == ["#7 lanes"])
        // A run discarded while it is overlaid drops the overlay.
        model.studioRun = live.id
        #expect(model.studioShownRun != nil)
        var discarded = live
        discarded.status = .discarded
        discarded.revision = 5
        model.apply(discarded)
        #expect(model.studioShownRun == nil)
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "cand.a")) == nil)
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

    @Test func studioRunClearsWhenDraftChanges() async throws {
        let run = laneRun()
        let (model, _, window) = try await fixture(runs: [run])
        try await showStudio(model, window)
        model.studioRun = run.id
        model.draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, location: .builtin)
        #expect(model.studioRun == nil, "replacing the draft")
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
        #expect(model.draft?.location == .of(file: url))
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
        try await press("save.dest.\(dir.lastPathComponent)", in: window)
        // The new file name is chosen off the main actor.
        try await window.runUntil { !client.files.saved.isEmpty }
        #expect(client.files.saved.map(\.url) == [expected])
        #expect(client.files.saved.first?.flow == FlowCatalog.prepareForSave(
            BuiltinFlows.fixGitHubIssue, destination: .of(file: expected), origin: nil).0)
        #expect(model.draft?.url == expected)
        #expect(model.draft?.isDirty == false)
        // Saving again writes the same file.
        try await press("studio.save", in: window)
        try await window.runUntil { client.files.saved.count == 2 }
        #expect(client.files.saved.map(\.url) == [expected, expected])
    }

    @Test func savingDropsOrphanBindings() async throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, client, window) = try await fixture(repos: [dir])
        try await showStudio(model, window)
        let draft = try #require(model.draft)
        draft.edit("test.orphan") { flow in
            if let i = flow.nodes.firstIndex(where: { $0.id == "plan" }) { flow.nodes[i].inputs["gone"] = .fixed("x") }
        }
        try await press("studio.save", in: window)
        try await press("save.dest.\(dir.lastPathComponent)", in: window)
        try await window.runUntil { !client.files.saved.isEmpty }
        #expect(client.files.saved.first?.flow.node("plan")?.inputs["gone"] == nil, "first save")
        draft.edit("test.orphan2") { flow in
            if let i = flow.nodes.firstIndex(where: { $0.id == "plan" }) { flow.nodes[i].inputs["gone"] = .fixed("y") }
        }
        try await press("studio.save", in: window)
        try await window.runUntil { client.files.saved.count == 2 }
        #expect(client.files.saved.last?.flow.node("plan")?.inputs["gone"] == nil, "later save")
        #expect(draft.flow.node("plan")?.inputs["gone"] == nil)
        #expect(draft.isDirty == false)
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
        let saving = Task { await model.saveDraft() }
        try await window.runUntil { model.isSavePanelVisible }
        model.chooseSaveDestination(.repo(dir))
        #expect(await saving.value)
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
        model.studioValues["issue"] = "42"
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "studio.save").isEnabled == false)
        #expect(try window.element(identifier: "studio.launch").isEnabled == false)
        _ = try window.element(identifier: "studio.validation")
        #expect(await model.saveDraft() == false)
        #expect(await model.launchFromStudio() == nil)
        #expect(client.files.saved.isEmpty)
        #expect(await !client.calls.contains { $0.hasPrefix("launch") })
    }

    @Test func studioLaunchUsesFields() async throws {
        let (model, client, window) = try await fixture()
        try await showStudio(model, window)
        // One control per launch field of the draft at its location: the issue, then the repo.
        _ = try window.element(identifier: "studio.field.issue")
        _ = try window.element(identifier: "studio.field.repo")
        #expect(try window.element(identifier: "studio.launch").isEnabled == false, "needs an issue")
        model.studioValues["issue"] = "  #42 \n"
        try await window.runUntilIdle()
        try await press("studio.launch", in: window)
        #expect(await client.calls.contains("launch(Fix GitHub issue, /repo, #42)"))
        let launched = await client.launches
        #expect(launched.map(\.location) == [.builtin], "an unsaved draft launches at .builtin")
        #expect(launched.first?.values == ["issue": "#42", "repo": "/repo"])
        #expect(model.studioValues["issue"] == nil, "the typed text is cleared")
        #expect(model.isLaunching == false)
    }

    func setRepoMode(_ draft: FlowDraft, _ mode: RepoMode) {
        draft.edit("repo mode") { flow in
            for i in flow.nodes.indices where flow.nodes[i].id == "repo" { flow.nodes[i].kind = .repo(RepoConfig(mode: mode)) }
        }
    }

    @Test func studioShowsResolvedRepoForFixed() async throws {
        let (model, _, window) = try await fixture()
        try await showStudio(model, window)
        let draft = try #require(model.draft)
        #expect((try? window.element(identifier: "studio.repo.resolved")) == nil, "Exposed shows the repo field instead")
        setRepoMode(draft, .fixed(path: "/somewhere/proj"))
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "studio.repo.resolved").value == "proj")
    }

    @Test func studioShowsResolvedRepoForThisRepo() async throws {
        let (model, _, window) = try await fixture()
        model.open(flow: URL(fileURLWithPath: "/work/alpha/.flows/x.flow"))
        try await window.runUntilIdle()
        let draft = try #require(model.draft)
        setRepoMode(draft, .thisRepo)
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "studio.repo.resolved").value == "alpha")
    }

    @Test func studioLaunchRowFollowsTheFlowsFields() async throws {
        let (model, client, window) = try await fixture()
        try await showStudio(model, window)
        let draft = try #require(model.draft)
        draft.edit("fix the repo") { flow in
            for i in flow.nodes.indices where flow.nodes[i].id == "repo" {
                flow.nodes[i].kind = .repo(RepoConfig(mode: .fixed(path: "/somewhere")))
            }
        }
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "studio.field.repo")) == nil, "a fixed repo asks for nothing")
        model.studioValues["issue"] = "7"
        try await window.runUntilIdle()
        try await press("studio.launch", in: window)
        #expect(await client.launches.first?.values == ["issue": "7"])
        // This repo is invalid for a draft that is not in a repo, and the row says why.
        draft.edit("this repo") { flow in
            for i in flow.nodes.indices where flow.nodes[i].id == "repo" {
                flow.nodes[i].kind = .repo(RepoConfig(mode: .thisRepo))
            }
        }
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "studio.launch").isEnabled == false)
        #expect(try window.element(identifier: "studio.validation").value
            == draft.flow.message(for: .thisRepoOutsideRepo))
    }

    @Test func draftUndoRedoAndValidation() {
        let draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, location: .unsaved)
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
