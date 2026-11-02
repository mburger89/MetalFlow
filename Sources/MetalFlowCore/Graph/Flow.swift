import Foundation

/// Stable identifier of a node within a flow.
public struct NodeID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    /// Creates an ID from its string form.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Creates an ID from a string literal.
    public init(stringLiteral value: String) { self.rawValue = value }
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

/// A position on the flow canvas.
public struct Point: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    /// Creates a point.
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Where a flow input's value comes from.
public enum InputSource: Codable, Hashable, Sendable {
    case githubIssue
    case text
}

/// Which repository a Repo node supplies.
public enum RepoMode: Codable, Hashable, Sendable {
    /// The repo the flow file lives in.
    case thisRepo
    /// A fixed repo path.
    case fixed(path: String)
    /// Chosen at launch, optionally with a default path.
    case exposed(default: String?)
}

/// Configuration of a Repo node.
public struct RepoConfig: Codable, Hashable, Sendable {
    public var mode: RepoMode
    /// Creates a repo configuration.
    public init(mode: RepoMode) { self.mode = mode }
}

/// Where a node input's value comes from when it is not wired.
public enum InputBinding: Codable, Hashable, Sendable {
    /// A literal value.
    case fixed(String)
    /// A launch field, optionally with a default.
    case exposed(default: String?)
}

/// Configuration of a `flowInput` node.
public struct FlowInputConfig: Codable, Hashable, Sendable {
    public var name: String
    public var source: InputSource
    public var binding: InputBinding
    /// Creates a flow input configuration.
    public init(name: String, source: InputSource, binding: InputBinding = .exposed(default: nil)) {
        self.name = name
        self.source = source
        self.binding = binding
    }
    private enum CodingKeys: String, CodingKey { case name, source, binding }
    /// Decodes, defaulting `binding` to an exposed field when absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(InputSource.self, forKey: .source)
        binding = try c.decodeIfPresent(InputBinding.self, forKey: .binding) ?? .exposed(default: nil)
    }
}

/// Configuration of a prompt or judge node.
public struct PromptConfig: Codable, Hashable, Sendable {
    /// Model used when `candidates` is empty.
    public var model: String
    public var prompt: String
    /// One model per lane; `count > 1` means fan-out, empty means a single run with `model`.
    public var candidates: [String]
    public var allowedTools: [String]
    public var maxTurns: Int?
    /// Creates a prompt configuration.
    public init(model: String, prompt: String, candidates: [String], allowedTools: [String], maxTurns: Int?) {
        self.model = model
        self.prompt = prompt
        self.candidates = candidates
        self.allowedTools = allowedTools
        self.maxTurns = maxTurns
    }
}

/// Configuration of a shell or gate node.
public struct ShellConfig: Codable, Hashable, Sendable {
    public var command: String
    /// How many times a failing gate may send the agent that wrote the code back to fix it before it gives up.
    /// Only gates use it; a shell node ignores it.
    public var fixAttempts: Int
    /// Creates a shell configuration.
    public init(command: String, fixAttempts: Int = 0) {
        self.command = command
        self.fixAttempts = fixAttempts
    }

    private enum CodingKeys: String, CodingKey { case command, fixAttempts }

    /// Decodes a configuration; files written before fix attempts existed have no `fixAttempts` and mean 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        fixAttempts = try c.decodeIfPresent(Int.self, forKey: .fixAttempts) ?? 0
    }

    /// Encodes the command, and `fixAttempts` only when it is set, so files without fix attempts stay as they were.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(command, forKey: .command)
        if fixAttempts != 0 { try c.encode(fixAttempts, forKey: .fixAttempts) }
    }
}

/// Configuration of an Open PR node.
public struct OpenPRConfig: Codable, Hashable, Sendable {
    /// Whether the pull request is opened as a draft.
    public var draft: Bool
    /// Creates a configuration; pull requests are drafts unless said otherwise.
    public init(draft: Bool = true) { self.draft = draft }

    private enum CodingKeys: String, CodingKey { case draft }

    /// Decodes a configuration; a missing `draft` means a draft.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? true
    }
}

