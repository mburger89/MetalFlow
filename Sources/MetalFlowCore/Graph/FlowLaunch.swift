import Foundation

/// Where a flow file lives.
public enum FlowLocation: Hashable, Sendable {
    case builtin
    case unsaved
    case library(file: URL)
    case repo(root: URL, file: URL)

    /// `.repo` when the file's folder is named `.flows` (root = its parent), otherwise `.library`.
    public static func of(file: URL) -> FlowLocation {
        let dir = file.deletingLastPathComponent()
        if dir.lastPathComponent == ".flows" {
            return .repo(root: URL(fileURLWithPath: dir.deletingLastPathComponent().path, isDirectory: true), file: file)
        }
        return .library(file: file)
    }
}

/// One value asked for at launch.
public struct LaunchField: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case text, githubIssue, repo }
    /// The input name; `repo` for the repo field.
    public var name: String
    public var kind: Kind
    public var defaultValue: String?
    /// True when the launch cannot proceed without a value.
    public var isRequired: Bool { defaultValue == nil }

    public init(name: String, kind: Kind, defaultValue: String? = nil) {
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

/// Reasons a valid flow cannot be launched from where it is.
public enum LaunchError: Error, Equatable, Sendable {
    case invalid(FlowError)
    case noRepoNode, multipleRepoNodes
    case thisRepoOutsideRepo
    /// An exposed placeholder is named like a Flow input.
    case exposedShadowsFlowInput(NodeID, String)
    /// An exposed placeholder is named `repo`.
    case reservedName(NodeID)
    case conflictingDefaults(String)
}

extension LaunchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalid(let e): return e.errorDescription
        case .noRepoNode: return "A flow needs a Repo node"
        case .multipleRepoNodes: return "A flow can have only one Repo node"
        case .thisRepoOutsideRepo: return "This repo only works for a flow saved in a repo — choose Fixed or Exposed"
        case .exposedShadowsFlowInput(_, let name):
            return "{\(name)} is the name of a Flow input — wire it from that node instead"
        case .reservedName(let id): return "'\(id.rawValue)': {repo} is reserved for the Repo field — wire it from the Repo node instead"
        case .conflictingDefaults(let name): return "The exposed input {\(name)} has different defaults on different nodes"
        }
    }
}

extension Flow {
    /// A readable message for `error`, naming the Flow input node by title where it can.
    public func message(for error: LaunchError) -> String {
        switch error {
        case .invalid(let e): return message(for: e)
        case .exposedShadowsFlowInput(_, let name):
            let title = nodes.first { if case .flowInput(let c) = $0.kind { c.name == name } else { false } }?.title ?? name
            return "{\(name)} is the \(title) input's name — wire it from that node instead"
        default: return error.errorDescription ?? "\(error)"
        }
    }

    /// Runs validate(), then the launch rules. Returns one field per exposed name, in plan order: Flow inputs
    /// and exposed placeholders in the order their nodes appear in the plan, with the repo field last.
    public func launchFields(location: FlowLocation) throws(LaunchError) -> [LaunchField] {
        let plan: FlowPlan
        do { plan = try validate() } catch { throw .invalid(error) }

        let repos = repoNodes
        guard let repoNode = repos.first else { throw .noRepoNode }
        if repos.count > 1 { throw .multipleRepoNodes }
        var repoField: LaunchField?
        if case .repo(let cfg) = repoNode.kind {
            switch cfg.mode {
            case .thisRepo:
                if case .repo = location {} else { throw .thisRepoOutsideRepo }
            case .fixed: break
            case .exposed(let d): repoField = LaunchField(name: "repo", kind: .repo, defaultValue: d)
            }
        }

        var flowInputNames = Set<String>()
        for n in nodes { if case .flowInput(let c) = n.kind { flowInputNames.insert(c.name) } }

        var fields: [LaunchField] = []
        func add(_ f: LaunchField) throws(LaunchError) {
            if let i = fields.firstIndex(where: { $0.name == f.name }) {
                if fields[i].defaultValue != f.defaultValue { throw .conflictingDefaults(f.name) }
            } else {
                fields.append(f)
            }
        }
        for id in plan.order {
            guard let n = node(id) else { continue }
            if case .flowInput(let c) = n.kind {
                if case .exposed(let d) = c.binding {
                    try add(LaunchField(name: c.name, kind: c.source == .githubIssue ? .githubIssue : .text, defaultValue: d))
                }
                continue
            }
            for name in inputNames(of: id) {
                guard case .exposed(let d)? = n.inputs[name] else { continue }
                if name == "repo" { throw .reservedName(id) }
                if flowInputNames.contains(name) { throw .exposedShadowsFlowInput(id, name) }
                try add(LaunchField(name: name, kind: .text, defaultValue: d))
            }
        }
        if let repoField { fields.append(repoField) }
        return fields
    }
}
