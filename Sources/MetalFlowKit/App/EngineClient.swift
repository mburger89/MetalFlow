import Foundation
import MetalFlowCore

/// The app's view of the run engine: everything the UI needs, behind a protocol so tests use a fake.
public protocol EngineClient: Sendable {
    /// Every saved run state, in order.
    var updates: AsyncStream<Run> { get }
    /// Loads persisted runs.
    func restore() async throws -> [Run]
    /// Starts a run of `flow` in `repo`.
    func launch(flow: Flow, location: FlowLocation, values: [String: String]) async throws -> RunID
    /// Answers a node that asked a question, optionally allowing more tools.
    func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String]) async throws
    /// Sends a message to a finished step's agent session and re-runs everything after it.
    func followUp(_ id: RunID, node: NodeKey, message: String) async throws
    /// Resumes a run that was cut short.
    func resumeInterrupted(_ id: RunID) async throws
    /// Re-runs a failed node.
    func retry(_ id: RunID, node: NodeKey) async throws
    /// Cancels a run.
    func cancel(_ id: RunID) async
    /// Stops a running run so that it can be resumed later (used when quitting).
    func suspend(_ id: RunID) async
    /// Whether another process (typically an `mflow` command) holds the run's lock, so this app does not drive it.
    func isRunningElsewhere(_ id: RunID) async -> Bool
    /// The newest saved state of a run: what another process has written since this app last saw it. Nil if unknown.
    func reload(_ id: RunID) async -> Run?
    /// Runs another process saved that this app has not seen yet, and the ones it deleted.
    func discover() async -> RunEngine.Discovery
    /// Merges a candidate lane into the base branch. `expectedRevision` is the revision of the run as shown: the
    /// engine refuses with `runChanged` if the run has moved on since.
    func pick(_ id: RunID, lane: LaneID, expectedRevision: Int?) async throws -> MergeResult
    /// Throws a run away.
    func discard(_ id: RunID) async throws
    /// Keeps a lane's branch under `name`.
    func branchFromHere(_ id: RunID, lane: LaneID, name: String) async throws
    /// Repositories runs were launched in.
    func knownRepos() -> [URL]
    /// How many agent sessions may run at once, as saved.
    func maxSessions() -> Int
    /// Saves a new limit (held to 1...16) and applies it to the running engine.
    func setMaxSessions(_ max: Int) async throws
    /// Remembers `url` as a known repo, so it is listed on the next start.
    func addKnownRepo(_ url: URL) async throws
    /// Every flow the app can open: built-ins, the library, then each known repo's `.flows`.
    func flowCatalog() -> [FlowEntry]
    /// Where library flows live.
    var libraryDirectory: URL { get }
    /// Whether `url` is the top level of a git repository (it has a `.git` entry).
    func isGitRepo(_ url: URL) async -> Bool
    /// Loads a flow file.
    func loadFlow(_ url: URL) throws -> Flow
    /// Saves a flow file.
    func saveFlow(_ flow: Flow, to url: URL) throws
    /// The unified diff of a lane against the run's branch.
    func diff(_ id: RunID, lane: LaneID) async -> String
}

/// The real client: wraps a `RunEngine` and its `RunStore`. The engine is built off the main thread
/// (reading the login-shell PATH can take seconds), so construction never blocks; every engine call awaits it.
public struct LiveEngineClient: EngineClient {
    let engine: Task<RunEngine, Never>
    let store: RunStore
    /// The engine's updates, forwarded once the engine exists.
    public let updates: AsyncStream<Run>

    /// Creates a client whose engine is built asynchronously by `build`, which starts immediately.
    public init(store: RunStore, build: @escaping @Sendable () async -> RunEngine) {
        let engine = Task { await build() }
        self.engine = engine
        self.store = store
        let (stream, continuation) = AsyncStream.makeStream(of: Run.self, bufferingPolicy: .bufferingNewest(256))
        updates = stream
        let forward = Task {
            for await run in await engine.value.updates { continuation.yield(run) }
            continuation.finish()
        }
        continuation.onTermination = { _ in forward.cancel() }
    }