/// Configuration of a Review node: an agent reads a candidate's diff and, when it finds problems, sends the
/// agent that wrote the code back to fix them.
public struct ReviewConfig: Codable, Hashable, Sendable {
    /// The reviewing agent; its `candidates` stay empty, and `{diff}` in its prompt is the candidate's diff.
    public var agent: PromptConfig
    /// How many times the review may send the writing agent back to fix what it found.
    public var fixAttempts: Int

    /// The agent a new Review node starts with.
    public static let defaultAgent = PromptConfig(
        model: "sonnet",
        prompt: "Review this change. Look for bugs, missing tests and anything that does not do what it should. Do not edit files. List only the problems worth fixing, each with its file and line.\n\n{diff}",
        candidates: [],
        allowedTools: ["Read", "Grep", "Glob", "Bash(git log:*)", "Bash(git diff:*)", "Bash(git show:*)", "Bash(git status:*)"],
        maxTurns: nil)

    /// Creates a configuration; a review gets one fix attempt unless said otherwise.
    public init(agent: PromptConfig = ReviewConfig.defaultAgent, fixAttempts: Int = 1) {
        self.agent = agent
        self.fixAttempts = fixAttempts
    }

    private enum CodingKeys: String, CodingKey { case agent, fixAttempts }

    /// Decodes a configuration; a missing `fixAttempts` means 1.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decode(PromptConfig.self, forKey: .agent)
        fixAttempts = try c.decodeIfPresent(Int.self, forKey: .fixAttempts) ?? 1
    }
}

/// What a node does.
public enum NodeKind: Codable, Hashable, Sendable {
    case flowInput(FlowInputConfig)
    case repo(RepoConfig)
    case prompt(PromptConfig)
    case shell(ShellConfig)
    case gate(ShellConfig)
    case judge(PromptConfig)
    case pick
    /// Pushes the picked candidate's branch and opens a GitHub pull request for it instead of merging locally.
    case openPR(OpenPRConfig)
    /// Has an agent review each candidate's diff and send the writing agent back to fix what it finds.
    case review(ReviewConfig)

    private enum CodingKeys: String, CodingKey { case flowInput, repo, prompt, shell, gate, judge, pick, openPR, review }
    private enum PayloadKey: String, CodingKey { case _0 }

    /// Decodes the synthesized shape; a `repo` without payload (written before Repo had config) means `.thisRepo`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.allKeys.first, c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expected exactly one node kind"))
        }
        func payload<T: Decodable>(_ type: T.Type) throws -> T {
            try c.nestedContainer(keyedBy: PayloadKey.self, forKey: key).decode(T.self, forKey: ._0)
        }
        switch key {
        case .flowInput: self = .flowInput(try payload(FlowInputConfig.self))
        case .repo:
            let n = try c.nestedContainer(keyedBy: PayloadKey.self, forKey: .repo)
            self = .repo(try n.decodeIfPresent(RepoConfig.self, forKey: ._0) ?? RepoConfig(mode: .thisRepo))
        case .prompt: self = .prompt(try payload(PromptConfig.self))
        case .shell: self = .shell(try payload(ShellConfig.self))
        case .gate: self = .gate(try payload(ShellConfig.self))
        case .judge: self = .judge(try payload(PromptConfig.self))
        case .pick: self = .pick
        case .openPR: self = .openPR(try payload(OpenPRConfig.self))
        case .review: self = .review(try payload(ReviewConfig.self))
        }
    }

    /// Encodes in Swift's synthesized enum shape (`{"case":{"_0":...}}`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put<T: Encodable>(_ key: CodingKeys, _ value: T) throws {
            var n = c.nestedContainer(keyedBy: PayloadKey.self, forKey: key)
            try n.encode(value, forKey: ._0)
        }
        switch self {
        case .flowInput(let v): try put(.flowInput, v)
        case .repo(let v): try put(.repo, v)
        case .prompt(let v): try put(.prompt, v)
        case .shell(let v): try put(.shell, v)
        case .gate(let v): try put(.gate, v)
        case .judge(let v): try put(.judge, v)
        case .pick: _ = c.nestedContainer(keyedBy: PayloadKey.self, forKey: .pick)
        case .openPR(let v): try put(.openPR, v)
        case .review(let v): try put(.review, v)
        }
    }
}

