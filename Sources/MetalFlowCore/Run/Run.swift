import Foundation

/// Unique identifier of a run (a UUID string).
public struct RunID: RawRepresentable, Codable, Hashable, Sendable {
    /// The underlying string.
    public var rawValue: String
    /// Creates an ID from its string form.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Creates a fresh random ID.
    public init() { self.rawValue = UUID().uuidString }
    /// Decodes from a single string value.
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    /// Encodes as a single string value.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Identifier of a fan-out lane ("a", "b", ...).
public typealias LaneID = String

/// Identifies one node execution: a node, optionally within a lane.
public struct NodeKey: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The node this key refers to.
    public var node: NodeID
    /// The lane within a fan-out, if the node is lane-scoped.
    public var lane: LaneID?
    /// Creates a key.
    public init(node: NodeID, lane: LaneID? = nil) { self.node = node; self.lane = lane }
    /// `"plan"` or `"implement@b"`.
    public var description: String {
        if let lane { return "\(node.rawValue)@\(lane)" }
        return node.rawValue
    }
    /// Parses the `description` form, splitting on the last `@`.
    public init?(description: String) {
        if let at = description.lastIndex(of: "@") {
            let node = String(description[..<at])
            let lane = String(description[description.index(after: at)...])
            guard !lane.isEmpty, NodeID(rawValue: node).isValidIdentifier else { return nil }
            self.init(node: NodeID(rawValue: node), lane: lane)
        } else {
            guard NodeID(rawValue: description).isValidIdentifier else { return nil }
            self.init(node: NodeID(rawValue: description), lane: nil)
        }
    }
}

/// Why a node is waiting for the user.
public enum NeedsYou: Codable, Hashable, Sendable {
    /// The agent asked a question.
    case question(String)
    /// Tools the agent was denied. No longer produced (a denial no longer blocks a session that finished);
    /// kept so runs saved earlier still decode and `answer(allowTools:)` still works on them.
    case deniedTools([String])
    /// A winner must be picked among lanes.
    case pickWinner(recommended: LaneID?, allGatesFailed: Bool)
}

/// Execution state of a node.
public enum NodeState: Codable, Hashable, Sendable {
    /// Not started.
    case waiting
    /// In progress.
    case running
    /// Finished successfully.
    case succeeded
    /// Finished with an error message.
    case failed(String)
    /// Blocked on the user.
    case needsYou(NeedsYou)
    /// Was running when the app stopped.
    case interrupted
    /// Cancelled by the user.
    case cancelled

    /// True for `.failed`, whatever the message.
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Runtime record of one node execution.
public struct NodeRun: Codable, Hashable, Sendable {
    /// Maximum number of retained log lines.
    public static let maxLogLines = 50
    /// Current execution state.
    public var state: NodeState
    /// Text output once finished.
    public var output: String?
    /// Agent session ID for resuming.
    public var sessionID: String?
    /// The last 50 log lines.
    public var log: [String]
    /// A user reply waiting to be sent to the agent.
    public var pendingReply: String?
    /// Tools the user approved beyond the node config.
    public var extraAllowedTools: [String]
    /// Accumulated cost in US dollars.
    public var costUSD: Double
    /// When execution started.
    public var startedAt: Date?
    /// When execution ended.
    public var endedAt: Date?
    /// For a gate: how many times it sent its agent back to fix a failure.
    public var fixAttemptsUsed: Int
    /// Set while the agent works on a failing gate's behalf: the fix its next turn carries out. It labels that turn's commit.
    public var pendingFix: PendingFix?
    /// The reply the current turn is carrying: moved here from `pendingReply` when the turn starts, back if the turn fails,
    /// dropped when it finishes. A retry after a failure then still resumes the session with it.
    public var replyInFlight: String?
    /// Set while a Judge works on a follow-up: what the verdict was and what was asked, so a reply that carries no
    /// `RECOMMEND:` line is shown beside the verdict instead of replacing it. Cleared when the turn finishes.
    public var followUpBase: FollowUpBase?
    /// Creates a node run with defaults (waiting, empty log).
    public init(
        state: NodeState = .waiting, output: String? = nil, sessionID: String? = nil,
        log: [String] = [], pendingReply: String? = nil, extraAllowedTools: [String] = [],
        costUSD: Double = 0, startedAt: Date? = nil, endedAt: Date? = nil, fixAttemptsUsed: Int = 0,
        pendingFix: PendingFix? = nil
    ) {
        self.pendingFix = pendingFix
        self.fixAttemptsUsed = fixAttemptsUsed
        self.state = state
        self.output = output
        self.sessionID = sessionID
        self.log = Array(log.suffix(Self.maxLogLines))
        self.pendingReply = pendingReply
        self.extraAllowedTools = extraAllowedTools
        self.costUSD = costUSD
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case state, output, sessionID, log, pendingReply, extraAllowedTools, costUSD, startedAt, endedAt, fixAttemptsUsed, pendingFix
        case replyInFlight, followUpBase
    }

