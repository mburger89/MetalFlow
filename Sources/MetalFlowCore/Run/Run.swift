import Foundation

/// Unique identifier of a run (a UUID string).
public struct RunID: RawRepresentable, Codable, Hashable, Sendable {
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
    public var node: NodeID
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
        guard !description.isEmpty else { return nil }
        if let at = description.lastIndex(of: "@") {
            let node = String(description[..<at])
            let lane = String(description[description.index(after: at)...])
            guard !node.isEmpty, !lane.isEmpty else { return nil }
            self.init(node: NodeID(rawValue: node), lane: lane)
        } else {
            self.init(node: NodeID(rawValue: description), lane: nil)
        }
    }
}

/// Why a node is waiting for the user.
public enum NeedsYou: Codable, Hashable, Sendable {
    /// The agent asked a question.
    case question(String)
    /// Tools the agent was denied.
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
}

/// Runtime record of one node execution.
public struct NodeRun: Codable, Hashable, Sendable {
    /// Maximum number of retained log lines.
    public static let maxLogLines = 50
    public var state: NodeState
    public var output: String?
    public var sessionID: String?
    /// The last 50 log lines.
    public var log: [String]
    public var pendingReply: String?
    public var extraAllowedTools: [String]
    public var costUSD: Double
    public var startedAt: Date?
    public var endedAt: Date?
    /// Creates a node run with defaults (waiting, empty log).
    public init(
        state: NodeState = .waiting, output: String? = nil, sessionID: String? = nil,
        log: [String] = [], pendingReply: String? = nil, extraAllowedTools: [String] = [],
        costUSD: Double = 0, startedAt: Date? = nil, endedAt: Date? = nil
    ) {
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
    /// Appends a log line, keeping only the last 50.
    public mutating func appendLog(_ line: String) {
        log.append(line)
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }
}

/// One candidate lane of a fan-out.
public struct Lane: Codable, Hashable, Sendable {
    public var id: LaneID
    public var model: String
    public var branch: String
    public var worktree: URL
    public var gatePassed: Bool?
    public var added: Int
    public var removed: Int
    /// Creates a lane.
    public init(id: LaneID, model: String, branch: String, worktree: URL,
                gatePassed: Bool? = nil, added: Int = 0, removed: Int = 0) {
        self.id = id
        self.model = model
        self.branch = branch
        self.worktree = worktree
        self.gatePassed = gatePassed
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
}

/// One launch of a flow.
public struct Run: Identifiable, Codable, Equatable, Sendable {
    public var id: RunID
    public var flow: Flow
    public var title: String
    public var repo: URL
    public var baseBranch: String
    public var branch: String
    public var worktree: URL
    public var inputs: [String: String]
    public var createdAt: Date
    public var status: RunStatus
    public var nodes: [NodeKey: NodeRun]
    public var lanes: [Lane]
    public var recommendation: LaneID?

    /// Creates a run.
    public init(
        id: RunID = RunID(), flow: Flow, title: String, repo: URL, baseBranch: String,
        branch: String, worktree: URL, inputs: [String: String] = [:], createdAt: Date = Date(),
        status: RunStatus = .running, nodes: [NodeKey: NodeRun] = [:], lanes: [Lane] = [],
        recommendation: LaneID? = nil
    ) {
        self.id = id
        self.flow = flow
        self.title = title
        self.repo = repo
        self.baseBranch = baseBranch
        self.branch = branch
        self.worktree = worktree
        self.inputs = inputs
        self.createdAt = createdAt
        self.status = status
        self.nodes = nodes
        self.lanes = lanes
        self.recommendation = recommendation
    }

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
        case status, nodes, lanes, recommendation
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
        var raw: [String: NodeRun] = [:]
        for (k, v) in nodes { raw[k.description] = v }
        try c.encode(raw, forKey: .nodes)
    }

    /// Equality over all stored fields (needsYou is derived).
    public static func == (a: Run, b: Run) -> Bool {
        a.id == b.id && a.flow == b.flow && a.title == b.title && a.repo == b.repo
            && a.baseBranch == b.baseBranch && a.branch == b.branch && a.worktree == b.worktree
            && a.inputs == b.inputs && a.createdAt == b.createdAt && a.status == b.status
            && a.nodes == b.nodes && a.lanes == b.lanes && a.recommendation == b.recommendation
    }
}