/// A node in a flow.
public struct Node: Codable, Hashable, Sendable {
    public var id: NodeID
    public var title: String
    public var kind: NodeKind
    public var position: Point
    /// Per-placeholder bindings for inputs that are not wired.
    public var inputs: [String: InputBinding]
    /// Creates a node.
    public init(id: NodeID, title: String, kind: NodeKind, position: Point, inputs: [String: InputBinding] = [:]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.position = position
        self.inputs = inputs
    }
    private enum CodingKeys: String, CodingKey { case id, title, kind, position, inputs }
    /// Decodes, defaulting `inputs` to empty when absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(NodeID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(NodeKind.self, forKey: .kind)
        position = try c.decode(Point.self, forKey: .position)
        inputs = try c.decodeIfPresent([String: InputBinding].self, forKey: .inputs) ?? [:]
    }
}

/// A connection carrying one node's output into a named placeholder of another.
public struct Wire: Codable, Hashable, Sendable {
    public var from: NodeID
    public var to: NodeID
    /// Placeholder name in the target node.
    public var input: String
    /// Creates a wire.
    public init(from: NodeID, to: NodeID, input: String) {
        self.from = from
        self.to = to
        self.input = input
    }
}

/// A directed acyclic graph of nodes.
public struct Flow: Codable, Hashable, Sendable {
    public var name: String
    public var nodes: [Node]
    public var wires: [Wire]
    /// Notes and frames on the canvas. Never read by validation, the plan or a run.
    public var notes: [FlowNote]
    /// Creates a flow.
    public init(name: String, nodes: [Node], wires: [Wire], notes: [FlowNote] = []) {
        self.name = name
        self.nodes = nodes
        self.wires = wires
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey { case name, nodes, wires, notes }

    /// Decodes a flow; files written before notes existed have no `notes` and mean none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        nodes = try c.decode([Node].self, forKey: .nodes)
        wires = try c.decode([Wire].self, forKey: .wires)
        notes = try c.decodeIfPresent([FlowNote].self, forKey: .notes) ?? []
    }

    /// Encodes the flow, and `notes` only when there are some, so files without notes stay as they were.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(wires, forKey: .wires)
        if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
    }
    /// The node with the given ID, if any.
    public func node(_ id: NodeID) -> Node? { nodes.first { $0.id == id } }
    /// Wires that feed the given node.
    public func inputs(of id: NodeID) -> [Wire] { wires.filter { $0.to == id } }

    /// The flow without bindings whose placeholder their node no longer has. Editing keeps these so retyping a
    /// placeholder restores its binding; everything that reads bindings ignores them, and saving drops them.
    public func droppingOrphanBindings() -> Flow {
        var out = self
        for i in out.nodes.indices where !out.nodes[i].inputs.isEmpty {
            let names = Set(inputNames(of: out.nodes[i].id))
            out.nodes[i].inputs = out.nodes[i].inputs.filter { names.contains($0.key) }
        }
        return out
    }

    /// Distinct placeholder names of a node's prompt or command, in order of first appearance. A judge's `candidates` and a review's `diff` are excluded.
    public func inputNames(of id: NodeID) -> [String] {
        guard let n = node(id) else { return [] }
        var texts: [String] = []
        var exempt: Set<String> = []
        switch n.kind {
        case .prompt(let c): texts = [c.prompt]
        case .judge(let c): texts = [c.prompt]; exempt = ["candidates"]
        case .shell(let c), .gate(let c): texts = [c.command]
        case .review(let c): texts = [c.agent.prompt]; exempt = ["diff"]
        case .flowInput, .repo, .pick, .openPR: break
        }
        var seen = Set<String>()
        return texts.flatMap { Template.placeholders(in: $0) }.filter { !exempt.contains($0) && seen.insert($0).inserted }
    }
    /// True when the flow has an Open PR node, so picking a candidate opens a pull request instead of merging.
    public var hasOpenPR: Bool {
        nodes.contains { if case .openPR = $0.kind { true } else { false } }
    }
    /// The Repo nodes of the flow.
    public var repoNodes: [Node] {
        nodes.filter { if case .repo = $0.kind { true } else { false } }
    }
}