    /// Decodes a node run; runs saved before fix attempts existed have no `fixAttemptsUsed` and mean 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(NodeState.self, forKey: .state)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        log = try c.decode([String].self, forKey: .log)
        pendingReply = try c.decodeIfPresent(String.self, forKey: .pendingReply)
        extraAllowedTools = try c.decode([String].self, forKey: .extraAllowedTools)
        costUSD = try c.decode(Double.self, forKey: .costUSD)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        fixAttemptsUsed = try c.decodeIfPresent(Int.self, forKey: .fixAttemptsUsed) ?? 0
        pendingFix = try c.decodeIfPresent(PendingFix.self, forKey: .pendingFix)
        replyInFlight = try c.decodeIfPresent(String.self, forKey: .replyInFlight)
        followUpBase = try c.decodeIfPresent(FollowUpBase.self, forKey: .followUpBase)
    }

    /// Appends a log line, keeping only the last 50.
    public mutating func appendLog(_ line: String) {
        log.append(line)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }
}

/// What a Judge said before it was asked a follow-up question.
public struct FollowUpBase: Codable, Hashable, Sendable {
    /// The Judge's output before the follow-up.
    public var previousOutput: String
    /// The message the user sent.
    public var message: String
    /// Creates a base.
    public init(previousOutput: String, message: String) {
        self.previousOutput = previousOutput
        self.message = message
    }
}

/// A fix attempt an agent is about to carry out for a failing gate or a review that asked for changes.
public struct PendingFix: Codable, Hashable, Sendable {
    /// Which attempt this is, counting from 1.
    public var attempt: Int
    /// How many attempts the gate or review allows.
    public var total: Int
    /// The gate's command, or the review's title.
    public var command: String
    /// What asked for the fix: "Gate" or "Review". It heads the line in the commit message that names `command`.
    public var label: String
    /// Creates a pending fix.
    public init(attempt: Int, total: Int, command: String, label: String = "Gate") {
        self.attempt = attempt
        self.total = total
        self.command = command
        self.label = label
    }

    private enum CodingKeys: String, CodingKey { case attempt, total, command, label }

    /// Decodes a pending fix; one saved before reviews existed has no `label` and came from a gate.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attempt = try c.decode(Int.self, forKey: .attempt)
        total = try c.decode(Int.self, forKey: .total)
        command = try c.decode(String.self, forKey: .command)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Gate"
    }
}

/// One candidate lane of a fan-out.
public struct Lane: Codable, Hashable, Sendable {
    /// Unique identifier.
    public var id: LaneID
    /// Model used by this lane.
    public var model: String
    /// Git branch.
    public var branch: String
    /// Worktree directory.
    public var worktree: URL
    /// Whether the gate passed; nil if not yet run.
    public var gatePassed: Bool?
    /// Whether the review found nothing left to fix; nil if there is no review or it has not finished.
    public var reviewPassed: Bool?
    /// Lines added.
    public var added: Int
    /// Lines removed.
    public var removed: Int
    /// Creates a lane.
    public init(id: LaneID, model: String, branch: String, worktree: URL,
                gatePassed: Bool? = nil, reviewPassed: Bool? = nil, added: Int = 0, removed: Int = 0) {
        self.id = id
        self.model = model
        self.branch = branch
        self.worktree = worktree
        self.gatePassed = gatePassed
        self.reviewPassed = reviewPassed
        self.added = added
        self.removed = removed
    }
}

