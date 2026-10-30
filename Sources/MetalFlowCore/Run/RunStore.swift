import Foundation

/// Persists runs (`runs/<id>.json`) and known repositories (`repos.json`) under a root directory.
public struct RunStore: Sendable {
    /// Storage root.
    public let root: URL

    /// Creates a store rooted at `root`.
    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/MetalFlow`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetalFlow")
    }

    /// Where run and candidate worktrees live.
    public var worktreesDirectory: URL { root.appendingPathComponent("worktrees") }

    private var runsDirectory: URL { root.appendingPathComponent("runs") }
    private var reposFile: URL { root.appendingPathComponent("repos.json") }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Self.dateString(date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let str = try dec.singleValueContainer().decode(String.self)
            guard let date = Self.parseDate(str) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(str)"))
            }
            return date
        }
        return d
    }

    private static func dateString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private func file(for id: RunID) -> URL {
        runsDirectory.appendingPathComponent("\(id.rawValue).json")
    }

    /// Writes the run atomically, creating `runs/` as needed.
    public func save(_ run: Run) throws {
        try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(run)
        try data.write(to: file(for: run.id), options: .atomic)
    }

    /// Loads all runs, newest first. Undecodable files are skipped. Running nodes become
    /// interrupted and a running run becomes needs-you; files are not rewritten.
    public func loadAll() throws -> [Run] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runsDirectory.path) else { return [] }
        let urls = try fm.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)
        let decoder = Self.decoder()
        var runs: [Run] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var run = try? decoder.decode(Run.self, from: data) else { continue }
            for (key, node) in run.nodes where node.state == .running {
                run.nodes[key]?.state = .interrupted
            }
            if run.status == .running { run.status = .needsYou }
            runs.append(run)
        }
        return runs.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.rawValue < $1.id.rawValue
        }
    }

    /// Deletes the run's file; a missing file is not an error.
    public func delete(_ id: RunID) throws {
        let url = file(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Known repositories in insertion order.
    public func knownRepos() -> [URL] {
        guard let data = try? Data(contentsOf: reposFile),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Adds a repository unless one with the same resolved path is already known.
    public func addKnownRepo(_ url: URL) throws {
        let normalized = Self.normalize(url)
        var paths = knownRepos().map(Self.normalize)
        guard !paths.contains(normalized) else { return }
        paths.append(normalized)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try Self.encoder().encode(paths)
        try data.write(to: reposFile, options: .atomic)
    }

    private static func normalize(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
