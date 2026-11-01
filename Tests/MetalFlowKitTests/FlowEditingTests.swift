import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

struct KindMismatch: Error {}

@MainActor
@Suite struct FlowEditingTests {
    let repo = URL(fileURLWithPath: "/repo")

    func fixture(runs: [Run] = [], repos: [URL]? = nil, gitRepos: Set<String> = []) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: runs, repos: repos ?? [repo], gitRepoPaths: gitRepos)
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

    /// The window position of a canvas point.
    func screen(_ window: TestWindow, _ draft: FlowDraft, _ p: CanvasPoint) throws -> ScreenPoint {
        let origin = try window.element(identifier: "canvas").frame.origin
        let s = draft.geometry.toScreen(p)
        return ScreenPoint(x: origin.x + s.x, y: origin.y + s.y)
    }

    func center(_ window: TestWindow, _ id: String) throws -> ScreenPoint {
        let f = try window.element(identifier: id).frame
        return ScreenPoint(x: f.origin.x + f.size.width / 2, y: f.origin.y + f.size.height / 2)
    }

    func tempRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mf-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func node(_ draft: FlowDraft, _ id: NodeID) throws -> Node { try #require(draft.flow.node(id)) }

    // MARK: Palette

    @Test func addNodeFromPalette() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        let size = try #require(draft.canvasSize)
        try await press("palette.prompt", in: window)
        let added = try node(draft, "prompt1")
        #expect(added.title == "Prompt")
        #expect(draft.selection == "prompt1")
        #expect(draft.isDirty)
        #expect(draft.undoStack.count == 1)
        guard case .prompt(let config) = added.kind else { Issue.record("not a prompt"); return }
        #expect(config == PromptConfig(model: "sonnet", prompt: "", candidates: [], allowedTools: [], maxTurns: nil))
        // Centred on the canvas centre.
        let rect = draft.geometry.nodeRect(added)
        let centre = draft.geometry.toCanvas(ScreenPoint(x: size.width / 2, y: size.height / 2))
        #expect(abs(rect.x + rect.w / 2 - centre.x) < 1 && abs(rect.y + rect.h / 2 - centre.y) < 1)
        _ = try window.element(identifier: "node.prompt1")
        // Smallest unused number.
        try await press("palette.prompt", in: window)
        #expect(draft.selection == "prompt2")
        draft.undo()
        draft.undo()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
    }

    @Test func everyPaletteItemAddsItsKind() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        let expected: [(String, String, String)] = [
            ("input", "input1", "Flow input"), ("repo", "repo1", "Repo"), ("prompt", "prompt1", "Prompt"),
            ("shell", "shell1", "Shell"), ("gate", "gate1", "Gate"), ("judge", "judge1", "Judge"),
            ("pick", "pick1", "You pick"),
        ]
        for (prefix, id, title) in expected {
            try await press("palette.\(prefix)", in: window)
            let added = try node(draft, NodeID(rawValue: id))
            #expect(added.title == title)
            #expect(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        }
        if case .flowInput(let c) = try node(draft, "input1").kind { #expect(c == FlowInputConfig(name: "issue", source: .githubIssue)) }
        if case .gate(let c) = try node(draft, "gate1").kind { #expect(c.command == "") }
    }

    // MARK: Dragging

    @Test func dragNodeMovesAndUndoes() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        let before = try node(draft, "plan").position
        let from = try center(window, "node.plan")
        let to = ScreenPoint(x: from.x + 60, y: from.y + 40)
        window.drag(from: from, to: to)
        try await window.runUntilIdle()
        let after = try node(draft, "plan").position
        let z = draft.geometry.zoom
        #expect(abs(after.x - before.x - 60 / z) < 1.5)
        #expect(abs(after.y - before.y - 40 / z) < 1.5)
        #expect(draft.selection == "plan")
        #expect(draft.undoStack.count == 1, "one drag is one undo step")
        #expect(draft.isDirty)
        draft.undo()
        #expect(try node(draft, "plan").position == before)
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
        draft.redo()
        #expect(try node(draft, "plan").position == after)
    }

    @Test func dragOnEmptyCanvasPans() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        let origin = try window.element(identifier: "canvas").frame.origin
        let from = ScreenPoint(x: origin.x + 12, y: origin.y + 6)
        let panBefore = draft.geometry.pan
        window.drag(from: from, to: ScreenPoint(x: from.x + 30, y: from.y + 20))
        try await window.runUntilIdle()
        #expect(draft.geometry.pan != panBefore)
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
        #expect(draft.undoStack.isEmpty)
    }

    // MARK: Wires

    @Test func connectPortsAddsWire() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        let issue = try node(draft, "issue"), gate = try node(draft, "gate")
        let from = try screen(window, draft, draft.geometry.outPort(issue))
        let to = try screen(window, draft, draft.geometry.inPort(gate))
        window.drag(from: from, to: to)
        try await window.runUntilIdle()
        let wire = Wire(from: "issue", to: "gate", input: "issue")
        #expect(draft.flow.wires.last == wire)
        #expect(draft.flow.wires.count == BuiltinFlows.fixGitHubIssue.wires.count + 1)
        #expect(draft.undoStack.count == 1)
        draft.undo()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
        // Released over nothing: no wire.
        let empty = try screen(window, draft, CanvasPoint(x: 400, y: 600))
        window.drag(from: from, to: empty)
        try await window.runUntilIdle()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
        #expect(draft.undoStack.isEmpty && draft.redoStack.count == 1, "the empty-space drag added no step")
    }

    @Test func selfWireRefused() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        draft.connect(from: "plan", to: "plan")
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue && draft.undoStack.isEmpty)
        let plan = try node(draft, "plan")
        window.drag(from: try screen(window, draft, draft.geometry.outPort(plan)),
                    to: try screen(window, draft, draft.geometry.inPort(plan)))
        try await window.runUntilIdle()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue && draft.undoStack.isEmpty)
    }

    @Test func duplicateInputNameGetsSuffix() async throws {
        let (model, _, _) = try await fixture()
        let draft = try #require(model.draft)
        draft.connect(from: "issue", to: "plan")
        #expect(draft.flow.wires.last == Wire(from: "issue", to: "plan", input: "issue_2"))
        draft.connect(from: "issue", to: "plan")
        #expect(draft.flow.wires.last == Wire(from: "issue", to: "plan", input: "issue_3"))
        let count = draft.flow.wires.count
        draft.connect(from: "issue", to: "plan", input: "issue_3")
        #expect(draft.flow.wires.count == count, "an exact duplicate is refused")
    }

    @Test func wireClickSelectsAndDeleteRemoves() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        let a = draft.geometry.outPort(try node(draft, "plan")), b = draft.geometry.inPort(try node(draft, "implement"))
        let mid = CanvasPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        try window.click(at: screen(window, draft, mid))
        try await window.runUntilIdle()
        let wire = Wire(from: "plan", to: "implement", input: "plan")
        #expect(draft.selectedWire == wire)
        #expect(draft.selection == nil)
        window.typeKey(.delete)
        try await window.runUntilIdle()
        #expect(!draft.flow.wires.contains(wire))
        #expect(draft.flow.nodes == BuiltinFlows.fixGitHubIssue.nodes)
        #expect(draft.selectedWire == nil)
        draft.undo()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
    }

    // MARK: Delete and keyboard

    @Test func deleteRemovesNodeAndWires() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.implement", in: window)
        #expect(draft.selection == "implement")
        window.typeKey(.delete)
        try await window.runUntilIdle()
        #expect(draft.flow.node("implement") == nil)
        #expect(!draft.flow.wires.contains { $0.from == "implement" || $0.to == "implement" })
        #expect(draft.flow.nodes.count == BuiltinFlows.fixGitHubIssue.nodes.count - 1)
        #expect(draft.selection == nil)
        #expect(draft.undoStack.count == 1)
        window.typeKey("z", modifierFlags: .command)
        try await window.runUntilIdle()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue, "Command-Z undoes")
        window.typeKey("z", modifierFlags: [.command, .shift])
        try await window.runUntilIdle()
        #expect(draft.flow.node("implement") == nil, "Shift-Command-Z redoes")
    }

    @Test func backspaceInInspectorDoesNotDeleteNode() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        let field = try window.element(identifier: "inspector.title")
        window.click(at: ScreenPoint(x: field.frame.origin.x + field.frame.size.width - 4,
                                         y: field.frame.origin.y + field.frame.size.height / 2))
        window.typeText("x")
        try await window.runUntilIdle()
        #expect(try node(draft, "plan").title == "Planx")
        #expect(try window.element(identifier: "inspector.title").value == "Planx")
        window.typeKey(.delete)
        try await window.runUntilIdle()
        #expect(try node(draft, "plan").title == "Plan")
        #expect(try window.element(identifier: "inspector.title").value == "Plan")
        #expect(draft.flow.nodes.count == BuiltinFlows.fixGitHubIssue.nodes.count)
        #expect(draft.selection == "plan")
        guard case .prompt(let before) = try node(draft, "plan").kind else { return }
        try window.click(window.element(identifier: "inspector.prompt"))
        window.typeKey(.delete)
        try await window.runUntilIdle()
        guard case .prompt(let after) = try node(draft, "plan").kind else { return }
        #expect(after.prompt.count == before.prompt.count - 1, "the TextEditor had focus and lost one character")
        #expect(draft.flow.node("plan") != nil)
    }

    // MARK: Inspector

    @Test func inspectorEditsPrompt() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        guard case .prompt(let before) = try node(draft, "plan").kind else { return }
        try window.click(window.element(identifier: "inspector.prompt"))
        window.typeText("QQ")
        try await window.runUntilIdle()
        guard case .prompt(let after) = try node(draft, "plan").kind else { return }
        #expect(after.prompt.count == before.prompt.count + 2)
        #expect(after.prompt.contains("QQ"))
        #expect(try window.element(identifier: "inspector.prompt").value == after.prompt)
        #expect(draft.undoStack.count == 1, "one typing session is one undo step")
        draft.undo()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue)
    }

    @Test func typingInOneFieldIsOneUndoStep() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        let field = try window.element(identifier: "inspector.title")
        window.click(at: ScreenPoint(x: field.frame.origin.x + field.frame.size.width - 4,
                                         y: field.frame.origin.y + field.frame.size.height / 2))
        window.typeText("abc")
        try await window.runUntilIdle()
        #expect(try node(draft, "plan").title == "Planabc")
        #expect(try window.element(identifier: "inspector.title").value == "Planabc")
        #expect(draft.undoStack.count == 1)
        // Another field starts a new step.
        draft.edit("other") { $0.name = "Other" }
        #expect(draft.undoStack.count == 2)
        draft.undo()
        draft.undo()
        #expect(try node(draft, "plan").title == "Plan")
    }

    @Test func undoToSavedStateIsClean() async throws {
        let draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, location: .unsaved)
        #expect(draft.isDirty == false)
        draft.edit("rename") { $0.name = "Renamed" }
        #expect(draft.isDirty)
        draft.undo()
        #expect(draft.isDirty == false, "undone back to the saved state")
        draft.redo()
        #expect(draft.isDirty)
        draft.didSave(draft.flow, at: .of(file: URL(fileURLWithPath: "/repo/.flows/x.flow")))
        #expect(draft.isDirty == false)
        draft.undo()
        #expect(draft.isDirty, "undoing past the save is an edit")
    }

    @Test func modelPickerOffersThreeModels() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        try window.click(window.element(identifier: "inspector.model"))
        let menu = try #require(window.presentedMenu)
        #expect(menu.items.map(\.title) == ["opus", "sonnet", "haiku"])
        #expect(menu.items.first?.isOn == true)
        try window.chooseMenuItem("sonnet")
        try await window.runUntilIdle()
        guard case .prompt(let config) = try node(draft, "plan").kind else { return }
        #expect(config.model == "sonnet")
    }

    @Test func candidatesStepperResizes() async throws {
        var config = PromptConfig(model: "opus", prompt: "", candidates: [], allowedTools: [], maxTurns: nil)
        config.setCandidateCount(3)
        #expect(config.candidates == ["opus", "opus", "opus"])
        config.candidates[1] = "haiku"
        config.setCandidateCount(2)
        #expect(config.candidates == ["opus", "haiku"])
        config.setCandidateCount(4)
        #expect(config.candidates == ["opus", "haiku", "opus", "opus"])
        config.setCandidateCount(1)
        #expect(config.candidates == [])
        config.setCandidateCount(9)
        #expect(config.candidates.count == 6, "clamped to 6")
        config.setCandidateCount(0)
        #expect(config.candidates == [])
        #expect(config.candidateCount == 1)

        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        #expect(try window.element(identifier: "inspector.candidates").value == "1")
        #expect((try? window.element(identifier: "inspector.candidate.0")) == nil, "single run: no per-candidate pickers")
        try await press("node.implement", in: window)
        #expect(try window.element(identifier: "inspector.candidates").value == "3")
        try window.click(window.element(identifier: "inspector.candidate.1"))
        try window.chooseMenuItem("haiku")
        try await window.runUntilIdle()
        guard case .prompt(let c) = try node(draft, "implement").kind else { return }
        #expect(c.candidates == ["sonnet", "haiku", "haiku"])
    }

    @Test func toolsAndMaxTurnsParse() async throws {
        #expect(InspectorView.parseTools("  Read \n\n Grep\n   \nBash(git log:*)\n") == ["Read", "Grep", "Bash(git log:*)"])
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        try window.click(window.element(identifier: "inspector.maxTurns"))
        window.typeText("1a2")
        try await window.runUntilIdle()
        guard case .prompt(let c) = try node(draft, "plan").kind else { return }
        #expect(c.maxTurns == 12)
        #expect(try window.element(identifier: "inspector.maxTurns").value == "12")
    }

    @Test func inspectorShowsAndRenamesIncomingWires() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        #expect(try window.element(identifier: "inspector.id").value == "plan")
        let field = try window.element(identifier: "inspector.wire.issue.issue")
        _ = try window.element(identifier: "inspector.wire.repo.repo")
        window.click(at: ScreenPoint(x: field.frame.origin.x + field.frame.size.width - 4,
                                         y: field.frame.origin.y + field.frame.size.height / 2))
        window.typeText("2")
        try await window.runUntilIdle()
        #expect(draft.flow.wires.contains(Wire(from: "issue", to: "plan", input: "issue2")))
        #expect(try window.element(identifier: "inspector.wire.issue.issue2").value == "issue2")
    }

    // MARK: Validation

    @Test func validationBannerNamesNodesByTitle() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        draft.edit("bind") { $0.nodes[$0.nodes.firstIndex { $0.id == "plan" }!].inputs["issue"] = .fixed("x") }
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "studio.validation").value == "Plan: input {issue} is both wired and set — choose one")
        _ = model
    }

    @Test func invalidDraftCannotSaveOrLaunch() async throws {
        let (model, client, window) = try await fixture()
        let draft = try #require(model.draft)
        model.studioValues["issue"] = "42"
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "studio.validation")) == nil)
        #expect(try window.element(identifier: "studio.save").isEnabled)
        #expect(try window.element(identifier: "studio.launch").isEnabled)
        draft.edit("unwire") { $0.wires.removeAll() }
        try await window.runUntilIdle()
        guard case .failure(let error) = draft.validation else { Issue.record("should be invalid"); return }
        let shown = try window.element(identifier: "studio.validation").value
        #expect(shown == draft.flow.message(for: error))
        #expect((try? window.element(identifier: "studio.error")) == nil, "no duplicate toolbar error")
        #expect(try window.element(identifier: "studio.save").isEnabled == false)
        #expect(try window.element(identifier: "studio.launch").isEnabled == false)
        #expect(await model.saveDraft() == false)
        #expect(await model.launchFromStudio() == nil)
        #expect(client.files.saved.isEmpty)
        #expect(await !client.calls.contains { $0.hasPrefix("launch") })
        draft.undo()
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "studio.validation")) == nil)
        #expect(try window.element(identifier: "studio.save").isEnabled)
    }

    @Test func editingDraftDoesNotChangeShownRun() async throws {
        let run = makeRun("#1 shown", status: .completed)
        let (model, _, window) = try await fixture(runs: [run])
        let draft = try #require(model.draft)
        model.studioRun = run.id
        try await press("palette.shell", in: window)
        draft.edit("rename") { $0.name = "Edited" }
        draft.deleteNode("gate")
        draft.connect(from: "issue", to: "pick")
        try await window.runUntilIdle()
        #expect(model.runs[run.id]?.flow == BuiltinFlows.fixGitHubIssue)
        #expect(model.studioShownRun?.flow == BuiltinFlows.fixGitHubIssue)
        #expect(draft.flow != BuiltinFlows.fixGitHubIssue)
        // The overlay still reads the run: the draft's remaining nodes show its states, the deleted one is gone.
        _ = try window.element(identifier: "node.plan.status")
        #expect((try? window.element(identifier: "node.gate")) == nil)
    }

    // MARK: Save and dirty switch

    @Test func saveWritesFlowFile() async throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, client, window) = try await fixture(repos: [dir])
        let draft = try #require(model.draft)
        try await press("palette.shell", in: window)
        #expect(draft.isDirty)
        let edited = draft.flow
        try await press("studio.save", in: window)
        try await press("save.dest.\(dir.lastPathComponent)", in: window)
        // The new file name is chosen off the main actor.
        try await window.runUntil { !client.files.saved.isEmpty }
        let expected = dir.appendingPathComponent(".flows/fix-github-issue.flow")
        #expect(client.files.saved.map(\.url) == [expected])
        // A repo save turns the unset Exposed repo into This repo.
        let written = FlowCatalog.prepareForSave(edited, destination: .of(file: expected), origin: nil).0
        #expect(client.files.saved.first?.flow == written)
        #expect(draft.flow == written)
        #expect(draft.isDirty == false)
        #expect(draft.url == expected)
        #expect(model.workingOn.contains(.flow(expected)))
        #expect(try window.element(identifier: "studio.file").value == "fix-github-issue.flow")
    }

    func openDirty(_ model: AppModel) throws -> (FlowDraft, URL, URL) {
        let a = repo.appendingPathComponent(".flows/a.flow"), b = repo.appendingPathComponent(".flows/b.flow")
        model.open(flow: a)
        let draft = try #require(model.draft)
        draft.edit("rename") { $0.name = "Edited" }
        return (draft, a, b)
    }

    @Test func dirtySwitchAsks() async throws {
        let (model, _, window) = try await fixture()
        let (draft, a, b) = try openDirty(model)
        model.open(flow: a)
        try await window.runUntilIdle()
        #expect(model.pendingOpen == nil && window.presentedAlert == nil, "the same file never asks")
        model.open(flow: b)
        try await window.runUntilIdle()
        #expect(model.pendingOpen == b)
        #expect(model.draft === draft && draft.url == a)
        let alert = try #require(window.presentedAlert)
        #expect(alert.buttons.map(\.title).sorted() == ["Cancel", "Discard", "Save"])
        #expect(!model.workingOn.contains(.flow(b)))
    }

    @Test func cleanSwitchDoesNotAsk() async throws {
        let (model, _, window) = try await fixture()
        let a = repo.appendingPathComponent(".flows/a.flow"), b = repo.appendingPathComponent(".flows/b.flow")
        model.open(flow: a)
        model.open(flow: b)
        try await window.runUntilIdle()
        #expect(model.pendingOpen == nil && window.presentedAlert == nil)
        #expect(model.draft?.url == b)
    }

    @Test func dirtySwitchSaveThenOpens() async throws {
        let (model, client, window) = try await fixture()
        let (draft, a, b) = try openDirty(model)
        let edited = draft.flow
        model.open(flow: b)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Save")
        try await window.runUntil { model.draft?.url == b }
        #expect(client.files.saved.map(\.url) == [a])
        #expect(client.files.saved.first?.flow == edited)
        #expect(model.draft?.url == b)
        #expect(model.draft?.isDirty == false)
        #expect(model.pendingOpen == nil)
        #expect(model.workingOn.contains(.flow(b)))
    }

    @Test func dirtySwitchDiscardOpens() async throws {
        let (model, client, window) = try await fixture()
        let (_, _, b) = try openDirty(model)
        model.open(flow: b)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Discard")
        try await window.runUntilIdle()
        #expect(client.files.saved.isEmpty)
        #expect(model.draft?.url == b)
        #expect(model.pendingOpen == nil)
    }

    @Test func dirtySwitchCancelKeepsDraft() async throws {
        let (model, client, window) = try await fixture()
        let (draft, a, b) = try openDirty(model)
        model.open(flow: b)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Cancel")
        try await window.runUntilIdle()
        #expect(client.files.saved.isEmpty)
        #expect(model.draft === draft && draft.url == a && draft.isDirty)
        #expect(model.pendingOpen == nil)
        #expect(window.presentedAlert == nil)
    }

    @Test func escapeOnDirtySwitchAlertCancels() async throws {
        // The window draws its alerts, so Escape reaches the alert as a key press.
        let client = FakeEngineClient(repos: [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model, options: .init(presentsAlertsNatively: false))
        try await window.runUntilIdle()
        await model.waitUntilReady()
        model.screen = .studio
        try await window.runUntilIdle()
        let (draft, a, b) = try openDirty(model)
        model.open(flow: b)
        try await window.runUntilIdle()
        #expect(model.pendingOpen == b)
        #expect(try window.elements(role: .alert).count == 1)
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(try window.elements(role: .alert).isEmpty)
        #expect(model.pendingAction == nil)
        #expect(client.files.saved.isEmpty)
        #expect(model.draft === draft && draft.url == a && draft.isDirty, "the draft is kept")
    }

    // MARK: Fix round 1

    func typeAtEnd(_ window: TestWindow, _ id: String, _ text: String) throws {
        let field = try window.element(identifier: id)
        window.click(at: ScreenPoint(x: field.frame.origin.x + field.frame.size.width - 4,
                                     y: field.frame.origin.y + field.frame.size.height / 2))
        window.typeText(text)
    }

    @Test func coalescingNeverJoinsAnOlderStep() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        draft.edit("rename") { $0.name = "Edited" }
        try await press("node.plan", in: window)
        try typeAtEnd(window, "inspector.title", "s")
        window.typeKey(.delete)
        window.typeText("t")
        try await window.runUntilIdle()
        #expect(try node(draft, "plan").title == "Plant")
        #expect(draft.undoStack.count == 2)
        draft.undo()
        #expect(draft.flow.name == "Edited")
        #expect(try node(draft, "plan").title == "Plan")
    }

    @Test func pickerChoicesAreSeparateSteps() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        for choice in ["sonnet", "haiku"] {
            try window.click(window.element(identifier: "inspector.model"))
            try window.chooseMenuItem(choice)
            try await window.runUntilIdle()
        }
        #expect(draft.undoStack.count == 2)
    }

    @Test func typingBurstEndsOnSelectionChangeAndCanvasClick() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        try typeAtEnd(window, "inspector.title", "a")
        try await press("node.implement", in: window)
        try await press("node.plan", in: window)
        try typeAtEnd(window, "inspector.title", "b")
        try await window.runUntilIdle()
        #expect(try node(draft, "plan").title == "Planab")
        #expect(draft.undoStack.count == 2, "selecting another node and back ends the burst")
        // Clicking the same node on the canvas moves focus off the field too.
        try await press("node.plan", in: window)
        try typeAtEnd(window, "inspector.title", "c")
        try await window.runUntilIdle()
        #expect(draft.undoStack.count == 3)
    }

    @Test func dragBetweenAlreadyWiredPairIsNoOp() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        let from = draft.geometry.outPort(try node(draft, "issue")), to = draft.geometry.inPort(try node(draft, "plan"))
        window.drag(from: try screen(window, draft, from), to: try screen(window, draft, to))
        try await window.runUntilIdle()
        #expect(draft.flow == BuiltinFlows.fixGitHubIssue && draft.undoStack.isEmpty)
    }

    @Test func hitWireToleranceIsInScreenPoints() async throws {
        let flow = BuiltinFlows.fixGitHubIssue
        for zoom in [1.0, 2.0] {
            let g = CanvasGeometry(pan: ScreenPoint(x: Pixels(10), y: Pixels(20)), zoom: zoom)
            let a = g.outPort(flow.node("plan")!), b = g.inPort(flow.node("implement")!)
            let mid = g.toScreen(CanvasPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
            func at(_ dx: Float) -> ScreenPoint { ScreenPoint(x: mid.x + Pixels(dx), y: mid.y) }
            let wire = Wire(from: "plan", to: "implement", input: "plan")
            #expect(g.hitWire(at: at(0), in: flow) == wire)
            #expect(g.hitWire(at: at(5), in: flow) == wire, "within 6 pt at zoom \(zoom)")
            #expect(g.hitWire(at: at(-5), in: flow) == wire)
            #expect(g.hitWire(at: at(9), in: flow) == nil, "just outside 6 pt at zoom \(zoom)")
        }
    }

    @Test func dirtySwitchSaveFailureKeepsDraft() async throws {
        let (model, client, window) = try await fixture()
        let (draft, a, b) = try openDirty(model)
        client.files.failSave = true
        model.open(flow: b)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Save")
        try await window.runUntil { model.notice != nil }
        #expect(model.draft === draft && draft.url == a && draft.isDirty)
        #expect(model.notice?.text == "engine said no")
        #expect(model.pendingOpen == nil)
        #expect(!model.workingOn.contains(.flow(b)))
    }

    // MARK: Destination, new flows, Open Flow (Task 6)

    /// Starts a save and waits for the destination panel.
    func startSave(_ model: AppModel, _ window: TestWindow) async throws -> Task<Bool, Never> {
        let saving = Task { await model.saveDraft() }
        try await window.runUntil { model.isSavePanelVisible }
        return saving
    }

    @Test func sameNamedReposGetDistinctDestinationIds() async throws {
        let (_, client, window) = try await fixture(repos: [URL(fileURLWithPath: "/work/a/app"), URL(fileURLWithPath: "/work/b/app")])
        try await press("studio.save", in: window)
        _ = try window.element(identifier: "save.dest.app")
        _ = try window.element(identifier: "save.dest.app-2")
        try await press("save.dest.app-2", in: window)
        #expect(client.files.saved.first?.url.path.hasPrefix("/work/b/app/") == true)
    }

    @Test func firstSaveAsksDestination() async throws {
        let (model, client, window) = try await fixture(repos: [URL(fileURLWithPath: "/work/alpha"), URL(fileURLWithPath: "/work/beta")])
        let draft = try #require(model.draft)
        #expect(draft.location == .builtin)
        try await press("studio.save", in: window)
        _ = try window.element(identifier: "save.panel")
        for id in ["save.dest.library", "save.dest.alpha", "save.dest.beta", "save.cancel"] {
            _ = try window.element(identifier: id)
        }
        #expect(client.files.saved.isEmpty, "nothing is written before a destination is chosen")
        // Escape cancels.
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "save.panel")) == nil)
        #expect(client.files.saved.isEmpty && draft.location == .builtin)
        // The built-in asks too.
        model.loadBuiltinDraft()
        try await press("studio.save", in: window)
        _ = try window.element(identifier: "save.panel")
    }

    @Test func saveToLibraryWritesThere() async throws {
        let library = try tempRepo()
        defer { try? FileManager.default.removeItem(at: library) }
        let (model, client, window) = try await fixture()
        client.catalog.library = library
        let draft = try #require(model.draft)
        let saving = try await startSave(model, window)
        try await press("save.dest.library", in: window)
        #expect(await saving.value)
        let expected = library.appendingPathComponent("fix-github-issue.flow")
        #expect(client.files.saved.map(\.url) == [expected])
        #expect(draft.location == .library(file: expected))
        #expect(draft.isDirty == false)
        #expect(model.workingOn.contains(.flow(expected)))
        // The built-in's Repo node is already Exposed, so there is nothing to say.
        #expect(model.notice == nil)
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "studio.file").value == "fix-github-issue.flow")
        // Saving again writes the same file, without asking.
        #expect(await model.saveDraft())
        #expect(client.files.saved.map(\.url) == [expected, expected])
        #expect(!model.isSavePanelVisible)
    }

    @Test func saveToLibraryNoticeForThisRepo() async throws {
        let (model, client, window) = try await fixture()
        let draft = try #require(model.draft)
        draft.edit("this repo") { flow in
            for i in flow.nodes.indices where flow.nodes[i].id == "repo" { flow.nodes[i].kind = .repo(RepoConfig(mode: .thisRepo)) }
        }
        let saving = try await startSave(model, window)
        model.chooseSaveDestination(.library)
        #expect(await saving.value)
        guard case .repo(let config)? = client.files.saved.first?.flow.node("repo")?.kind else { Issue.record("no repo"); return }
        #expect(config.mode == .exposed(default: nil))
        #expect(model.notice == Notice("Saved to the library: the repo is now asked at launch (no default).", kind: .info))
    }

    @Test func saveToRepoMakesThisRepo() async throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, client, window) = try await fixture(repos: [dir])
        let draft = try #require(model.draft)
        let saving = try await startSave(model, window)
        try await press("save.dest.\(dir.lastPathComponent)", in: window)
        #expect(await saving.value)
        let expected = dir.appendingPathComponent(".flows/fix-github-issue.flow")
        guard case .repo(let config)? = client.files.saved.first?.flow.node("repo")?.kind else { Issue.record("no repo"); return }
        #expect(config.mode == .thisRepo)
        #expect(draft.location == .of(file: expected))
        guard case .repo(let shown)? = draft.flow.node("repo")?.kind else { return }
        #expect(shown.mode == .thisRepo, "the draft shows what the file holds")
        #expect(draft.isDirty == false)
        #expect(draft.lastSavedFlow == draft.flow)
    }

    @Test func saveDestinationAddSavesIntoNewRepo() async throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, client, window) = try await fixture(gitRepos: [dir.standardizedFileURL.path])
        let draft = try #require(model.draft)
        let saving = try await startSave(model, window)
        try await press("save.dest.add", in: window)
        #expect(model.isSavePanelVisible, "the save waits for the folder")
        #expect(model.addRepoRequest == .saveDestination)
        try window.respondToFileDialog(choosing: [dir.path])
        #expect(await saving.value)
        let expected = dir.standardizedFileURL.appendingPathComponent(".flows/fix-github-issue.flow")
        #expect(client.files.saved.first?.url == expected)
        #expect(draft.location == .of(file: expected))
        #expect(model.repos.map(\.path).contains(dir.standardizedFileURL.path))
        #expect(!model.isSavePanelVisible)
    }

    @Test func saveRechecksValidityAfterTheDestinationAnswers() async throws {
        let (model, client, window) = try await fixture()
        let draft = try #require(model.draft)
        let saving = try await startSave(model, window)
        draft.edit("unwire") { $0.wires.removeAll() }
        try await window.runUntilIdle()
        model.chooseSaveDestination(.library)
        #expect(await saving.value == false)
        #expect(client.files.saved.isEmpty)
        #expect(model.notice != nil)
        #expect(draft.location == .builtin)
    }

    @Test func saveDestinationAddCancelCancelsTheSave() async throws {
        let (model, client, window) = try await fixture()
        let saving = try await startSave(model, window)
        try await press("save.dest.add", in: window)
        try window.cancelFileDialog()
        #expect(await saving.value == false)
        #expect(!model.isSavePanelVisible)
        #expect(client.files.saved.isEmpty)
    }

    @Test func inspectorChooseFolderSetsFixedPath() async throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.standardizedFileURL.path
        let (model, _, window) = try await fixture(gitRepos: [path])
        let draft = try #require(model.draft)
        try await press("node.repo", in: window)
        try window.click(window.element(identifier: "inspector.repo.mode"))
        try window.chooseMenuItem("Fixed")
        try await window.runUntilIdle()
        let steps = draft.undoStack.count
        try await press("inspector.repo.add", in: window)
        #expect(model.addRepoRequest == .repoNode("repo"))
        try window.respondToFileDialog(choosing: [dir.path])
        try await window.runUntil {
            if case .repo(let c)? = draft.flow.node("repo")?.kind { return c.mode == .fixed(path: path) }
            return false
        }
        #expect(draft.undoStack.count == steps + 1)
        #expect(model.repos.map(\.path).contains(path))
        draft.undo()
        guard case .repo(let c)? = draft.flow.node("repo")?.kind else { throw KindMismatch() }
        #expect(c.mode == .fixed(path: "/repo"))
    }

    @Test func studioAddSelectsNewRepo() async throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.standardizedFileURL.path
        let (model, _, window) = try await fixture(gitRepos: [path])
        try await press("studio.field.repo.add", in: window)
        #expect(model.addRepoRequest == .launchField)
        try window.respondToFileDialog(choosing: [dir.path])
        try await window.runUntil { model.studioValues["repo"] == path }
    }

    @Test func saveCancelKeepsDraftUnsaved() async throws {
        let (model, client, window) = try await fixture()
        let draft = try #require(model.draft)
        draft.edit("rename") { $0.name = "Edited" }
        let saving = try await startSave(model, window)
        try await press("save.cancel", in: window)
        #expect(await saving.value == false)
        #expect(!model.isSavePanelVisible)
        #expect(draft.location == .builtin && draft.isDirty)
        #expect(client.files.saved.isEmpty)
        #expect(model.notice == nil)
    }

    @Test func dirtySwitchSaveOnUnsavedAsksDestination() async throws {
        let (model, client, window) = try await fixture()
        let draft = try #require(model.draft)
        draft.edit("rename") { $0.name = "Edited" }
        let target = repo.appendingPathComponent(".flows/b.flow")
        model.open(flow: target)
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Save")
        try await window.runUntil { model.isSavePanelVisible }
        #expect(model.pendingAction == nil, "the alert's answer was taken first")
        #expect(model.draft === draft, "not switched yet")
        try await press("save.dest.library", in: window)
        try await window.runUntil { model.draft?.url == target }
        #expect(client.files.saved.count == 1)
        // Cancelling the panel cancels the switch.
        let again = try #require(model.draft)
        again.edit("rename") { $0.name = "Edited 2" }
        model.draft = FlowDraft(flow: again.flow, location: .unsaved)
        let other = try #require(model.draft)
        other.edit("rename") { $0.name = "Edited 3" }
        model.open(flow: repo.appendingPathComponent(".flows/c.flow"))
        try await window.runUntilIdle()
        try window.respondToAlert(button: "Save")
        try await window.runUntil { model.isSavePanelVisible }
        try await press("save.cancel", in: window)
        try await window.runUntil { !model.isSavePanelVisible }
        #expect(model.draft === other && other.isDirty && other.location == .unsaved)
        #expect(client.files.saved.count == 1)
        #expect(model.pendingAction == nil)
    }

    @Test func newFlowLaunchesWithFields() async throws {
        let (model, client, window) = try await fixture()
        await model.newFlow()
        try await window.runUntilIdle()
        let draft = try #require(model.draft)
        #expect(draft.flow.nodes.map(\.id) == ["repo"])
        // The repo field is the one launch field.
        #expect(model.studioLaunch.fields.map(\.name) == ["repo"])
        model.studioValues["repo"] = "/repo"
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "studio.launch").isEnabled)
        #expect(await model.launchFromStudio() != nil)
        #expect(await client.launches.first?.values == ["repo": "/repo"])
        #expect(await client.launches.first?.location == .unsaved)
    }

    @Test func paletteRepoDefaultsToExposed() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("palette.repo", in: window)
        guard case .repo(let config)? = draft.flow.node(try #require(draft.selection))?.kind else { Issue.record("not a repo"); return }
        #expect(config.mode == .exposed(default: nil))
    }

    @Test func openFlowListsCatalog() async throws {
        let (model, client, window) = try await fixture()
        let lib = URL(fileURLWithPath: "/lib/mine.flow"), inRepo = URL(fileURLWithPath: "/repo/.flows/theirs.flow")
        client.catalog.entries = [
            FlowEntry(id: "builtin:Fix GitHub issue", name: "Fix GitHub issue", location: .builtin, file: nil),
            FlowEntry(id: lib.path, name: "Mine", location: .library(file: lib), file: lib),
            FlowEntry(id: inRepo.path, name: "Theirs", location: .of(file: inRepo), file: inRepo),
        ]
        await model.refreshCatalog()
        model.showOpenFlow()
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "openFlow.builtin").label == "Fix GitHub issue \u{2014} Built-in")
        #expect(try window.element(identifier: "openFlow.mine.flow").label == "Mine \u{2014} Library")
        #expect(try window.element(identifier: "openFlow.theirs.flow").label == "Theirs \u{2014} repo")
        try await press("openFlow.mine.flow", in: window)
        #expect(model.draft?.location == .library(file: lib))
        model.showOpenFlow()
        try await window.runUntilIdle()
        try await press("openFlow.builtin", in: window)
        #expect(model.draft?.location == .builtin)
        #expect(model.screen == .studio)
        #expect(!model.isOpenFlowVisible)
    }

    // MARK: Input bindings and the Repo node

    /// Gives the plan prompt a third placeholder, `{topic}`, that nothing wires.
    func planWithTopic(_ draft: FlowDraft) {
        draft.edit("test.topic") { flow in
            guard let i = flow.nodes.firstIndex(where: { $0.id == "plan" }), case .prompt(var c) = flow.nodes[i].kind else { return }
            c.prompt += "\n{topic}"
            flow.nodes[i].kind = .prompt(c)
        }
    }

    /// Scrolls the inspector to its end, where the Inputs rows are.
    func scrollInspectorToEnd(_ window: TestWindow) async throws {
        try window.scroll(window.element(identifier: "inspector.id"), byDeltaX: 0, deltaY: -2000)
        try await window.runUntilIdle()
    }

    func planWires(_ draft: FlowDraft, _ input: String) -> [Wire] {
        draft.flow.wires.filter { $0.to == "plan" && $0.input == input }
    }

    @Test func inspectorListsInputs() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        planWithTopic(draft)
        try await press("node.plan", in: window)
        try await scrollInspectorToEnd(window)
        for name in ["issue", "repo", "topic"] {
            _ = try window.element(identifier: "inspector.input.\(name)")
            _ = try window.element(identifier: "inspector.input.\(name).mode.wire")
            _ = try window.element(identifier: "inspector.input.\(name).mode.value")
            _ = try window.element(identifier: "inspector.input.\(name).mode.exposed")
        }
        #expect(try window.element(identifier: "inspector.input.issue.source").value == "Issue")
        #expect(try window.element(identifier: "inspector.input.topic.source").value == "not wired")
        // A pick node has no inputs section.
        try await press("node.pick", in: window)
        #expect((try? window.element(identifier: "inspector.input.recommendation")) == nil)
    }

    @Test func switchToValueRemovesWire() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        try await scrollInspectorToEnd(window)
        #expect(planWires(draft, "issue").count == 1)
        try await press("inspector.input.issue.mode.value", in: window)
        #expect(planWires(draft, "issue").isEmpty)
        #expect(try node(draft, "plan").inputs["issue"] == .fixed(""))
        try typeAtEnd(window, "inspector.input.issue.value", "abc")
        try await window.runUntilIdle()
        #expect(try node(draft, "plan").inputs["issue"] == .fixed("abc"))
        try await press("inspector.input.issue.mode.wire", in: window)
        #expect(try node(draft, "plan").inputs["issue"] == nil)
    }

    @Test func switchToExposedSetsBinding() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        planWithTopic(draft)
        try await press("node.plan", in: window)
        try await scrollInspectorToEnd(window)
        try await press("inspector.input.topic.mode.exposed", in: window)
        #expect(try node(draft, "plan").inputs["topic"] == .exposed(default: nil))
        try typeAtEnd(window, "inspector.input.topic.default", "x")
        try await window.runUntilIdle()
        #expect(try node(draft, "plan").inputs["topic"] == .exposed(default: "x"))
        // Exposed over a wire removes the wire.
        try await press("inspector.input.issue.mode.exposed", in: window)
        #expect(planWires(draft, "issue").isEmpty)
        #expect(try node(draft, "plan").inputs["issue"] == .exposed(default: nil))
    }

    @Test func renamingPlaceholderPrunesBinding() async throws {
        let (model, _, _) = try await fixture()
        let draft = try #require(model.draft)
        planWithTopic(draft)
        draft.edit("test.bind") { flow in
            if let i = flow.nodes.firstIndex(where: { $0.id == "plan" }) {
                flow.nodes[i].inputs["topic"] = .exposed(default: "x")
            }
        }
        let steps = draft.undoStack.count
        draft.editPrompt("plan", "prompt") { $0.prompt = $0.prompt.replacingOccurrences(of: "{topic}", with: "{subject}") }
        #expect(try node(draft, "plan").inputs["topic"] == nil, "the stale binding is gone")
        #expect(!(try node(draft, "plan").hasExposedInput), "and no longer counts as exposed")
        #expect(draft.undoStack.count == steps + 1)
        draft.undo()
        #expect(try node(draft, "plan").inputs["topic"] == .exposed(default: "x"), "one undo step brings it back")
    }

    @Test func wireOntoBoundInputClearsBinding() async throws {
        let (model, _, _) = try await fixture()
        let draft = try #require(model.draft)
        planWithTopic(draft)
        draft.edit("test.bind") { flow in
            if let i = flow.nodes.firstIndex(where: { $0.id == "plan" }) { flow.nodes[i].inputs["topic"] = .fixed("x") }
        }
        let steps = draft.undoStack.count
        draft.connect(from: "issue", to: "plan", input: "topic")
        #expect(try node(draft, "plan").inputs["topic"] == nil)
        #expect(planWires(draft, "topic").count == 1)
        #expect(draft.undoStack.count == steps + 1)
        draft.undo()
        #expect(try node(draft, "plan").inputs["topic"] == .fixed("x"))
        #expect(planWires(draft, "topic").isEmpty)
    }

    @Test func bindingSwitchIsOneUndoStep() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        try await scrollInspectorToEnd(window)
        let before = draft.flow
        let steps = draft.undoStack.count
        try await press("inspector.input.issue.mode.value", in: window)
        #expect(draft.undoStack.count == steps + 1)
        draft.undo()
        #expect(draft.flow == before)
    }

    @Test func repoModePickerSetsMode() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.repo", in: window)
        try window.click(window.element(identifier: "inspector.repo.mode"))
        let menu = try #require(window.presentedMenu)
        #expect(menu.items.map(\.title) == ["This repo", "Fixed", "Exposed"])
        #expect(menu.items.first { $0.isOn }?.title == "Exposed")
        try window.chooseMenuItem("Fixed")
        try await window.runUntilIdle()
        guard case .repo(let fixed) = try node(draft, "repo").kind else { throw KindMismatch() }
        #expect(fixed.mode == .fixed(path: "/repo"))
        try window.click(window.element(identifier: "inspector.repo.path"))
        #expect(window.presentedMenu?.items.map(\.title) == ["repo"])
        try window.chooseMenuItem("repo")
        try await window.runUntilIdle()
        try typeAtEnd(window, "inspector.repo.pathField", "2")
        try await window.runUntilIdle()
        guard case .repo(let typed) = try node(draft, "repo").kind else { throw KindMismatch() }
        #expect(typed.mode == .fixed(path: "/repo2"))
        try window.click(window.element(identifier: "inspector.repo.mode"))
        try window.chooseMenuItem("This repo")
        try await window.runUntilIdle()
        guard case .repo(let here) = try node(draft, "repo").kind else { throw KindMismatch() }
        #expect(here.mode == .thisRepo)
        #expect((try? window.element(identifier: "inspector.repo.path")) == nil)
    }

    @Test func flowInputValueRow() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.issue", in: window)
        _ = try window.element(identifier: "inspector.flowInput.mode")
        try await press("inspector.flowInput.mode.fixed", in: window)
        guard case .flowInput(let c) = try node(draft, "issue").kind else { throw KindMismatch() }
        #expect(c.binding == .fixed(""))
        try typeAtEnd(window, "inspector.flowInput.value", "7")
        try await window.runUntilIdle()
        guard case .flowInput(let d) = try node(draft, "issue").kind else { throw KindMismatch() }
        #expect(d.binding == .fixed("7"))
    }

    @Test func exposedTagShowsOnCard() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        planWithTopic(draft)
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "node.plan.exposed")) == nil)
        try await press("node.plan", in: window)
        try await scrollInspectorToEnd(window)
        try await press("inspector.input.topic.mode.exposed", in: window)
        #expect(try window.element(identifier: "node.plan.exposed").value == "\u{21E2} launch")
        try await press("inspector.input.topic.mode.wire", in: window)
        #expect((try? window.element(identifier: "node.plan.exposed")) == nil)
    }

    @Test func reselectingSameModeIsNoUndoStep() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        try await press("node.plan", in: window)
        try await scrollInspectorToEnd(window)
        let steps = draft.undoStack.count
        try await press("inspector.input.issue.mode.wire", in: window)
        #expect(draft.undoStack.count == steps, "wired input, Wire again")
        try await press("inspector.input.issue.mode.value", in: window)
        try await press("inspector.input.issue.mode.value", in: window)
        #expect(draft.undoStack.count == steps + 1)
        try await press("inspector.input.issue.mode.exposed", in: window)
        try await press("inspector.input.issue.mode.exposed", in: window)
        #expect(draft.undoStack.count == steps + 2)
    }

    @Test func launchErrorShowsInBanner() async throws {
        let (model, _, window) = try await fixture()
        let draft = try #require(model.draft)
        #expect((try? window.element(identifier: "studio.validation")) == nil)
        draft.addNode(.repo)
        try await window.runUntilIdle()
        #expect(draft.plan != nil)
        #expect(try window.element(identifier: "studio.validation").value == "A flow can have only one Repo node")
        let shown = try window.elements(where: { $0.value == "A flow can have only one Repo node" })
        #expect(shown.count == 1, "the message appears once")
    }
}
