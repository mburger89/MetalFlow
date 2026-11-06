import Foundation

/// A local session ID that could not be used as a file name.
public struct InvalidLocalSessionID: Error, Equatable, CustomStringConvertible {
    public let id: String
    public var description: String { "Invalid local session ID: \(id)" }
}

/// Stores the messages of local agent sessions as `<directory>/<sessionID>.json`.
public struct LocalTranscriptStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func file(for sessionID: String) throws -> URL {
        guard !sessionID.isEmpty, !sessionID.contains("/"), !sessionID.contains("\\"),
              !sessionID.contains(".."), !sessionID.contains("\0") else { throw InvalidLocalSessionID(id: sessionID) }
        return directory.appendingPathComponent(sessionID + ".json")
    }

    public func save(sessionID: String, messages: [ChatMessage]) throws {
        let url = try file(for: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(messages).write(to: url, options: .atomic)
    }

    /// The saved messages, or an empty array when the session has no transcript.
    public func load(sessionID: String) throws -> [ChatMessage] {
        let url = try file(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ChatMessage].self, from: Data(contentsOf: url))
    }
}
