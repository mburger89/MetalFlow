import Foundation
import MetalFlowCore

/// What a pick of one lane showed on its card.
public enum PickOutcome: Equatable, Sendable {
    /// The lane was merged.
    case merged
    /// The user's checkout has uncommitted changes, so nothing was merged.
    case blockedDirty(URL)
    /// The merge conflicted in these files and nothing was merged.
    case conflict([String])
    /// The flow opens a pull request: nothing was merged, and the run is pushing the branch.
    case openingPullRequest
    /// The pick threw; the error's description.
    case failed(String)

    /// The line shown on the card.
    public var message: String {
        switch self {
        case .merged: "Merged"
        case .blockedDirty(let url):
            "Your checkout at \(url.path) has uncommitted changes — commit or stash, then pick again."
        case .conflict(let files): "Conflicts in: \(files.joined(separator: ", ")) — nothing was merged."
        case .openingPullRequest: "Opening pull request\u{2026}"
        case .failed(let text): text
        }
    }
}

/// Identifies one lane's diff.
public struct DiffKey: Hashable, Sendable {
    /// The run.
    public var run: RunID
    /// The lane.
    public var lane: LaneID
    /// Creates a key.
    public init(run: RunID, lane: LaneID) { self.run = run; self.lane = lane }
}

extension AppModel {
    /// The key of a per-lane draft or flag.
    public static func laneKey(_ run: RunID, _ lane: LaneID) -> String { "\(run.rawValue)#\(lane)" }

    /// Whether the run waits for a winner, so the pick buttons work.
    public func canPick(_ run: Run) -> Bool {
        run.nodes.values.contains { if case .needsYou(.pickWinner) = $0.state { true } else { false } }
    }

    /// Opens the run's pull request in the browser. Does nothing for a run that has none.
    public func openPullRequest(_ run: RunID) {
        guard case .prOpened(_, let url)? = runs[run]?.status, let target = URL(string: url) else { return }
        openURL(target)
    }

    /// Opens the lane's diff (loading it), or closes it if it is the open one. One diff is open at a time.
    /// A cached diff is reused only while the run is unchanged; a load already in flight is not repeated.
    public func toggleDiff(_ run: RunID, lane: LaneID) async {
        let key = DiffKey(run: run, lane: lane)
        if openDiff == key { openDiff = nil; return }
        openDiff = key
        let revision = runs[run]?.revision ?? 0
        if diffChunks[key] != nil, diffRevisions[key] == revision { return }
        guard !diffInFlight.contains(key) else { return }
        diffChunks[key] = nil
        await loadDiff(key)
    }

    /// Loads a lane's diff and caches it under the run's revision at the time. The old chunks stay until the new text
    /// arrives. Does nothing but ask for one more pass when a load is already in flight; the running load repeats once.
    /// Caches the result even if the diff was closed meanwhile; opens nothing.
    func loadDiff(_ key: DiffKey) async {
        guard !diffInFlight.contains(key) else { diffReloadWanted.insert(key); return }
        diffInFlight.insert(key)
        defer { diffInFlight.remove(key) }
        repeat {
            diffReloadWanted.remove(key)
            let revision = runs[key.run]?.revision ?? 0
            let text = await client.diff(key.run, lane: key.lane)
            diffChunks[key] = diffAttributed(text)
            diffRevisions[key] = revision
        } while diffReloadWanted.contains(key)
    }

    /// Reloads the open diff in place when it belongs to `run` and its cached text is older than the run.
    func reloadOpenDiff(of run: Run) {
        guard let key = openDiff, key.run == run.id else { return }
        if let cached = diffRevisions[key], run.revision <= cached { return }
        if diffInFlight.contains(key) { diffReloadWanted.insert(key); return }
        Task { await loadDiff(key) }
    }

    /// Forgets the cached diffs of a run that changed, except the one on screen (it is reloaded in place by `reloadOpenDiff(of:)`).
    func dropStaleDiffs(of run: RunID) {
        for key in diffChunks.keys where key.run == run && key != openDiff {
            diffChunks[key] = nil
            diffRevisions[key] = nil
        }
    }

    /// Whether the branch-name field of a lane is open.
    public func isBranchOpen(_ run: RunID, _ lane: LaneID) -> Bool { branchOpen.contains(Self.laneKey(run, lane)) }

    /// Opens or closes the lane's branch-name field.
    public func toggleBranch(_ run: RunID, _ lane: LaneID) {
        let key = Self.laneKey(run, lane)
        if branchOpen.contains(key) { branchOpen.remove(key) } else { branchOpen.insert(key) }
    }

    /// Keeps the lane's branch under the drafted name. Does nothing for an empty name.
    public func submitBranch(_ run: RunID, lane: LaneID) async {
        let key = Self.laneKey(run, lane)
        let name = Self.trimmed(branchDrafts[key] ?? "")
        guard !name.isEmpty else { return }
        if await branchFromHere(run, lane: lane, name: name) {
            branchDrafts[key] = nil
            branchOpen.remove(key)
        }
    }
}
