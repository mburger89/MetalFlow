import Foundation
import MetalFlowCore

/// The app's view of the run engine: everything the UI needs, behind a protocol so tests use a fake.
public protocol EngineClient: Sendable {
    /// Every saved run state, in order.
    var updates: AsyncStream<Run> { get }
    /// Loads persisted runs.
    func restore() async throws -> [Run]
    /// Starts a run of `flow` in `repo`.
    func launch(flow: Flow, repo: URL, input: String) async throws -> RunID
    /// Answers a node that asked a question, optionally allowing more tools.
    func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String]) async throws
    /// Resumes a run that was cut short.
    func resumeInterrupted(_ id: RunID) async throws
    /// Re-runs a failed node.
    func retry(_ id: RunID, node: NodeKey) async throws
    /// Cancels a run.
    func cancel(_ id: RunID) async
    /// Merges a candidate lane into the base branch.
    func pick(_ id: RunID, lane: LaneID) async throws -> MergeResult
    /// Throws a run away.
    func discard(_ id: RunID) async throws
    /// Keeps a lane's branch under `name`.
    func branchFromHere(_ id: RunID, lane: LaneID, name: String) async throws
    /// Repositories runs were launched in.
    func knownRepos() -> [URL]
    /// The `.flow` files of a repository.
    func flows(in repo: URL) -> [URL]
    /// Loads a flow file.
    func loadFlow(_ url: URL) throws -> Flow
    /// Saves a flow file.
    func saveFlow(_ flow: Flow, to url: URL) throws
    /// The unified diff of a lane against the run's branch.
    func diff(_ id: RunID, lane: LaneID) async -> String
}

/// The real client: wraps a `RunEngine` and its `RunStore`.
public struct LiveEngineClient: EngineClient {
    let engine: RunEngine
    let store: RunStore

    /// Creates a client over an existing engine and store.
    public init(engine: RunEngine, store: RunStore) {
        self.engine = engine
        self.store = store
    }

    /// Wires the engine as `mflow` does: resolver, process runner, Claude CLI, GitHub, the run store, and the
    /// login-shell PATH. `METALFLOW_HOME` overrides the store root. Blocks briefly to read the PATH.
    public static func makeDefault() -> LiveEngineClient {
        let root: URL
        if let home = ProcessInfo.processInfo.environment["METALFLOW_HOME"], !home.isEmpty {
            root = URL(fileURLWithPath: home)
        } else {
            root = RunStore.defaultRoot
        }
        let resolver = ExecutableResolver()
        let runner = ProcessRunner(resolver: resolver)
        let box = PathBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await resolver.searchPath().joined(separator: ":")
            semaphore.signal()
        }
        semaphore.wait()
        let store = RunStore(root: root)
        let engine = RunEngine(
            store: store, runner: runner, agent: ClaudeCLI(runner: runner),
            issues: GitHubIssues(runner: runner), shellEnvironment: ["PATH": box.value])
        return LiveEngineClient(engine: engine, store: store)
    }

    public var updates: AsyncStream<Run> { engine.updates }
    public func restore() async throws -> [Run] { try await engine.restore() }
    public func launch(flow: Flow, repo: URL, input: String) async throws -> RunID {
        try await engine.launch(flow: flow, repo: repo, input: input)
    }
    public func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String]) async throws {
        try await engine.answer(id, node: node, reply: reply, allowTools: allowTools)
    }
    public func resumeInterrupted(_ id: RunID) async throws { try await engine.resumeInterrupted(id) }
    public func retry(_ id: RunID, node: NodeKey) async throws { try await engine.retry(id, node: node) }
    public func cancel(_ id: RunID) async { await engine.cancel(id) }
    public func pick(_ id: RunID, lane: LaneID) async throws -> MergeResult { try await engine.pick(id, lane: lane) }
    public func discard(_ id: RunID) async throws { try await engine.discard(id) }
    public func branchFromHere(_ id: RunID, lane: LaneID, name: String) async throws {
        try await engine.branchFromHere(id, lane: lane, name: name)
    }
    public func knownRepos() -> [URL] { store.knownRepos() }
    public func flows(in repo: URL) -> [URL] { engine.flows(in: repo) }
    public func loadFlow(_ url: URL) throws -> Flow { try FlowFile.load(from: url) }
    public func saveFlow(_ flow: Flow, to url: URL) throws { try FlowFile.save(flow, to: url) }
    public func diff(_ id: RunID, lane: LaneID) async -> String { await engine.laneDiff(id, lane: lane) }
}

/// Carries the PATH string out of a detached task; written once before the semaphore is signalled.
private final class PathBox: @unchecked Sendable {
    var value = ""
}
