import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct FlowEditingTests {
    let repo = URL(fileURLWithPath: "/repo")

    func fixture(runs: [Run] = [], repos: [URL]? = nil) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: runs, repos: repos ?? [repo])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
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
        let draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, url: nil, repo: repo)
        #expect(draft.isDirty == false)
        draft.edit("rename") { $0.name = "Renamed" }
        #expect(draft.isDirty)
        draft.undo()
        #expect(draft.isDirty == false, "undone back to the saved state")
        draft.redo()
        #expect(draft.isDirty)
        draft.didSave(to: URL(fileURLWithPath: "/repo/.flows/x.flow"))
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

    @Test func invalidDraftCannotSaveOrLaunch() async throws {
        let (model, client, window) = try await fixture()
        let draft = try #require(model.draft)
        model.studioIssue = "42"
        try await window.runUntilIdle()
        #expect((try? window.element(identifier: "studio.validation")) == nil)
        #expect(try window.element(identifier: "studio.save").isEnabled)
        #expect(try window.element(identifier: "studio.launch").isEnabled)
        draft.edit("unwire") { $0.wires.removeAll() }
        try await window.runUntilIdle()
        guard case .failure(let error) = draft.validation else { Issue.record("should be invalid"); return }
        #expect(try window.element(identifier: "studio.validation").value == error.errorDescription)
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
        let expected = dir.appendingPathComponent(".flows/fix-github-issue.flow")
        #expect(client.files.saved.map(\.url) == [expected])
        #expect(client.files.saved.first?.flow == edited)
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
        try await window.runUntilIdle()
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
        try await window.runUntilIdle()
        #expect(model.draft === draft && draft.url == a && draft.isDirty)
        #expect(model.notice?.text == "engine said no")
        #expect(model.pendingOpen == nil)
        #expect(!model.workingOn.contains(.flow(b)))
    }
}
