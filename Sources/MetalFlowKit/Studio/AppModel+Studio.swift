import Foundation
import MetalFlowCore

extension AppModel {
    /// The run the Studio overlays on the canvas, if one is selected and still known.
    public var studioShownRun: Run? {
        guard let run = studioRun.flatMap({ runs[$0] }), run.status != .discarded else { return nil }
        return run
    }

    /// Runs of the draft's flow in the draft's repo, newest first. Discarded runs have no worktrees left, so
    /// nothing can be shown or branched from them.
    public var studioRuns: [Run] {
        guard let draft else { return [] }
        return order.compactMap { runs[$0] }.filter {
            $0.flow.name == draft.flow.name && $0.repo == draft.repo && $0.status != .discarded
        }
    }

    /// The text a unsaved flow's file name is made of: lowercase letters and digits joined by dashes.
    nonisolated static func slug(_ name: String) -> String { FlowCatalog.slug(name) }

    /// Where an unsaved flow goes: `<repo>/.flows/<slug>.flow`, or `-2`, `-3`... when taken.
    /// Reads the directory, so it runs off the main actor.
    nonisolated static func newFlowURL(name: String, repo: URL) -> URL {
        FlowCatalog.newFileURL(name: name, in: repo.appendingPathComponent(FlowFile.directoryName, isDirectory: true))
    }

    /// Opens the Studio with the built-in flow when it has nothing open and a repo is selected.
    func ensureDraft() {
        guard screen == .studio, draft == nil, let repo = launchForm.repo else { return }
        draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, url: nil, repo: repo)
    }

    /// The known repo that contains `url`, falling back to the selected repo, then to the folder above `.flows`.
    func repo(containing url: URL) -> URL {
        let path = url.standardizedFileURL.path
        let known = (repos + [launchForm.repo].compactMap { $0 })
            .filter { path.hasPrefix($0.standardizedFileURL.path + "/") }
            .max { $0.path.count < $1.path.count }
        return known ?? launchForm.repo ?? url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Loads a flow file into the Studio. A load error becomes a notice and leaves the screen alone.
    /// The flow that is already the draft keeps its draft and undo history.
    func loadDraft(from url: URL) {
        if let draft, draft.url == url {
            screen = .studio
            return
        }
        do {
            let flow = try client.loadFlow(url)
            draft = FlowDraft(flow: flow, url: url, repo: repo(containing: url))
            screen = .studio
        } catch {
            notice = Notice(error.localizedDescription)
        }
    }

    /// Keeps a pristine, untitled draft pointed at the selected repo.
    func retargetPristineDraft() {
        if let draft, draft.url == nil, !draft.isDirty, let repo = launchForm.repo { draft.repo = repo }
        ensureDraft()
    }

    /// What waits behind the unsaved-edits alert.
    public enum PendingAction: Sendable, Equatable {
        /// Open this flow file.
        case open(URL)
        /// Start a new, empty flow.
        case newFlow
        /// Quit the app, or close its window (the same thing: it is the only one).
        case quit
    }

    /// The user's answer to the unsaved-edits alert.
    public enum PendingOpenChoice: Sendable {
        /// Save the draft, then carry on.
        case save
        /// Throw the edits away and carry on.
        case discard
        /// Stay on the draft.
        case cancel
    }

    /// Resolves `action`, which was pending behind the unsaved-edits alert. For a quit: Save or Discard go on to the
    /// running-runs step; Cancel, and a Save that fails, cancel the quit.
    public func resolvePending(_ action: PendingAction, _ choice: PendingOpenChoice) async {
        pendingAction = nil
        switch choice {
        case .cancel:
            abandon(action)
        case .discard:
            await perform(action)
        case .save:
            if !draftIsValid {
                notice = Notice("Fix the flow's errors before saving it.")
                abandon(action)
                return
            }
            if await saveDraft() { await perform(action) } else { abandon(action) }
        }
    }

    /// Cancels the alert without choosing: the user stays on the draft. A pending quit is refused.
    public func cancelPending() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        abandon(action)
    }

    /// An unsaved-edits or quit alert went away. When no button answered it (it was dismissed some other way), it
    /// counts as Cancel, so no request is left unanswered.
    func alertDismissed() {
        cancelPending()
        if quitPending { cancelQuit() }
    }

    private func abandon(_ action: PendingAction) {
        if action == .quit { replyToTerminate(false) }
    }

    private func perform(_ action: PendingAction) async {
        switch action {
        case .open(let url): openWithoutAsking(url)
        case .newFlow: await newFlowWithoutAsking()
        case .quit:
            if continueQuit() == .now { replyToTerminate(true) }
        }
    }

    /// Whether the draft can be saved or launched.
    public var draftIsValid: Bool {
        if let draft, case .success = draft.validation { return true }
        return false
    }

    /// Saves the draft: to its file, or into `<repo>/.flows/` under a fresh name. Sets a notice on failure.
    @discardableResult
    public func saveDraft() async -> Bool {
        guard let draft, draftIsValid else { return false }
        let target: URL
        if let url = draft.url {
            target = url
        } else {
            let (name, repo) = (draft.flow.name, draft.repo)
            target = await Task.detached { Self.newFlowURL(name: name, repo: repo) }.value
        }
        do {
            try client.saveFlow(draft.flow, to: target)
        } catch {
            notice = Notice(error.localizedDescription)
            return false
        }
        draft.didSave(to: target)
        if !workingOn.contains(.flow(target)) { workingOn.append(.flow(target)) }
        if launchForm.repo == draft.repo { await selectRepo(draft.repo) }
        return true
    }

    /// Launches the draft's flow in its repo on the issue typed in the Studio, then clears that field.
    @discardableResult
    public func launchFromStudio() async -> RunID? {
        guard let draft, draftIsValid, !isLaunching, !Self.trimmed(studioIssue).isEmpty else { return nil }
        let typed = studioIssue
        let id = await launchGuarded(
            flow: draft.flow, location: draft.url.map { FlowLocation.of(file: $0) } ?? .unsaved, repo: draft.repo, typed: typed)
        if id != nil, studioIssue == typed { studioIssue = "" }
        return id
    }
}