    /// Creates a client over an existing engine and store.
    public init(engine: RunEngine, store: RunStore) {
        self.init(store: store, build: { engine })
    }

    /// Wires the engine as `mflow` does: resolver, process runner, Claude CLI, GitHub, the run store, and the
    /// login-shell PATH. `METALFLOW_HOME` overrides the store root. Returns at once; the PATH is read in the background.
    public static func makeDefault() -> LiveEngineClient {
        let root: URL
        if let home = ProcessInfo.processInfo.environment["METALFLOW_HOME"], !home.isEmpty {
            root = URL(fileURLWithPath: home)
        } else {
            root = RunStore.defaultRoot
        }
        let store = RunStore(root: root)
        return LiveEngineClient(store: store) {
            let resolver = ExecutableResolver()
            let runner = ProcessRunner(resolver: resolver)
            let path = await resolver.searchPath().joined(separator: ":")
            return RunEngine(
                store: store, runner: runner, agent: ClaudeCLI(runner: runner),
                issues: GitHubIssues(runner: runner), maxSessions: store.settings().maxSessions,
                shellEnvironment: ["PATH": path])
        }
    }

    public func restore() async throws -> [Run] { try await engine.value.restore() }
    public func launch(flow: Flow, location: FlowLocation, values: [String: String]) async throws -> RunID {
        try await engine.value.launch(flow: flow, location: location, values: values)
    }
    public func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String]) async throws {
        try await engine.value.answer(id, node: node, reply: reply, allowTools: allowTools)
    }
    public func followUp(_ id: RunID, node: NodeKey, message: String) async throws {
        try await engine.value.followUp(id, node: node, message: message)
    }
    public func resumeInterrupted(_ id: RunID) async throws { try await engine.value.resumeInterrupted(id) }
    public func retry(_ id: RunID, node: NodeKey) async throws { try await engine.value.retry(id, node: node) }
    public func cancel(_ id: RunID) async { await engine.value.cancel(id) }
    public func suspend(_ id: RunID) async { await engine.value.suspend(id) }
    public func isRunningElsewhere(_ id: RunID) async -> Bool { await engine.value.isRunningElsewhere(id) }
    public func reload(_ id: RunID) async -> Run? { await engine.value.reload(id) }
    public func discover() async -> RunEngine.Discovery { await engine.value.discover() }
    public func pick(_ id: RunID, lane: LaneID, expectedRevision: Int?) async throws -> MergeResult {
        try await engine.value.pick(id, lane: lane, expectedRevision: expectedRevision)
    }
    public func discard(_ id: RunID) async throws { try await engine.value.discard(id) }
    public func branchFromHere(_ id: RunID, lane: LaneID, name: String) async throws {
        try await engine.value.branchFromHere(id, lane: lane, name: name)
    }
    public func knownRepos() -> [URL] { store.knownRepos() }
    public func maxSessions() -> Int { store.settings().maxSessions }
    public func setMaxSessions(_ max: Int) async throws {
        let store = store
        let settings = RunSettings(maxSessions: max)
        try await Task.detached { try store.saveSettings(settings) }.value
        await engine.value.setMaxSessions(settings.maxSessions)
    }
    public func addKnownRepo(_ url: URL) async throws {
        let store = store
        try await Task.detached { try store.addKnownRepo(url) }.value
    }
    public func flowCatalog() -> [FlowEntry] { FlowCatalog.entries(library: store.flowsDirectory, repos: store.knownRepos()) }
    public var libraryDirectory: URL { store.flowsDirectory }
    public func isGitRepo(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }
    public func loadFlow(_ url: URL) throws -> Flow { try FlowFile.load(from: url) }
    public func saveFlow(_ flow: Flow, to url: URL) throws { try FlowFile.save(flow, to: url) }
    public func diff(_ id: RunID, lane: LaneID) async -> String { await engine.value.laneDiff(id, lane: lane) }
}