/// Overall status of a run.
public enum RunStatus: Codable, Hashable, Sendable {
    /// Executing.
    case running
    /// Waiting for the user.
    case needsYou
    /// A lane was merged.
    case merged(LaneID)
    /// Discarded by the user.
    case discarded
    /// Failed with a message.
    case failed(String)
    /// Cancelled by the user.
    case cancelled
    /// The chosen candidate's branch was pushed and a pull request opened at `url`.
    case prOpened(LaneID, url: String)
    /// Every node finished successfully and no step is left for the user.
    case completed
}

/// One launch of a flow.
public struct Run: Identifiable, Codable, Equatable, Sendable {
    /// Unique identifier.
    public var id: RunID
    /// The flow being run.
    public var flow: Flow
    /// Display title.
    public var title: String
    /// The user repository.
    public var repo: URL
    /// Branch the run started from.
    public var baseBranch: String
    /// Git branch.
    public var branch: String
    /// Worktree directory.
    public var worktree: URL
    /// The flow file the run was launched from; nil for the built-in or an unsaved flow, and for runs saved before this existed.
    public var flowFile: URL?
    /// Flow input values by name.
    public var inputs: [String: String]
    /// Creation time.
    public var createdAt: Date
    /// Overall status.
    public var status: RunStatus
    /// Per-node runtime records.
    public var nodes: [NodeKey: NodeRun]
    /// Fan-out lanes.
    public var lanes: [Lane]
    /// Lane recommended by the judge.
    public var recommendation: LaneID?
    /// The candidate the user picked, when the flow opens a pull request instead of merging; nil until then.
    public var pickedLane: LaneID?
    /// Branches created with "branch from here"; cleanup never deletes them.
    public var keptBranches: [String]
    /// Monotonic counter the engine increments on every save, so consumers can order snapshots.
    public var revision: Int
    /// True once a follow-up was sent: cancelling the run then suspends it (it stays resumable) instead of cancelling.
    public var followedUp: Bool = false
    /// The step a follow-up is working on while the pick waited for the user; if it fails, the pick is offered again.
    public var pickToRestore: NodeKey?

    /// Creates a run.
    public init(
        id: RunID = RunID(), flow: Flow, title: String, repo: URL, baseBranch: String,
        branch: String, worktree: URL, inputs: [String: String] = [:], createdAt: Date = Date(),
        status: RunStatus = .running, nodes: [NodeKey: NodeRun] = [:], lanes: [Lane] = [],
        recommendation: LaneID? = nil, keptBranches: [String] = [], revision: Int = 0, flowFile: URL? = nil,
        pickedLane: LaneID? = nil
    ) {
        self.id = id
        self.flow = flow
        self.title = title
        self.repo = repo
        self.baseBranch = baseBranch
        self.branch = branch
        self.worktree = worktree
        self.flowFile = flowFile
        self.inputs = inputs
        self.createdAt = createdAt
        self.status = status
        self.nodes = nodes
        self.lanes = lanes
        self.recommendation = recommendation
        self.keptBranches = keptBranches
        self.revision = revision
        self.pickedLane = pickedLane
    }

    /// The run as it should appear when nothing is driving it: running nodes become interrupted and a running
    /// run becomes needs-you.
    public func markingCutShort() -> Run {
        var run = self
        for (key, node) in run.nodes where node.state == .running { run.nodes[key]?.state = .interrupted }
        if run.status == .running { run.status = .needsYou }
        return run
    }

    /// The keys of `nodes` in plan order (index in `flow.nodes`), then by lane.
    public var orderedNodeKeys: [NodeKey] {
        let order = flow.nodes.map(\.id)
        return nodes.keys.sorted {
            let (i, j) = (order.firstIndex(of: $0.node) ?? Int.max, order.firstIndex(of: $1.node) ?? Int.max)
            return i != j ? i < j : ($0.lane ?? "") < ($1.lane ?? "")
        }
    }

    /// How far a gate has got with its fix attempts.
    public struct FixProgress: Equatable, Sendable {
        /// Attempts used so far.
        public var used: Int
        /// Attempts the gate allows.
        public var of: Int
        /// Creates a progress value.
        public init(used: Int, of: Int) {
            self.used = used
            self.of = of
        }
    }