extension AppModel {
    /// File > New Flow: an empty "Untitled flow" in the selected repo. With unsaved edits it asks first.
    public func newFlow() async {
        guard launchForm.repo != nil else {
            notice = Notice("Add a repo on the dashboard first.")
            return
        }
        if let draft, draft.isDirty {
            pendingAction = .newFlow
            screen = .studio
            return
        }
        await newFlowWithoutAsking()
    }

    func newFlowWithoutAsking() async {
        guard let repo = launchForm.repo else { return }
        let name = await untitledName(in: repo)
        // The scan took a moment: drop the result if the repo changed meanwhile.
        guard launchForm.repo == repo else { return }
        draft = FlowDraft(flow: Flow(name: name, nodes: [], wires: []), url: nil, repo: repo)
        screen = .studio
    }

    /// "Untitled flow", or "Untitled flow 2", "Untitled flow 3"... when the repo's flows already use the name, so
    /// the run overlay (which matches runs by flow name) never mixes up two new flows.
    /// Scans and loads the repo's flow files, so it runs off the main actor.
    func untitledName(in repo: URL) async -> String {
        let client = client
        return await Task.detached { Self.untitledName(client: client, in: repo) }.value
    }

    nonisolated static func untitledName(client: EngineClient, in repo: URL) -> String {
        let taken = Set(client.flows(in: repo).compactMap { try? client.loadFlow($0).name })
        var name = "Untitled flow"
        var n = 2
        while taken.contains(name) {
            name = "Untitled flow \(n)"
            n += 1
        }
        return name
    }

    /// File > Open Flow...: shows the repo / flow panel.
    public func showOpenFlow() { isOpenFlowVisible = true }

    /// Closes the Open Flow panel.
    public func hideOpenFlow() { isOpenFlowVisible = false }

    /// Opens a flow from the panel and closes it.
    public func chooseFlow(_ url: URL) {
        isOpenFlowVisible = false
        open(flow: url)
    }

    /// Whether File > Save is enabled: the Studio shows a valid draft.
    public var canSave: Bool { screen == .studio && draft != nil && draftIsValid }

    /// Whether Edit > Undo is enabled: the Studio shows a draft with something to undo.
    public var canUndo: Bool { screen == .studio && draft.map { !$0.undoStack.isEmpty } == true }

    /// Whether Edit > Redo is enabled.
    public var canRedo: Bool { screen == .studio && draft.map { !$0.redoStack.isEmpty } == true }

    /// Edit > Undo, on the Studio's draft.
    public func undo() { if canUndo { draft?.undo() } }

    /// Edit > Redo, on the Studio's draft.
    public func redo() { if canRedo { draft?.redo() } }

    /// Run > Launch...: the dashboard with the issue field focused.
    public func focusLaunch() {
        selectedRun = nil
        screen = .dashboard
        launchFocusRequested = true
    }

    /// Run > Go to Dashboard.
    public func goToDashboard() { screen = .dashboard }

    /// Run > Go to Studio.
    public func goToStudio() { screen = .studio }
}
