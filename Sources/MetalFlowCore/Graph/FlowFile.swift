import Foundation

/// Reading and writing flow files (`.flows/<name>.flow`).
public enum FlowFile {
    /// Directory (relative to a repo root) that holds flow files.
    public static let directoryName = ".flows"
    /// Current on-disk format version.
    static let currentVersion = 1

    private struct Wrapper: Codable {
        var formatVersion: Int
        var flow: Flow
    }

    private struct VersionOnly: Decodable { var formatVersion: Int }

    /// Errors thrown when loading a flow file.
    public enum LoadError: Error, Equatable {
        /// The file declares a `formatVersion` this build does not understand.
        case unsupportedFormatVersion(Int)
    }

    /// Loads a flow from `url`; throws `LoadError.unsupportedFormatVersion` for unknown versions.
    public static func load(from url: URL) throws -> Flow {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let version = try decoder.decode(VersionOnly.self, from: data).formatVersion
        guard version == currentVersion else { throw LoadError.unsupportedFormatVersion(version) }
        return try decoder.decode(Wrapper.self, from: data).flow
    }

    /// Saves `flow` to `url` as pretty-printed JSON with sorted keys, creating parent directories.
    public static func save(_ flow: Flow, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Wrapper(formatVersion: currentVersion, flow: flow))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension FlowFile.LoadError: LocalizedError {
    /// A readable message.
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let v): return "unsupported flow file format version \(v)"
        }
    }
}
