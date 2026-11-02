import Foundation
import MetalFlowCore

extension AppModel {
    /// The run the Studio overlays on the canvas, if one is selected and still known.
    public var studioShownRun: Run? {
        guard let run = studioRun.flatMap({ runs[$0] }), run.status != .discarded else { return nil }
        return run
    }

    /// Runs of the draft's flow, newest first. A draft with a file gets the runs launched from that file (compared as
    /// standardized paths); runs recorded without a file (built-in, unsaved, or saved before files were recorded) belong
    /// to a draft by flow name. Discarded runs have no worktrees left, so nothing can be shown or branched from them.
    public var studioRuns: [Run] {
        guard let draft else { return [] }
        let file = draft.url?.standardizedFileURL.path
        return order.compactMap { runs[$0] }.filter { run in
            guard run.status != .discarded else { return false }
            guard let runFile = run.flowFile else { return run.flow.name == draft.flow.name }
            return runFile.standardizedFileURL.path == file
        }
    }

    /// The text a unsaved flow's file name is made of: lowercase letters and digits joined by dashes.
    nonisolated static func slug(_ name: String) -> String { FlowCatalog.slug(name) }

    /// Opens the Studio with the built-in flow, unsaved, when it has nothing open. No repo is needed.
    func ensureDraft() {
        guard screen == .studio, draft == nil else { return }
        draft = FlowDraft(flow: BuiltinFlows.fixGitHubIssue, location: .builtin)
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
            draft = FlowDraft(flow: flow, location: .of(file: url))
            screen = .studio
        } catch {
            notice = Notice(error.localizedDescription)
        }
    }

    /// Shows a built-in flow in the Studio (saving it asks where to); the default one without an argument.
    /// The built-in already open keeps its draft; another built-in replaces it.
    func loadBuiltinDraft(_ flow: Flow = BuiltinFlows.fixGitHubIssue) {
        if !isOpen(builtin: flow) {
            draft = FlowDraft(flow: flow, location: .builtin)
        }
        screen = .studio
    }

    /// Whether the draft is `flow` the built-in. It goes by the name the draft was loaded with, since edits can rename it.
    private func isOpen(builtin flow: Flow) -> Bool {
        draft?.location == .builtin && draft?.lastSavedFlow.name == flow.name
    }

    /// What waits behind the unsaved-edits alert.
    public enum PendingAction: Sendable, Equatable {
        /// Open this flow file.
        case open(URL)
        /// Open the built-in flow with this name.
        case openBuiltin(String)
        /// Start a new flow.
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
        case .openBuiltin(let name): loadBuiltinDraft(BuiltinFlows.named(name) ?? BuiltinFlows.fixGitHubIssue)
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

    /// Saves the draft. One that already has a file is written there. One that has none (unsaved, or the built-in)
    /// first asks where to go, in the destination panel; cancelling the panel is not saving (false, no notice).
    /// Sets a notice on failure.
    @discardableResult
    public func saveDraft() async -> Bool {
        guard let draft, draftIsValid else { return false }
        let flow: Flow
        let location: FlowLocation
        if let url = draft.url {
            flow = draft.flow.droppingOrphanBindings()
            location = draft.location
            do { try client.saveFlow(flow, to: url) } catch {
                notice = Notice(error.localizedDescription)
                return false
            }
        } else {
            guard let choice = await askSaveDestination(), self.draft === draft else { return false }
            // The draft can change while the panel is up.
            if case .failure(let error) = draft.validation {
                notice = Notice("Not saved: \(draft.flow.message(for: error))")
                return false
            }
            let directory: URL
            switch choice {
            case .library: directory = client.libraryDirectory
            case .repo(let root): directory = root.appendingPathComponent(FlowFile.directoryName, isDirectory: true)
            }
            let name = draft.flow.name
            let target = await Task.detached { FlowCatalog.newFileURL(name: name, in: directory) }.value
            guard self.draft === draft else { return false }
            if case .library = choice { location = .library(file: target) } else { location = .of(file: target) }
            let (prepared, note) = FlowCatalog.prepareForSave(draft.flow, destination: location, origin: nil)
            flow = prepared
            do { try client.saveFlow(flow, to: target) } catch {
                notice = Notice(error.localizedDescription)
                return false
            }
            if let note { notice = Notice(note, kind: .info) }
        }
        draft.didSave(flow, at: location)
        if let url = draft.url, !workingOn.contains(.flow(url)) { workingOn.append(.flow(url)) }
        await refreshCatalog()
        return true
    }

    /// Shows the destination panel and waits for its answer: nil when cancelled.
    func askSaveDestination(_ mode: SavePanelMode = .save) async -> SaveDestination? {
        guard !isSavePanelVisible else { return nil }
        savePanelMode = mode
        isSavePanelVisible = true
        return await withCheckedContinuation { saveDestinationWaiter = $0 }
    }

    /// The destination panel's answer: a destination, or nil to cancel the save.
    public func chooseSaveDestination(_ destination: SaveDestination?) {
        guard isSavePanelVisible else { return }
        isSavePanelVisible = false
        let waiter = saveDestinationWaiter
        saveDestinationWaiter = nil
        waiter?.resume(returning: destination)
    }

    /// Copies the draft, with its unsaved edits, to a place chosen in the destination panel (the draft's own location
    /// is left out): the library, or a repo's `.flows`. The original file is never written. Into a repo the Repo node
    /// becomes This repo; into the library a This repo node is exposed with the origin repo as default. On success the
    /// Studio switches to the copy, with a fresh undo history. Cancelling the panel does nothing; a failed write sets
    /// a notice and leaves the draft as it was.
    public func copyDraft() async {
        guard let draft, draft.url != nil else { return }
        guard draftIsValid else {
            notice = Notice("Fix the flow's errors before copying it.")
            return
        }
        let origin: URL?
        let excluded: SaveDestination?
        switch draft.location {
        case .library: (origin, excluded) = (nil, .library)
        case .repo(let root, _): (origin, excluded) = (root, .repo(root))
        case .builtin, .unsaved: (origin, excluded) = (nil, nil)
        }
        guard let choice = await askSaveDestination(.copy(excluding: excluded)), self.draft === draft else { return }
        // The draft can change while the panel is up.
        if case .failure(let error) = draft.validation {
            notice = Notice("Not copied: \(draft.flow.message(for: error))")
            return
        }
        let directory: URL
        switch choice {
        case .library: directory = client.libraryDirectory
        case .repo(let root): directory = root.appendingPathComponent(FlowFile.directoryName, isDirectory: true)
        }
        let name = draft.flow.name
        let target = await Task.detached { FlowCatalog.newFileURL(name: name, in: directory) }.value
        guard self.draft === draft else { return }
        let location: FlowLocation
        if case .library = choice { location = .library(file: target) } else { location = .of(file: target) }
        let (prepared, note) = FlowCatalog.prepareForCopy(draft.flow, destination: location, origin: origin)
        do { try client.saveFlow(prepared, to: target) } catch {
            notice = Notice(error.localizedDescription)
            return
        }
        self.draft = FlowDraft(flow: prepared, location: location)
        if !workingOn.contains(.flow(target)) { workingOn.append(.flow(target)) }
        notice = Notice(["Copied to \(target.path)", note].compactMap { $0 }.joined(separator: ". "), kind: .info)
        await refreshCatalog()
    }

    /// The Studio launch row's fields for the draft at its location, or the message for why it cannot be launched.
    /// A draft that is not valid says so in the Studio's validation banner, so it has no message here.
    public var studioLaunch: (fields: [LaunchField], error: String?, canLaunch: Bool) {
        guard let draft else { return ([], nil, false) }
        do {
            let fields = try draft.flow.launchFields(location: draft.location)
            let filled = fields.allSatisfy { !$0.isRequired || !Self.trimmed(studioValue($0)).isEmpty }
            return (fields, nil, filled && !isLaunching)
        } catch {
            if case .invalid = error { return ([], nil, false) }
            return ([], draft.flow.message(for: error), false)
        }
    }

    /// The repo folder name shown read-only for a This repo or Fixed draft; nil for Exposed.
    public var studioResolvedRepo: String? {
        guard let draft else { return nil }
        for node in draft.flow.nodes {
            guard case .repo(let config) = node.kind else { continue }
            switch (config.mode, draft.location) {
            case (.thisRepo, .repo(let root, _)): return root.lastPathComponent
            case (.fixed(let path), _): return URL(fileURLWithPath: path).lastPathComponent
            default: break
            }
        }
        return nil
    }

    /// What the Studio row shows for `field`: the typed text, else its default (a repo field: the selected repo).
    public func studioValue(_ field: LaunchField) -> String {
        if let typed = studioValues[field.name] { return typed }
        switch field.kind {
        case .text, .githubIssue: return field.defaultValue ?? ""
        case .repo:
            if let def = field.defaultValue { return repos.first { $0.standardizedFileURL.path == def }?.path ?? "" }
            return selectedRepo?.path ?? repos.first?.path ?? ""
        }
    }

    /// Launches the draft's flow at its location with the Studio row's values, then clears the text fields whose
    /// text was not changed meanwhile.
    @discardableResult
    public func launchFromStudio() async -> RunID? {
        guard let draft, draftIsValid, studioLaunch.canLaunch else { return nil }
        let fields = studioLaunch.fields
        let typed = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, studioValue($0)) })
        let id = await launchGuarded(flow: draft.flow, location: draft.location, values: typed)
        if id != nil, self.draft === draft {
            for field in fields where field.kind != .repo && studioValue(field) == typed[field.name] {
                studioValues[field.name] = nil
            }
        }
        return id
    }
}

