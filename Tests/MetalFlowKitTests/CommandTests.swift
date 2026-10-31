import Foundation
import MetalFlowCore
import MetalUI
import MetalUIPlatform
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct CommandTests {
    let repo = URL(fileURLWithPath: "/repo")

    func fixture(runs: [Run] = [], repos: [URL]? = nil) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: runs, repos: repos ?? [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        try await window.runUntilIdle()
        return (model, client, window)
    }

    func menuItem(_ window: TestWindow, _ menu: String, _ title: String) throws -> PlatformMenuItem {
        let m = try #require(window.testApp.menuBar.first { $0.title == menu })
        return try #require(m.items.first { $0.title == title })
    }

    // MARK: Shortcuts

    @Test func shortcutsMapToMenuItems() async throws {
        let (_, _, window) = try await fixture()
        let cmd = EventModifiers.command
        let table: [(String, String, String, EventModifiers)] = [
            ("File", "New Flow", "n", cmd), ("File", "Open Flow…", "o", cmd), ("File", "Save", "s", cmd),
            ("Run", "Launch…", "l", cmd), ("Run", "Go to Dashboard", "1", cmd), ("Run", "Go to Studio", "2", cmd),
            ("Edit", "Undo", "z", cmd), ("Edit", "Redo", "z", [cmd, .shift]),
        ]
        for (menu, title, key, mods) in table {
            let item = try menuItem(window, menu, title)
            #expect(item.shortcut == PlatformKeyEquivalent(key: key, modifiers: mods), "\(menu) > \(title)")
        }
    }

    @Test func shortcutsSwitchScreens() async throws {
        let (model, _, window) = try await fixture()
        window.typeKey("2", modifierFlags: [.command])
        try await window.runUntilIdle()
        #expect(model.screen == .studio)
        _ = try window.element(identifier: "studio")
        window.typeKey("1", modifierFlags: [.command])
        try await window.runUntilIdle()
        #expect(model.screen == .dashboard)
        try window.testApp.performMenuBarItem("Run", "Go to Studio")
        #expect(model.screen == .studio)
        try window.testApp.performMenuBarItem("Run", "Go to Dashboard")
        #expect(model.screen == .dashboard)
    }

    @Test func launchFocusesIssueField() async throws {
        let id = RunID()
        let (model, _, window) = try await fixture(runs: [makeRun("r", status: .running, id: id)])
        model.open(run: id)
        model.screen = .studio
        try await window.runUntilIdle()
        try window.testApp.performMenuBarItem("Run", "Launch…")
        try await window.runUntilIdle()
        #expect(model.screen == .dashboard)
        #expect(model.selectedRun == nil)
        let focused = try window.focusedElement?.identifier
        #expect(focused == "launch.issue")
    }

    // MARK: New Flow

    @Test func newFlowCreatesUntitledDraft() async throws {
        let (model, _, window) = try await fixture()
        await model.newFlow()
        try await window.runUntilIdle()
        let draft = try #require(model.draft)
        #expect(model.screen == .studio)
        #expect(draft.flow == Flow(name: "Untitled flow", nodes: [], wires: []))
        #expect(draft.url == nil)
        #expect(draft.repo == repo)
        #expect(!draft.isDirty)
    }

    @Test func newFlowWithoutRepoSetsNotice() async throws {
        let (model, _, _) = try await fixture(repos: [])
        await model.newFlow()
        #expect(model.notice?.text == "Add a repo on the dashboard first.")
        #expect(model.draft == nil)
    }

    @Test func newFlowWhileDirtyAsks() async throws {
        let (model, client, window) = try await fixture()
        model.screen = .studio
        let old = try #require(model.draft)
        old.edit("rename") { $0.name = "Edited" }
        await model.newFlow()
        try await window.runUntilIdle()
        #expect(model.draft === old)
        #expect(model.pendingAction == .newFlow)
        #expect(window.presentedAlert != nil)
        try window.respondToAlert(button: "Discard")
        try await window.runUntilIdle()
        #expect(model.pendingAction == nil)
        #expect(model.draft?.flow.name == "Untitled flow")
        _ = client
        // Cancel keeps the draft.
        let again = try #require(model.draft)
        again.edit("rename") { $0.name = "Edited 2" }
        await model.newFlow()
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Cancel")
        try await window.runUntilIdle()
        #expect(model.draft === again)
    }

    // MARK: Open Flow

    @Test func openFlowPanelListsFlowsAndOpens() async throws {
        let flow = URL(fileURLWithPath: "/repo/.flows/fix.flow")
        let client = FakeEngineClient(repos: [repo], flowFiles: [flow])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        try window.testApp.performMenuBarItem("File", "Open Flow…")
        try await window.runUntilIdle()
        #expect(model.isOpenFlowVisible)
        _ = try window.element(identifier: "openFlow.panel")
        try window.click(window.element(identifier: "openFlow.fix.flow"))
        try await window.runUntilIdle()
        #expect(!model.isOpenFlowVisible)
        #expect(model.screen == .studio)
        #expect(model.draft?.url == flow)
        // Cancel closes it.
        model.showOpenFlow()
        try await window.runUntilIdle()
        try window.click(window.element(identifier: "openFlow.cancel"))
        try await window.runUntilIdle()
        #expect(!model.isOpenFlowVisible)
        #expect((try? window.element(identifier: "openFlow.panel")) == nil)
    }

    // MARK: Save, Undo, Redo

    @Test func saveCommandSavesDraft() async throws {
        let (model, client, window) = try await fixture()
        let save = try menuItem(window, "File", "Save")
        #expect(!save.isEnabled, "no draft")
        model.screen = .studio
        try await window.runUntilIdle()
        let on486 = try menuItem(window, "File", "Save")
        #expect(on486.isEnabled)
        try window.testApp.performMenuBarItem("File", "Save")
        try await window.runUntilIdle()
        #expect(client.files.saved.count == 1)
    }

    @Test func undoRedoCommandsTargetDraft() async throws {
        let (model, _, window) = try await fixture()
        let item879 = try menuItem(window, "Edit", "Undo")
        #expect(!item879.isEnabled, "dashboard")
        model.screen = .studio
        let draft = try #require(model.draft)
        #expect(!model.canUndo && !model.canRedo)
        draft.edit("rename") { $0.name = "Renamed" }
        try await window.runUntilIdle()
        let on460 = try menuItem(window, "Edit", "Undo")
        #expect(on460.isEnabled)
        let item122 = try menuItem(window, "Edit", "Redo")
        #expect(!item122.isEnabled)
        try window.testApp.performMenuBarItem("Edit", "Undo")
        #expect(draft.flow.name == BuiltinFlows.fixGitHubIssue.name)
        let on871 = try menuItem(window, "Edit", "Redo")
        #expect(on871.isEnabled)
        try window.testApp.performMenuBarItem("Edit", "Redo")
        #expect(draft.flow.name == "Renamed")
        // On the dashboard they do nothing.
        model.screen = .dashboard
        model.undo()
        #expect(draft.flow.name == "Renamed")
    }

    // MARK: Quit

    @Test func quitDecisionByRunningCount() {
        #expect(quitDecision(runningCount: 0) == .now)
        #expect(quitDecision(runningCount: 1)
            == .ask("1 run is still running. Quitting stops it — you can resume later."))
        #expect(quitDecision(runningCount: 3)
            == .ask("3 runs are still running. Quitting stops them — you can resume later."))
    }

    @Test func quitWithNothingRunningQuitsNow() async throws {
        let (model, _, window) = try await fixture()
        #expect(window.testApp.app.onTerminateRequest != nil, "our handler is installed")
        #expect(model.requestTerminate() == .now)
        #expect(!model.quitPending)
        #expect(window.testApp.platform.simulateTerminateRequest() == .now)
    }

    @Test func quitWhileRunningAsks() async throws {
        let a = makeRun("a", status: .running), b = makeRun("b", status: .running)
        let (model, client, window) = try await fixture(runs: [a, b])
        let platform = window.testApp.platform
        #expect(platform.simulateTerminateRequest() == .later)
        try await window.runUntilIdle()
        let alert = try #require(window.presentedAlert)
        #expect(alert.message == "2 runs are still running. Quitting stops them — you can resume later.")
        #expect(alert.buttons.map(\.title) == ["Quit", "Cancel"])
        // Cancel replies false.
        try window.respondToAlert(button: "Cancel")
        try await window.runUntilIdle()
        #expect(platform.terminateReplies == [false])
        #expect(!model.quitPending)
        let none = await client.calls.filter { $0 == "cancel" }
        #expect(none.isEmpty)
        // Quit cancels every running run, then replies true.
        #expect(platform.simulateTerminateRequest() == .later)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Quit")
        try await window.runUntilIdle()
        await waitUntil("the quit reply") { platform.terminateReplies.count >= 2 }
        #expect(platform.terminateReplies == [false, true])
        let suspends = await client.calls.filter { $0 == "suspend" }
        #expect(suspends.count == 2)
        let cancels = await client.calls.filter { $0 == "cancel" }
        #expect(cancels.isEmpty, "quit suspends runs so they can be resumed; it never cancels them")
    }

    @Test func quitWithOneRunUsesSingular() async throws {
        let (_, _, window) = try await fixture(runs: [makeRun("a", status: .running)])
        #expect(window.testApp.platform.simulateTerminateRequest() == .later)
        try await window.runUntilIdle()
        let alert = try #require(window.presentedAlert)
        #expect(alert.message == "1 run is still running. Quitting stops it — you can resume later.")
    }

    @Test func saveIsOffTheDashboard() async throws {
        let (model, client, window) = try await fixture()
        model.screen = .studio
        try await window.runUntilIdle()
        model.screen = .dashboard
        try await window.runUntilIdle()
        #expect(model.draft != nil)
        let save = try menuItem(window, "File", "Save")
        #expect(!save.isEnabled)
        window.typeKey("s", modifierFlags: [.command])
        try await window.runUntilIdle()
        #expect(client.files.saved.isEmpty)
    }

    @Test func saveDisabledForInvalidDraft() async throws {
        let (model, client, window) = try await fixture()
        model.screen = .studio
        let draft = try #require(model.draft)
        draft.edit("break") { $0.wires.append(Wire(from: "nope", to: "plan", input: "x")) }
        try await window.runUntilIdle()
        #expect(!model.draftIsValid)
        let save = try menuItem(window, "File", "Save")
        #expect(!save.isEnabled)
        window.typeKey("s", modifierFlags: [.command])
        try await window.runUntilIdle()
        #expect(client.files.saved.isEmpty)
    }

    @Test func openFlowPanelIdIsThePanelNotATitle() async throws {
        let (model, _, window) = try await fixture()
        model.showOpenFlow()
        try await window.runUntilIdle()
        let panel = try window.element(identifier: "openFlow.panel").frame
        let cancel = try window.element(identifier: "openFlow.cancel").frame
        #expect(panel.size.width >= 400)
        #expect(cancel.origin.y + cancel.size.height <= panel.origin.y + panel.size.height)
        #expect(cancel.origin.y >= panel.origin.y)
    }

    @Test func escapeClosesOpenFlowPanel() async throws {
        let (model, _, window) = try await fixture()
        model.showOpenFlow()
        try await window.runUntilIdle()
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(!model.isOpenFlowVisible)
    }

    @Test func openFlowWhileDirtyAsksFirst() async throws {
        let flow = URL(fileURLWithPath: "/repo/.flows/fix.flow")
        let client = FakeEngineClient(repos: [repo], flowFiles: [flow])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.screen = .studio
        let draft = try #require(model.draft)
        draft.edit("rename") { $0.name = "Edited" }
        model.showOpenFlow()
        try await window.runUntilIdle()
        try window.click(window.element(identifier: "openFlow.fix.flow"))
        try await window.runUntilIdle()
        #expect(model.pendingAction == .open(flow))
        #expect(model.draft === draft)
        #expect(window.presentedAlert != nil)
    }

    // MARK: Quit and close with unsaved work

    private func dirtyFixture(runs: [Run] = []) async throws -> (AppModel, FakeEngineClient, TestWindow, FlowDraft) {
        let (model, client, window) = try await fixture(runs: runs)
        model.screen = .studio
        let draft = try #require(model.draft)
        draft.edit("rename") { $0.name = "Edited" }
        try await window.runUntilIdle()
        return (model, client, window, draft)
    }

    @Test func quitWithDirtyDraftAsks() async throws {
        let (model, _, window, draft) = try await dirtyFixture()
        let platform = window.testApp.platform
        #expect(platform.simulateTerminateRequest() == .later)
        try await window.runUntilIdle()
        #expect(model.pendingAction == .quit)
        let alert = try #require(window.presentedAlert)
        #expect(alert.buttons.map(\.title) == ["Save", "Discard", "Cancel"])
        try window.respondToAlert(button: "Cancel")
        try await window.runUntilIdle()
        #expect(platform.terminateReplies == [false])
        #expect(model.pendingAction == nil)
        #expect(draft.isDirty, "cancel keeps the edits")
    }

    @Test func quitWithDirtyDraftSaveThenQuits() async throws {
        let (model, client, window, _) = try await dirtyFixture()
        let platform = window.testApp.platform
        #expect(platform.simulateTerminateRequest() == .later)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Save")
        try await window.runUntilIdle()
        await waitUntil("the quit reply") { platform.terminateReplies.count == 1 }
        #expect(client.files.saved.count == 1)
        #expect(platform.terminateReplies == [true])
        #expect(!model.quitPending)
    }

    @Test func quitWithDirtyDraftDiscardQuitsWithoutSaving() async throws {
        let (_, client, window, _) = try await dirtyFixture()
        let platform = window.testApp.platform
        #expect(platform.simulateTerminateRequest() == .later)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Discard")
        await waitUntil("the quit reply") { platform.terminateReplies.count == 1 }
        #expect(client.files.saved.isEmpty)
        #expect(platform.terminateReplies == [true])
    }

    @Test func quitSaveFailureCancelsTheQuit() async throws {
        let (model, client, window, draft) = try await dirtyFixture()
        client.files.failSave = true
        let platform = window.testApp.platform
        #expect(platform.simulateTerminateRequest() == .later)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Save")
        try await window.runUntilIdle()
        await waitUntil("the quit reply") { platform.terminateReplies.count == 1 }
        #expect(platform.terminateReplies == [false])
        #expect(model.notice != nil)
        #expect(draft.isDirty)
    }

    @Test func dirtyDraftAndRunningRunsAsksBothInOrder() async throws {
        let (model, client, window, _) = try await dirtyFixture(runs: [makeRun("a", status: .running)])
        let platform = window.testApp.platform
        #expect(platform.simulateTerminateRequest() == .later)
        try await window.runUntilIdle()
        #expect(window.presentedAlert?.buttons.map(\.title) == ["Save", "Discard", "Cancel"], "the draft comes first")
        try window.respondToAlert(button: "Discard")
        try await window.runUntilIdle()
        await waitUntil("the running-runs alert") { model.quitPending }
        try await window.runUntilIdle()
        #expect(platform.terminateReplies.isEmpty, "not answered yet")
        #expect(window.presentedAlert?.buttons.map(\.title) == ["Quit", "Cancel"])
        try window.respondToAlert(button: "Quit")
        try await window.runUntilIdle()
        await waitUntil("the quit reply") { platform.terminateReplies.count == 1 }
        #expect(platform.terminateReplies == [true])
        #expect(await client.calls.filter { $0 == "suspend" }.count == 1)
    }

    @Test func closingTheWindowWithRunningRunAsksAndSuspends() async throws {
        let (model, client, window) = try await fixture(runs: [makeRun("a", status: .running)])
        #expect(window.requestClose() == false, "held while the alert is up")
        try await window.runUntilIdle()
        #expect(model.quitPending)
        #expect(window.presentedAlert?.buttons.map(\.title) == ["Quit", "Cancel"])
        try window.respondToAlert(button: "Quit")
        try await window.runUntilIdle()
        await waitUntil("the window to close") { window.platformWindow.isClosed }
        #expect(await client.calls.filter { $0 == "suspend" }.count == 1)
        #expect(window.testApp.platform.terminateReplies.isEmpty, "answered the close, not a terminate")
    }

    @Test func cancellingAClosedRequestKeepsTheWindow() async throws {
        let (_, client, window) = try await fixture(runs: [makeRun("a", status: .running)])
        #expect(window.requestClose() == false)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Cancel")
        try await window.runUntilIdle()
        #expect(!window.platformWindow.isClosed)
        #expect(!window.window.isCloseRequestPending)
        #expect(await client.calls.filter { $0 == "suspend" }.isEmpty)
    }

    @Test func closingACleanIdleWindowClosesAtOnce() async throws {
        let (_, _, window) = try await fixture()
        #expect(window.requestClose() == true)
    }

    @Test func closingWithDirtyDraftAsks() async throws {
        let (model, _, window, _) = try await dirtyFixture()
        #expect(window.requestClose() == false)
        try await window.runUntilIdle()
        #expect(model.pendingAction == .quit)
        try window.respondToAlert(button: "Discard")
        await waitUntil("the window to close") { window.platformWindow.isClosed }
    }

    // MARK: A close and a quit pending together

    @Test func closeThenQuitThenCancelAnswersBoth() async throws {
        let (model, _, window) = try await fixture(runs: [makeRun("a", status: .running)])
        let platform = window.testApp.platform
        #expect(window.requestClose() == false)
        try await window.runUntilIdle()
        _ = platform.simulateTerminateRequest()
        try window.respondToAlert(button: "Cancel")
        try await window.runUntilIdle()
        #expect(!window.window.isCloseRequestPending, "the close is answered")
        #expect(platform.terminateReplies == [false], "the quit is answered too")
        #expect(!window.platformWindow.isClosed)
        #expect(!model.quitPending)
    }

    @Test func closeThenQuitThenQuitAnswersBoth() async throws {
        let (_, client, window) = try await fixture(runs: [makeRun("a", status: .running)])
        let platform = window.testApp.platform
        #expect(window.requestClose() == false)
        try await window.runUntilIdle()
        _ = platform.simulateTerminateRequest()
        try window.respondToAlert(button: "Quit")
        await waitUntil("the quit reply") { platform.terminateReplies.count == 1 && window.platformWindow.isClosed }
        #expect(platform.terminateReplies == [true])
        #expect(!window.window.isCloseRequestPending)
        #expect(await client.calls.filter { $0 == "suspend" }.count == 1)
    }

    @Test func plainQuitGetsExactlyOneReply() async throws {
        let (_, _, window) = try await fixture(runs: [makeRun("a", status: .running)])
        let platform = window.testApp.platform
        #expect(platform.simulateTerminateRequest() == .later)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Cancel")
        try await window.runUntilIdle()
        #expect(platform.terminateReplies == [false])
    }
}
