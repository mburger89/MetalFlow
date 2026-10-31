import Foundation
import MetalFlowCore

/// What the launch bar has selected and typed.
public struct LaunchForm: Sendable, Equatable {
    /// The chosen catalog entry.
    public var flow: FlowEntry.ID?
    /// Typed values, keyed by launch field name.
    public var values: [String: String] = [:]
    /// Creates an empty form.
    public init() {}
}

/// One card of the dashboard's "Needs you" section.
public struct NeedsItem: Identifiable, Equatable, Sendable {
    /// What the user has to do.
    public enum Kind: Equatable, Sendable {
        /// Pick one of the candidates.
        case pickWinner(recommended: LaneID?, allGatesFailed: Bool)
        /// Answer the agent's question.
        case question(String)
        /// Approve tools the agent was denied.
        case deniedTools([String])
        /// The run was cut short.
        case interrupted
        /// The node failed with this message.
        case failed(String)
    }
    /// The run.
    public var run: Run
    /// The node waiting.
    public var key: NodeKey
    /// What is wanted.
    public var kind: Kind
    /// `needs.<runID>.<nodeKey>`.
    public var id: String { "needs.\(run.id.rawValue).\(key)" }
}

extension AppModel {
    /// The key of an answer draft.
    public static func draftKey(_ run: RunID, _ node: NodeKey) -> String { "\(run.rawValue).\(node)" }

    /// One card per node that waits on the user, runs newest first, nodes in flow order.
    public var needsItems: [NeedsItem] {
        var items: [NeedsItem] = []
        for run in needsYou {
            for key in run.orderedNodeKeys {
                guard let node = run.nodes[key] else { continue }
                let kind: NeedsItem.Kind?
                switch node.state {
                case .needsYou(.pickWinner(let r, let all)): kind = .pickWinner(recommended: r, allGatesFailed: all)
                case .needsYou(.question(let q)): kind = .question(q)
                case .needsYou(.deniedTools(let t)): kind = .deniedTools(t)
                case .interrupted: kind = .interrupted
                case .failed(let message): kind = .failed(message)
                case .waiting, .running, .succeeded, .cancelled: kind = nil
                }
                if let kind { items.append(NeedsItem(run: run, key: key, kind: kind)) }
            }
        }
        return items
    }

    /// The one-word state of a run for chips and headers; a running run another process drives says so.
    public func statusText(_ run: Run) -> String {
        run.status == .running && runningElsewhere.contains(run.id) ? "Running in another mflow" : WorkingChip.statusText(run)
    }

    /// The text with surrounding whitespace and newlines removed: the one trim used by buttons and actions.
    public static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Re-reads the known repos, merges the added ones, keeps the selection valid and refreshes the catalog.
    public func refreshRepos() async {
        var merged = client.knownRepos()
        for url in addedRepos where !merged.contains(url) { merged.append(url) }
        repos = merged
        if selectedRepo == nil || !merged.contains(selectedRepo!) { selectRepo(merged.first) }
        await refreshCatalog()
    }

    /// Selects the repo new drafts default to.
    public func selectRepo(_ url: URL?) {
        selectedRepo = url
    }

    /// Re-reads the catalog (off the main actor) and keeps the selected flow, or selects the first entry. Repos
    /// added by path but not yet known to the client are scanned too.
    public func refreshCatalog() async {
        let client = client
        let added = addedRepos
        let found = await Task.detached { () -> [FlowEntry] in
            var entries = client.flowCatalog()
            let known = Set(client.knownRepos())
            let extra = added.filter { !known.contains($0) }
            if !extra.isEmpty {
                let have = Set(entries.map(\.id))
                entries += FlowCatalog.entries(library: client.libraryDirectory, repos: extra).filter { !have.contains($0.id) }
            }
            return entries
        }.value
        catalog = found
        if let id = launchForm.flow, found.contains(where: { $0.id == id }) {
            await loadLaunchFields()
        } else {
            await selectFlow(found.first?.id)
        }
    }

    /// The catalog entry the launch form has selected.
    public var selectedEntry: FlowEntry? { catalog.first { $0.id == launchForm.flow } }

