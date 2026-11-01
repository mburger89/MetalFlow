import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct OpenPRViewTests {
    let repo = URL(fileURLWithPath: "/repo")
    static let prURL = "https://github.com/acme/widgets/pull/12"

    func prFlow() -> Flow {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.nodes.append(Node(id: "openpr", title: "Open PR", kind: .openPR(OpenPRConfig()), position: Point(x: 1200, y: 330)))
        flow.wires.append(Wire(from: "pick", to: "openpr", input: "approval"))
        return flow
    }

    func lanes() -> [Lane] {
        [Lane(id: "a", model: "sonnet", branch: "mf/x-a", worktree: URL(fileURLWithPath: "/wt/a"), gatePassed: true, added: 12, removed: 3),
         Lane(id: "b", model: "opus", branch: "mf/x-b", worktree: URL(fileURLWithPath: "/wt/b"), gatePassed: false, added: 40, removed: 9)]
    }

    func pickRun(flow: Flow) -> Run {
        var run = makeRun("pick", status: .needsYou, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false))),
            NodeKey(node: "judge"): NodeRun(state: .succeeded, output: "B."),
        ])
        run.flow = flow
        run.lanes = lanes()
        run.recommendation = "b"
        return run
    }

    func openedRun(flow: Flow) -> Run {
        var run = pickRun(flow: flow)
        run.status = .prOpened("b", url: Self.prURL)
        run.pickedLane = "b"
        run.revision = 5
        run.nodes[NodeKey(node: "pick")] = NodeRun(state: .succeeded, output: "chose b")
        run.nodes[NodeKey(node: "openpr")] = NodeRun(state: .succeeded, output: Self.prURL)
        return run
    }

    func fixture(_ run: Run, others: [Run] = []) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: [run] + others, repos: [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.open(run: run.id)
        try await window.runUntilIdle()
        return (model, client, window)
    }

    func studio() async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: [], repos: [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model, size: metalFlowWindowSize)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.screen = .studio
        try await window.runUntilIdle()
        return (model, client, window)
    }

    func press(_ id: String, in window: TestWindow) async throws {
        try window.click(window.element(identifier: id))
        try await window.runUntilIdle()
    }

    // MARK: Pick button

    @Test func theButtonSaysOpenPRWhenTheFlowHasAnOpenPRNode() async throws {
        let (_, _, window) = try await fixture(pickRun(flow: prFlow()))
        for lane in ["a", "b"] {
            #expect(try window.element(identifier: "cand.\(lane).pick").label == "Pick & open PR")
        }
    }

    @Test func theButtonStaysPickAndMergeOtherwise() async throws {
        let (_, _, window) = try await fixture(pickRun(flow: BuiltinFlows.fixGitHubIssue))
        for lane in ["a", "b"] {
            #expect(try window.element(identifier: "cand.\(lane).pick").label == "Pick & merge")
        }
    }

    // MARK: Notices and outcome

    @Test func pickingNoticesThatThePullRequestIsOpeningAndThenThatItOpened() async throws {
        let run = pickRun(flow: prFlow())
        let (model, client, window) = try await fixture(run)
        await client.setPick(.handedToPullRequest)

        try await press("cand.b.pick", in: window)

        #expect(model.notice == Notice("Opening pull request\u{2026}", kind: .info))
        #expect(model.pickOutcomes[run.id]?["b"] == .openingPullRequest)
        #expect(model.selectedRun == run.id, "the detail stays up so the URL appears there")
        #expect(try window.element(identifier: "cand.b.result").value == "Opening pull request\u{2026}")

        var opened = openedRun(flow: prFlow())
        opened.id = run.id
        model.apply(opened)
        #expect(model.notice == Notice("Opened \(Self.prURL)", kind: .info))
    }

    // MARK: Status text

    @Test func aPullRequestRunReadsPROpenedAndCountsAsFinished() async throws {
        let run = openedRun(flow: prFlow())
        let (model, _, _) = try await fixture(run)
        #expect(WorkingChip.statusText(run) == "PR opened (B)")
        #expect(model.statusText(run) == "PR opened (B)")
        #expect(FinishedRow.result(run.status).0 == "PR opened (B)")
        #expect(model.finished.map(\.id) == [run.id])
        #expect(model.needsYou.isEmpty && model.running.isEmpty)
    }

    @Test func theFinishedListShowsIt() async throws {
        let run = openedRun(flow: prFlow())
        let client = FakeEngineClient(restored: [run], repos: [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        try await window.runUntilIdle()
        _ = try window.element(identifier: "finished.\(run.id.rawValue)")
    }

    @Test func theActivityFeedReportsTheOpenedPullRequest() async throws {
        let run = pickRun(flow: prFlow())
        let (model, _, _) = try await fixture(run)
        var opened = openedRun(flow: prFlow())
        opened.id = run.id
        model.apply(opened)
        #expect(model.activity.contains { $0.text.contains("opened a pull request for candidate b") && $0.text.contains(Self.prURL) })
    }

    // MARK: Run detail button

    @Test func theOpenPRButtonOpensTheURL() async throws {
        let run = openedRun(flow: prFlow())
        let (model, _, window) = try await fixture(run)
        var opened: [URL] = []
        model.openURL = { opened.append($0) }

        #expect(try window.element(identifier: "run.pr.open").label == "Open PR")
        #expect(try window.element(identifier: "run.pr.url").value == Self.prURL)
        try await press("run.pr.open", in: window)

        #expect(opened == [URL(string: Self.prURL)!])
    }

    @Test func noOpenPRButtonWithoutAPullRequest() async throws {
        let (_, _, window) = try await fixture(pickRun(flow: prFlow()))
        #expect((try? window.element(identifier: "run.pr.open")) == nil)
    }

    // MARK: Studio

    @Test func thePaletteAddsAnOpenPRNodeUnderDecide() async throws {
        let (model, _, window) = try await studio()
        let draft = try #require(model.draft)
        #expect(PaletteKind.groups.first { $0.title == "DECIDE" }?.items == [.judge, .pick, .openPR])
        #expect(try window.element(identifier: "palette.openpr").label == "Open PR")

        try await press("palette.openpr", in: window)

        let added = try #require(draft.flow.node("openpr1"))
        #expect(added.title == "Open PR")
        #expect(added.kind == .openPR(OpenPRConfig(draft: true)))
        #expect(added.kindLabel == "OPEN PR")
        #expect(added.summary == "Draft pull request")
        #expect(draft.selection == "openpr1")
    }

    @Test func theCanvasSummaryFollowsTheDraftSetting() {
        var node = Node(id: "o", title: "Open PR", kind: .openPR(OpenPRConfig(draft: false)), position: Point(x: 0, y: 0))
        #expect(node.summary == "Pull request")
        node.kind = .openPR(OpenPRConfig(draft: true))
        #expect(node.summary == "Draft pull request")
    }

    @Test func theInspectorTogglesDraftAndUndoes() async throws {
        let (model, _, window) = try await studio()
        let draft = try #require(model.draft)
        try await press("palette.openpr", in: window)
        #expect(draft.opensDraft("openpr1"))
        let before = draft.flow
        let undoSteps = draft.undoStack.count

        try await press("inspector.openpr.draft", in: window)

        #expect(draft.flow.node("openpr1")?.kind == .openPR(OpenPRConfig(draft: false)))
        #expect(draft.undoStack.count == undoSteps + 1)
        #expect(try window.element(identifier: "node.openpr1.title").value == "Open PR")

        window.typeKey("z", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow.node("openpr1")?.kind == .openPR(OpenPRConfig(draft: true)))
        #expect(draft.flow.nodes.count == before.nodes.count)

        try await press("inspector.openpr.draft", in: window)
        try await press("inspector.openpr.draft", in: window)
        #expect(draft.opensDraft("openpr1"), "two toggles are back to a draft")
    }

    @Test func theBannerShowsTheMissingPickMessageAndClearsOnceWired() async throws {
        let (model, _, window) = try await studio()
        let draft = try #require(model.draft)
        try await press("palette.openpr", in: window)
        #expect(try window.element(identifier: "studio.validation").value == "Open PR needs a You pick before it.")
        #expect(try window.element(identifier: "studio.save").isEnabled == false)

        draft.edit("wire") { $0.wires.append(Wire(from: "pick", to: "openpr1", input: "approval")) }
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "studio.validation")) == nil)
    }

    @Test func theBannerShowsTheSecondOpenPRMessage() async throws {
        let (model, _, window) = try await studio()
        let draft = try #require(model.draft)
        draft.edit("two") { flow in
            for id in ["a", "b"] {
                flow.nodes.append(Node(id: NodeID(rawValue: id), title: "Open PR", kind: .openPR(OpenPRConfig()), position: Point(x: 5, y: 5)))
                flow.wires.append(Wire(from: "pick", to: NodeID(rawValue: id), input: "approval"))
            }
        }
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "studio.validation").value == "A flow can have only one Open PR node.")
    }
}
