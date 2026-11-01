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
    /// Creates a shell configuration.
    public init(command: String) { self.command = command }
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

    private enum CodingKeys: String, CodingKey { case flowInput, repo, prompt, shell, gate, judge, pick }
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
    /// Creates a flow.
    public init(name: String, nodes: [Node], wires: [Wire]) {
        self.name = name
        self.nodes = nodes
        self.wires = wires
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

    /// Distinct placeholder names of a node's prompt or command, in order of first appearance. A judge's `candidates` is excluded.
    public func inputNames(of id: NodeID) -> [String] {
        guard let n = node(id) else { return [] }
        var texts: [String] = []
        var exempt: Set<String> = []
        switch n.kind {
        case .prompt(let c): texts = [c.prompt]
        case .judge(let c): texts = [c.prompt]; exempt = ["candidates"]
        case .shell(let c), .gate(let c): texts = [c.command]
        case .flowInput, .repo, .pick: break
        }
        var seen = Set<String>()
        return texts.flatMap { Template.placeholders(in: $0) }.filter { !exempt.contains($0) && seen.insert($0).inserted }
    }
    /// The Repo nodes of the flow.
    public var repoNodes: [Node] {
        nodes.filter { if case .repo = $0.kind { true } else { false } }
    }
}