    /// Selects a catalog entry: clears the typed values and fills in the fields' defaults.
    public func selectFlow(_ id: FlowEntry.ID?) async {
        launchForm.flow = id
        launchForm.values = [:]
        launchFields = []
        launchError = nil
        launchResolvedRepo = nil
        launchFlow = nil
        await loadLaunchFields()
    }

    /// Loads the selected flow to derive its launch fields. Typed values are kept for fields that remain; new
    /// fields get their defaults, and the repo field the default repo when it is a known one.
    /// The file is read off the main actor; a result for a selection that has since changed is dropped, and
    /// Launch is disabled until it arrives.
    func loadLaunchFields() async {
        launchGeneration += 1
        let generation = launchGeneration
        launchFields = []
        launchError = nil
        launchResolvedRepo = nil
        launchFlow = nil
        guard let entry = selectedEntry else { isLoadingLaunch = false; return }
        isLoadingLaunch = true
        let client = client
        let loaded = await Task.detached { () -> Result<Flow, Error> in
            Result { try entry.file.map { try client.loadFlow($0) } ?? BuiltinFlows.fixGitHubIssue }
        }.value
        guard generation == launchGeneration else { return }
        isLoadingLaunch = false
        let flow: Flow
        switch loaded {
        case .success(let f): flow = f
        case .failure(let error):
            launchError = error.localizedDescription
            return
        }
        launchFlow = flow
        do { launchFields = try flow.launchFields(location: entry.location) } catch {
            launchError = flow.message(for: error)
            return
        }
        let names = Set(launchFields.map(\.name))
        launchForm.values = launchForm.values.filter { names.contains($0.key) }
        for field in launchFields where launchForm.values[field.name] == nil {
            switch field.kind {
            case .text, .githubIssue: launchForm.values[field.name] = field.defaultValue ?? ""
            case .repo:
                if let def = field.defaultValue {
                    if let known = repos.first(where: { $0.standardizedFileURL.path == def }) { launchForm.values["repo"] = known.path }
                } else if let selectedRepo {
                    launchForm.values["repo"] = selectedRepo.path
                }
            }
        }
        for node in flow.nodes {
            guard case .repo(let config) = node.kind else { continue }
            switch (config.mode, entry.location) {
            case (.thisRepo, .repo(let root, _)): launchResolvedRepo = root.lastPathComponent
            case (.fixed(let path), _): launchResolvedRepo = URL(fileURLWithPath: path).lastPathComponent
            default: break
            }
        }
    }

    /// Whether the launch bar has a launchable flow and every required field is filled (trimmed).
    public var canLaunch: Bool {
        !isLaunching && !isLoadingLaunch && selectedEntry != nil && launchError == nil
            && launchFields.allSatisfy { !$0.isRequired || !Self.trimmed(launchForm.values[$0.name] ?? "").isEmpty }
    }

    /// Adds the repo at `path` if it is a git repo top level, and makes it the default for new drafts. Otherwise sets a notice.
    @discardableResult
    public func addRepo(path: String) async -> Bool {
        let trimmed = Self.trimmed(path)
        guard !trimmed.isEmpty else { return false }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
        guard await client.isGitRepo(url) else {
            notice = Notice("\(url.path) is not the top level of a git repository.")
            return false
        }
        if !addedRepos.contains(url) { addedRepos.append(url) }
        await refreshRepos()
        selectRepo(url)
        return true
    }

    /// Launches the selected flow with the typed values, then resets the fields whose text was not changed meanwhile.
    @discardableResult
    public func launchFromForm() async -> RunID? {
        guard canLaunch, let entry = selectedEntry, let flow = launchFlow else { return nil }
        let typed = launchForm.values
        let id = await launchGuarded(flow: flow, location: entry.location, values: typed)
        if id != nil {
            for field in launchFields where field.kind != .repo && launchForm.values[field.name] == typed[field.name] {
                launchForm.values[field.name] = field.defaultValue ?? ""
            }
        }
        return id
    }

    /// The one launch path: marks the launch in flight and sends the trimmed, non-empty values.
    func launchGuarded(flow: Flow, location: FlowLocation, values: [String: String]) async -> RunID? {
        isLaunching = true
        defer { isLaunching = false }
        var sent: [String: String] = [:]
        for (name, value) in values where !Self.trimmed(value).isEmpty { sent[name] = Self.trimmed(value) }
        return await launch(flow: flow, location: location, values: sent)
    }
}