/// Where the destination panel can send a first save.
public enum SaveDestination: Sendable, Equatable {
    /// The library folder.
    case library
    /// This repo's `.flows` folder.
    case repo(URL)
}

/// What the destination panel is asking for.
public enum SavePanelMode: Sendable, Equatable {
    /// Where a flow with no file yet is saved.
    case save
    /// Where to copy a saved flow; `excluding` is its current location, which is not offered.
    case copy(excluding: SaveDestination?)
}

extension AppModel {
    /// File > New Flow: a new flow with one Repo node, "Untitled flow" or the first "Untitled flow N" the catalog
    /// does not use. With unsaved edits it asks first.
    public func newFlow() async {
        if let draft, draft.isDirty {
            pendingAction = .newFlow
            screen = .studio
            return
        }
        await newFlowWithoutAsking()
    }

    func newFlowWithoutAsking() async {
        let name = untitledName()
        let repo = Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .exposed(default: nil))),
                        position: Point(x: 24, y: 24))
        draft = FlowDraft(flow: Flow(name: name, nodes: [repo], wires: []), location: .unsaved)
        screen = .studio
    }

    /// "Untitled flow", or "Untitled flow 2", "Untitled flow 3"... when the catalog's flows already use the name, so
    /// the run overlay (which matches runs by flow name) never mixes up two new flows.
    func untitledName() -> String {
        let taken = Set(catalog.map(\.name))
        var name = "Untitled flow"
        var n = 2
        while taken.contains(name) {
            name = "Untitled flow \(n)"
            n += 1
        }
        return name
    }

    /// File > Open Flow...: shows the panel listing the catalog.
    public func showOpenFlow() { isOpenFlowVisible = true }

    /// Closes the Open Flow panel.
    public func hideOpenFlow() { isOpenFlowVisible = false }

    /// Opens a catalog entry from the panel and closes it.
    public func chooseEntry(_ entry: FlowEntry) {
        isOpenFlowVisible = false
        if let file = entry.file {
            open(flow: file)
        } else {
            openBuiltin(entry.builtinFlow ?? BuiltinFlows.fixGitHubIssue)
        }
    }

    /// Shows a built-in flow in the Studio (the default one without an argument); with unsaved edits to anything
    /// else, including another built-in, it asks first.
    public func openBuiltin(_ flow: Flow = BuiltinFlows.fixGitHubIssue) {
        if let draft, draft.isDirty, !isOpen(builtin: flow) {
            pendingAction = .openBuiltin(flow.name)
            return
        }
        loadBuiltinDraft(flow)
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
