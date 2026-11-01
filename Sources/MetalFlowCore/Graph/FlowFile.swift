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
        let flow = try decoder.decode(Wrapper.self, from: data).flow
        return normalised(flow, inFlowsDirectory: url.deletingLastPathComponent().lastPathComponent == directoryName)
    }

    /// Makes legacy flows independent of a repo: outside a `.flows` folder `.thisRepo` becomes exposed,
    /// and a flow without a Repo node gets one.
    private static func normalised(_ input: Flow, inFlowsDirectory: Bool) -> Flow {
        var flow = input
        let fallback = RepoConfig(mode: inFlowsDirectory ? .thisRepo : .exposed(default: nil))
        if !inFlowsDirectory {
            for i in flow.nodes.indices {
                if case .repo(let c) = flow.nodes[i].kind, c.mode == .thisRepo { flow.nodes[i].kind = .repo(fallback) }
            }
        }
        if flow.repoNodes.isEmpty {
            let taken = Set(flow.nodes.map(\.id.rawValue))
            var id = "repo"
            var n = 2
            while taken.contains(id) { id = "repo\(n)"; n += 1 }
            let position = flow.nodes.isEmpty ? Point(x: 24, y: 24)
                : Point(x: flow.nodes.map(\.position.x).min()! - 240, y: flow.nodes.map(\.position.y).min()!)
            flow.nodes.append(Node(id: NodeID(rawValue: id), title: "Repo", kind: .repo(fallback), position: position))
        }
        return flow
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
