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
    /// The pick threw; the error's description.
    case failed(String)

    /// The line shown on the card.
    public var message: String {
        switch self {
        case .merged: "Merged"
        case .blockedDirty(let url):
            "Your checkout at \(url.path) has uncommitted changes — commit or stash, then pick again."
        case .conflict(let files): "Conflicts in: \(files.joined(separator: ", ")) — nothing was merged."
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

    /// Opens the lane's diff (loading it), or closes it if it is the open one. One diff is open at a time.
    public func toggleDiff(_ run: RunID, lane: LaneID) async {
        let key = DiffKey(run: run, lane: lane)
        if openDiff == key { openDiff = nil; return }
        openDiff = key
        guard diffChunks[key] == nil else { return }
        let text = await client.diff(run, lane: lane)
        diffChunks[key] = diffAttributed(text)
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