    /// The fix attempts a gate or review has used, or nil for any other node or one that has used none.
    public func fixProgress(_ key: NodeKey) -> FixProgress? {
        let allowed: Int
        switch flow.node(key.node)?.kind {
        case .gate(let config)?: allowed = config.fixAttempts
        case .review(let config)?: allowed = config.fixAttempts
        default: return nil
        }
        guard let used = nodes[key]?.fixAttemptsUsed, used > 0 else { return nil }
        return FixProgress(used: used, of: allowed)
    }

    /// True when any node, in any lane, has failed.
    public var hasFailedNode: Bool { nodes.values.contains { $0.state.isFailed } }

    /// Nodes waiting on the user, ordered by index in `flow.nodes`, then lane.
    public var needsYou: [(NodeKey, NeedsYou)] {
        var result: [(NodeKey, NeedsYou)] = []
        for (key, run) in nodes {
            if case .needsYou(let n) = run.state { result.append((key, n)) }
        }
        func index(_ key: NodeKey) -> Int {
            flow.nodes.firstIndex { $0.id == key.node } ?? Int.max
        }
        return result.sorted {
            let (i, j) = (index($0.0), index($1.0))
            if i != j { return i < j }
            return ($0.0.lane ?? "") < ($1.0.lane ?? "")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, flow, title, repo, baseBranch, branch, worktree, inputs, createdAt
        case status, nodes, lanes, recommendation, keptBranches, revision, flowFile, pickedLane, followedUp, pickToRestore
    }

    /// Decodes a run; `nodes` is a JSON object keyed by `NodeKey.description`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(RunID.self, forKey: .id)
        flow = try c.decode(Flow.self, forKey: .flow)
        title = try c.decode(String.self, forKey: .title)
        repo = try c.decode(URL.self, forKey: .repo)
        baseBranch = try c.decode(String.self, forKey: .baseBranch)
        branch = try c.decode(String.self, forKey: .branch)
        worktree = try c.decode(URL.self, forKey: .worktree)
        inputs = try c.decode([String: String].self, forKey: .inputs)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        status = try c.decode(RunStatus.self, forKey: .status)
        lanes = try c.decode([Lane].self, forKey: .lanes)
        recommendation = try c.decodeIfPresent(LaneID.self, forKey: .recommendation)
        keptBranches = try c.decodeIfPresent([String].self, forKey: .keptBranches) ?? []
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        pickedLane = try c.decodeIfPresent(LaneID.self, forKey: .pickedLane)
        flowFile = try c.decodeIfPresent(URL.self, forKey: .flowFile)
        followedUp = try c.decodeIfPresent(Bool.self, forKey: .followedUp) ?? false
        pickToRestore = try c.decodeIfPresent(NodeKey.self, forKey: .pickToRestore)
        let raw = try c.decode([String: NodeRun].self, forKey: .nodes)
        var parsed: [NodeKey: NodeRun] = [:]
        for (k, v) in raw {
            guard let key = NodeKey(description: k) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nodes, in: c, debugDescription: "Invalid node key \(k)")
            }
            parsed[key] = v
        }
        nodes = parsed
    }

    /// Encodes a run; `nodes` becomes a JSON object keyed by `NodeKey.description`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(flow, forKey: .flow)
        try c.encode(title, forKey: .title)
        try c.encode(repo, forKey: .repo)
        try c.encode(baseBranch, forKey: .baseBranch)
        try c.encode(branch, forKey: .branch)
        try c.encode(worktree, forKey: .worktree)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(status, forKey: .status)
        try c.encode(lanes, forKey: .lanes)
        try c.encodeIfPresent(recommendation, forKey: .recommendation)
        try c.encode(keptBranches, forKey: .keptBranches)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(flowFile, forKey: .flowFile)
        try c.encodeIfPresent(pickedLane, forKey: .pickedLane)
        if followedUp { try c.encode(true, forKey: .followedUp) }
        try c.encodeIfPresent(pickToRestore, forKey: .pickToRestore)
        var raw: [String: NodeRun] = [:]
        for (k, v) in nodes { raw[k.description] = v }
        try c.encode(raw, forKey: .nodes)
    }
}
