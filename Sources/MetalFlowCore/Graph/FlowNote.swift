import Foundation

/// Stable identifier of a note within a flow: `note1`, `note2`, ...
public struct NoteID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
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

/// A note on the canvas. A sticky (`surrounds` false) holds a body of text; a frame (`surrounds` true) has a title
/// and holds whichever nodes lie inside it. Notes are for people: validation, the plan and runs never read them.
public struct FlowNote: Codable, Hashable, Sendable {
    public var id: NoteID
    /// A sticky's body, or a frame's title.
    public var text: String
    /// The top-left corner, in canvas units.
    public var origin: Point
    public var width: Double
    public var height: Double
    /// Whether this is a frame around nodes rather than a sticky.
    public var surrounds: Bool

    /// Creates a note.
    public init(id: NoteID, text: String = "", origin: Point, width: Double, height: Double, surrounds: Bool) {
        self.id = id
        self.text = text
        self.origin = origin
        self.width = width
        self.height = height
        self.surrounds = surrounds
    }
}
