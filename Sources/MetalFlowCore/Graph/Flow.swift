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

/// Configuration of a `flowInput` node.
public struct FlowInputConfig: Codable, Hashable, Sendable {
    public var name: String
    public var source: InputSource
    /// Creates a flow input configuration.
    public init(name: String, source: InputSource) { self.name = name; self.source = source }
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
    case repo
    case prompt(PromptConfig)
    case shell(ShellConfig)
    case gate(ShellConfig)
    case judge(PromptConfig)
    case pick
}

/// A node in a flow.
public struct Node: Codable, Hashable, Sendable {
    public var id: NodeID
    public var title: String
    public var kind: NodeKind
    public var position: Point
    /// Creates a node.
    public init(id: NodeID, title: String, kind: NodeKind, position: Point) {
        self.id = id
        self.title = title
        self.kind = kind
        self.position = position
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
}
