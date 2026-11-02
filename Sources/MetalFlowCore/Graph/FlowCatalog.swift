import Foundation

extension RunStore {
    /// Where library flows live: `<root>/flows`.
    public var flowsDirectory: URL { root.appendingPathComponent("flows", isDirectory: true) }
}

/// One flow the app can open: a built-in, a library file, or a repo's `.flows` file.
public struct FlowEntry: Hashable, Sendable, Identifiable {
    /// The file path, or `builtin:<name>`.
    public var id: String
    /// The flow's name (read from the file), or the file stem if it can't be read.
    public var name: String
    public var location: FlowLocation
    /// Nil for built-ins.
    public var file: URL?

    public init(id: String, name: String, location: FlowLocation, file: URL?) {
        self.id = id
        self.name = name
        self.location = location
        self.file = file
    }
}

/// Discovery of flows and normalisation of a flow when it is saved.
public enum FlowCatalog {
    /// Built-ins, then library flows (sorted by file name), then each repo's `.flows` (repos in the given order).
    /// Reads the file system, so call it off the main actor.
    public static func entries(library: URL, repos: [URL]) -> [FlowEntry] {
        var out = BuiltinFlows.all.map { FlowEntry(id: "builtin:\($0.name)", name: $0.name, location: .builtin, file: nil) }
        for file in flowFiles(in: library) {
            out.append(entry(file, location: .library(file: file)))
        }
        for repo in repos {
            for file in RunEngine.flows(in: repo) {
                out.append(entry(file, location: .of(file: file)))
            }
        }
        return out
    }

    /// Prepares `flow` for saving at `destination`, returning the flow to write and an optional notice.
    /// Library: `.thisRepo` becomes `.exposed(default: origin?.path)`.
    /// Repo: `.exposed(default: nil)` becomes `.thisRepo`. Every other mode is unchanged.
    /// Input bindings whose placeholder is gone are dropped.
    public static func prepareForSave(_ flow: Flow, destination: FlowLocation, origin: URL?) -> (Flow, String?) {
        var out = flow.droppingOrphanBindings()
        var notice: String?
        for i in out.nodes.indices {
            guard case .repo(var config) = out.nodes[i].kind else { continue }
            switch (destination, config.mode) {
            case (.library, .thisRepo):
                config.mode = .exposed(default: origin?.path)
                notice = "Saved to the library: the repo is now asked at launch (\(defaultDetail(origin)))."
            case (.repo, .exposed(let d)) where d == nil:
                config.mode = .thisRepo
            default:
                continue
            }
            out.nodes[i].kind = .repo(config)
        }
        return (out, notice)
    }

    /// Prepares `flow` for a "Copy to..." at `destination`, like `prepareForSave` but a repo copy is made for that
    /// repo: every Repo node becomes `.thisRepo`, whatever its mode. A library copy follows `prepareForSave`'s rule
    /// (`.thisRepo` becomes `.exposed(default: origin?.path)`); `origin` is the repo the flow came from.
    /// The notice describes only the change, since the copy reports where it went.
    public static func prepareForCopy(_ flow: Flow, destination: FlowLocation, origin: URL?) -> (Flow, String?) {
        var (out, notice) = prepareForSave(flow, destination: destination, origin: origin)
        guard case .repo = destination else {
            return (out, notice.map { _ in "The repo is now asked at launch (\(defaultDetail(origin)))." })
        }
        for i in out.nodes.indices {
            guard case .repo(var config) = out.nodes[i].kind, config.mode != .thisRepo else { continue }
            config.mode = .thisRepo
            out.nodes[i].kind = .repo(config)
        }
        return (out, notice)
    }

    /// "defaults to <repo>" for the exposed Repo field, or "no default" without an origin.
    private static func defaultDetail(_ origin: URL?) -> String {
        origin.map { "defaults to \($0.lastPathComponent)" } ?? "no default"
    }

    /// The file to write a new flow named `name` into `directory`: `<slug>.flow`, or `-2`, `-3`... when taken.
    /// Never overwrites.
    public static func newFileURL(name: String, in directory: URL) -> URL {
        let base = slug(name)
        var candidate = directory.appendingPathComponent("\(base).flow")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(n).flow")
            n += 1
        }
        return candidate
    }

    /// Lowercase letters and digits joined by dashes; `flow` when nothing is left.
    public static func slug(_ name: String) -> String {
        var out = ""
        var dash = false
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                if dash, !out.isEmpty { out.append("-") }
                out.append(ch)
                dash = false
            } else {
                dash = true
            }
        }
        return out.isEmpty ? "flow" : out
    }

    private static func flowFiles(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "flow" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func entry(_ file: URL, location: FlowLocation) -> FlowEntry {
        let name = (try? FlowFile.load(from: file).name) ?? file.deletingPathExtension().lastPathComponent
        return FlowEntry(id: file.path, name: name, location: location, file: file)
    }
}
