import Foundation

/// User settings kept in `settings.json` beside the runs.
public struct RunSettings: Codable, Equatable, Sendable {
    /// How many agent sessions run at once, within `sessionRange`.
    public var maxSessions: Int

    /// The limit when nothing is saved.
    public static let defaultMaxSessions = 4
    /// The limits a saved value is held to.
    public static let sessionRange = 1...16

    /// Creates settings; `maxSessions` is held to `sessionRange`.
    public init(maxSessions: Int = RunSettings.defaultMaxSessions) {
        self.maxSessions = Self.clamped(maxSessions)
    }

    /// Reads settings; a missing `maxSessions` is the default and any value is held to `sessionRange`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maxSessions: try c.decodeIfPresent(Int.self, forKey: .maxSessions) ?? Self.defaultMaxSessions)
    }

    static func clamped(_ n: Int) -> Int {
        min(max(n, sessionRange.lowerBound), sessionRange.upperBound)
    }
}
