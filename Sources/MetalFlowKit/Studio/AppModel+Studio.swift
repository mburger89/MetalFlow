import Foundation
import MetalFlowCore

extension AppModel {
    /// The run the Studio overlays on the canvas, if one is selected and still known.
    public var studioShownRun: Run? { studioRun.flatMap { runs[$0] } }

    /// Runs of the draft's flow in the draft's repo, newest first.
    public var studioRuns: [Run] {
        guard let draft else { return [] }
        return order.compactMap { runs[$0] }.filter { $0.flow.name == draft.flow.name && $0.repo == draft.repo }
    }

    /// The text a unsaved flow's file name is made of: lowercase letters and digits joined by dashes.
    static func slug(_ name: String) -> String {
        var out = ""
        var dash = false
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                if dash, !out.isEmpty { out.append("-") }
                out.append(ch)
                dash = false
            } else {
                dash = true
            }
        }
        return out.isEmpty ? "flow" : out
    }

    /// Where an unsaved flow goes: `<repo>/.flows/<slug>.flow`, or `-2`, `-3`... when taken.
    static func newFlowURL(name: String, repo: URL) -> URL {
        let dir = repo.appendingPathComponent(FlowFile.directoryName, isDirectory: true)
        let base = slug(name)
        var candidate = dir.appendingPathComponent("\(base).flow")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).flow")
            n += 1
        }
        return candidate
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
            studioRun = nil
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

    /// Whether the draft can be saved or launched.
    public var draftIsValid: Bool {
        if let draft, case .success = draft.validation { return true }
        return false
    }

    /// Saves the draft: to its file, or into `<repo>/.flows/` under a fresh name. Sets a notice on failure.
    @discardableResult
    public func saveDraft() async -> Bool {
        guard let draft, draftIsValid else { return false }
        let target = draft.url ?? Self.newFlowURL(name: draft.flow.name, repo: draft.repo)
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
        let id = await launchGuarded(flow: draft.flow, repo: draft.repo, typed: typed)
        if id != nil, studioIssue == typed { studioIssue = "" }
        return id
    }
}
