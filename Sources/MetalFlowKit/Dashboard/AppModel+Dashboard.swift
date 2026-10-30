import Foundation
import MetalFlowCore

/// What the launch bar has selected and typed.
public struct LaunchForm: Sendable, Equatable {
    /// The chosen repository.
    public var repo: URL?
    /// The chosen `.flow` file.
    public var flow: URL?
    /// The issue number or URL.
    public var issue = ""
    /// The "Add repo..." field's text.
    public var newRepoPath = ""
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
            let order = run.flow.nodes.map(\.id)
            let keys = run.nodes.keys.sorted {
                let (i, j) = (order.firstIndex(of: $0.node) ?? Int.max, order.firstIndex(of: $1.node) ?? Int.max)
                return i != j ? i < j : ($0.lane ?? "") < ($1.lane ?? "")
            }
            for key in keys {
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

    /// Re-reads the known repos, merges the added ones, and keeps the selection valid.
    public func refreshRepos() {
        var merged = client.knownRepos()
        for url in addedRepos where !merged.contains(url) { merged.append(url) }
        repos = merged
        if launchForm.repo == nil || !merged.contains(launchForm.repo!) { selectRepo(merged.first) }
    }

    /// Selects a repo and loads its flows, choosing the first.
    public func selectRepo(_ url: URL?) {
        launchForm.repo = url
        repoFlows = url.map { client.flows(in: $0) } ?? []
        if launchForm.flow == nil || !repoFlows.contains(launchForm.flow!) { launchForm.flow = repoFlows.first }
    }

    /// Selects a flow file.
    public func selectFlow(_ url: URL?) { launchForm.flow = url }

    /// Whether the launch bar has a repo, a flow and a non-empty issue.
    public var canLaunch: Bool {
        launchForm.repo != nil && launchForm.flow != nil
            && !launchForm.issue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Adds the repo at `path` if it is a git repo top level, and selects it. Otherwise sets a notice.
    @discardableResult
    public func addRepo(path: String) async -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
        guard await client.isGitRepo(url) else {
            notice = Notice("\(url.path) is not the top level of a git repository.")
            return false
        }
        if !addedRepos.contains(url) { addedRepos.append(url) }
        refreshRepos()
        selectRepo(url)
        launchForm.newRepoPath = ""
        return true
    }

    /// Launches the selected flow in the selected repo on the typed issue, then clears the issue field.
    @discardableResult
    public func launchFromForm() async -> RunID? {
        guard canLaunch, let repo = launchForm.repo, let file = launchForm.flow else { return nil }
        let issue = launchForm.issue.trimmingCharacters(in: .whitespacesAndNewlines)
        let flow: Flow
        do { flow = try client.loadFlow(file) } catch {
            notice = Notice(error.localizedDescription)
            return nil
        }
        let id = await launch(flow: flow, repo: repo, input: issue)
        if id != nil { launchForm.issue = "" }
        return id
    }
}
