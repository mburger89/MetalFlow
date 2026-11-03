import Foundation
import MetalFlowCore
@testable import MetalFlowKit

/// A scripted engine: serves canned runs, records every call, and pushes updates on demand.
actor FakeEngineClient: EngineClient {
    nonisolated let updates: AsyncStream<Run>
    private let continuation: AsyncStream<Run>.Continuation

    /// What `restore()` returns.
    var restored: [Run]
    /// Every call, as "name(args)".
    private(set) var calls: [String] = []
    /// When set, every throwing call throws it.
    var failure: Error?
    /// What `pick` returns.
    var pickResult: MergeResult = .merged(commit: "abc")

    nonisolated let repoList: URLList
    /// The known repos: those given at init plus any added through `addKnownRepo`.
    nonisolated var repos: [URL] { repoList.urls }
    nonisolated let flowFiles: [URL]
    nonisolated let gitRepoPaths: Set<String>

    init(restored: [Run] = [], repos: [URL] = [], flowFiles: [URL] = [], gitRepoPaths: Set<String> = []) {
        self.restored = restored
        (setMaxStarts, setMaxStartsContinuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)
        self.repoList = URLList(repos)
        self.flowFiles = flowFiles
        self.gitRepoPaths = gitRepoPaths
        (updates, continuation) = AsyncStream.makeStream(of: Run.self, bufferingPolicy: .unbounded)
        // The built-in plus each flow file, so tests that only name files still see them in the catalog.
        catalog.entries = [FlowEntry(id: "builtin:\(BuiltinFlows.fixGitHubIssue.name)", name: BuiltinFlows.fixGitHubIssue.name,
                                     location: .builtin, file: nil)]
            + flowFiles.map { FlowEntry(id: $0.path, name: $0.deletingPathExtension().lastPathComponent, location: .of(file: $0), file: $0) }
    }

    /// Pushes a snapshot onto `updates`.
    func send(_ run: Run) { continuation.yield(run) }
    /// Ends `updates`.
    func finish() { continuation.finish() }
    func setFailure(_ error: Error?) { failure = error }
    func setPick(_ result: MergeResult) { pickResult = result }

    private func record(_ call: String) throws {
        calls.append(call)
        if let failure { throw failure }
    }

    func restore() async throws -> [Run] { try record("restore"); return restored }
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    /// Makes `launch` suspend until `releaseLaunches()`.
    func holdLaunches() { holding = true }
    /// Resumes every suspended `launch`.
    func releaseLaunches() {
        holding = false
        for c in held { c.resume() }
        held = []
    }

    /// The location and values of every `launch` received.
    var launches: [(location: FlowLocation, values: [String: String])] = []
    /// The flow of every `launch` received.
    var launchedFlows: [Flow] = []
    func launch(flow: Flow, location: FlowLocation, values: [String: String]) async throws -> RunID {
        if holding { await withCheckedContinuation { held.append($0) } }
        launches.append((location, values))
        launchedFlows.append(flow)
        let input = values.filter { $0.key != "repo" }.values.first ?? ""
        try record("launch(\(flow.name), \(values["repo"] ?? ""), \(input))")
        return RunID()
    }
    func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String]) async throws {
        try record("answer(\(node), \(reply), \(allowTools))")
    }
    func followUp(_ id: RunID, node: NodeKey, message: String) async throws {
        try record("followUp(\(node), \(message))")
    }
    func resumeInterrupted(_ id: RunID) async throws { try record("resume") }
    func retry(_ id: RunID, node: NodeKey) async throws { try record("retry(\(node))") }
    func cancel(_ id: RunID) async { calls.append("cancel") }
    func suspend(_ id: RunID) async { calls.append("suspend") }
    /// The runs the fake reports as driven by another process.
    var elsewhere: Set<RunID> = []
    func setElsewhere(_ ids: Set<RunID>) { elsewhere = ids }
    func isRunningElsewhere(_ id: RunID) async -> Bool { elsewhere.contains(id) }
    /// What `reload` returns per run (nil: no newer state known).
    var reloads: [RunID: Run] = [:]
    func setReload(_ run: Run) { reloads[run.id] = run }
    func reload(_ id: RunID) async -> Run? { calls.append("reload"); return reloads[id] }
    /// What `discover` returns (once: the fake forgets them, as the real engine caches what it found).
    var discoverable: [Run] = []
    func setDiscoverable(_ runs: [Run]) { discoverable = runs }
    /// What `discover` reports as deleted (once, like `discoverable`).
    var vanishable: [RunID] = []
    func setVanished(_ ids: [RunID]) { vanishable = ids }
    func discover() async -> RunEngine.Discovery {
        calls.append("discover")
        defer { discoverable = []; vanishable = [] }
        return RunEngine.Discovery(found: discoverable, vanished: vanishable)
    }
    private var holdingPicks = false
    private var heldPicks: [CheckedContinuation<Void, Never>] = []
    /// Makes `pick` suspend until `releasePicks()`.
    func holdPicks() { holdingPicks = true }
    /// Resumes every suspended `pick`.
    func releasePicks() {
        holdingPicks = false
        for c in heldPicks { c.resume() }
        heldPicks = []
    }
    /// What `diff` returns.
    var diffText = ""
    func setDiff(_ text: String) { diffText = text }

    func pick(_ id: RunID, lane: LaneID) async throws -> MergeResult {
        calls.append("pick-start(\(lane))")
        // Only the first call is held, so a second one (a broken in-flight guard) fails a test instead of hanging it.
        if holdingPicks && heldPicks.isEmpty { await withCheckedContinuation { heldPicks.append($0) } }
        try record("pick(\(lane))")
        return pickResult
    }
    func discard(_ id: RunID) async throws { try record("discard") }
    func branchFromHere(_ id: RunID, lane: LaneID, name: String) async throws {
        try record("branch(\(lane), \(name))")
    }
    nonisolated func knownRepos() -> [URL] { repos }
    /// The saved session limit.
    nonisolated let limit = IntBox(4)
    nonisolated func maxSessions() -> Int { limit.value }
    /// Every `setMaxSessions` call's value, in arrival order.
    var setMaxCalls: [Int] = []
    /// The most `setMaxSessions` calls that were ever in flight together.
    var peakSetMax = 0
    private var activeSetMax = 0
    /// Calls start here as they arrive (their value).
    nonisolated let setMaxStarts: AsyncStream<Int>
    private let setMaxStartsContinuation: AsyncStream<Int>.Continuation
    private var holdingFirstSetMax = false
    private var heldSetMax: CheckedContinuation<Void, Never>?
    /// Whether each upcoming `setMaxSessions` call throws, consumed one per call.
    var setMaxFailures: [Bool] = []
    /// Makes the first `setMaxSessions` call suspend until `releaseSetMax()`.
    func holdFirstSetMax() { holdingFirstSetMax = true }
    func releaseSetMax() { heldSetMax?.resume(); heldSetMax = nil; holdingFirstSetMax = false }
    func setSetMaxFailures(_ failures: [Bool]) { setMaxFailures = failures }
    func setMaxSessions(_ max: Int) async throws {
        calls.append("setMaxSessions(\(max))")
        setMaxCalls.append(max)
        activeSetMax += 1
        peakSetMax = Swift.max(peakSetMax, activeSetMax)
        defer { activeSetMax -= 1 }
        setMaxStartsContinuation.yield(max)
        if holdingFirstSetMax, setMaxCalls.count == 1 { await withCheckedContinuation { heldSetMax = $0 } }
        let fails = setMaxFailures.isEmpty ? false : setMaxFailures.removeFirst()
        if let failure { throw failure }
        if fails { throw FakeFailure() }
        limit.value = max
    }
    func addKnownRepo(_ url: URL) async throws {
        try record("addKnownRepo(\(url.path))")
        repoList.add(url)
    }
    /// What `flowCatalog()` returns, and `libraryDirectory`.
    nonisolated let catalog = CatalogBox()
    nonisolated func flowCatalog() -> [FlowEntry] { catalog.scan() }
    nonisolated var libraryDirectory: URL { catalog.library }
    func isGitRepo(_ url: URL) async -> Bool { gitRepoPaths.contains(url.path) }
    /// Every `saveFlow` call, and whether `loadFlow` fails.
    nonisolated let files = FileLog()
    nonisolated func loadFlow(_ url: URL) throws -> Flow {
        files.gate.pass(url)
        if files.failLoad { throw FakeFailure() }
        var flow = files.flows[url] ?? BuiltinFlows.fixGitHubIssue
        if let name = files.names[url] { flow.name = name }
        return flow
    }
    nonisolated func saveFlow(_ flow: Flow, to url: URL) throws {
        if files.failSave { throw FakeFailure() }
        files.record(flow, url)
    }
    private var holdingDiffs = false
    private var heldDiffs: [CheckedContinuation<Void, Never>] = []
    private var diffEntries = 0
    private var diffEntryWaiters: [CheckedContinuation<Void, Never>] = []
    /// Makes `diff` suspend until `releaseDiffs()`.
    func holdDiffs() { holdingDiffs = true }
    /// Resumes every suspended `diff`.
    func releaseDiffs() {
        holdingDiffs = false
        for c in heldDiffs { c.resume() }
        heldDiffs = []
    }
    /// Returns once a `diff` call has started.
    func waitForDiffStart() async {
        if diffEntries == 0 { await withCheckedContinuation { diffEntryWaiters.append($0) } }
    }
    func diff(_ id: RunID, lane: LaneID) async -> String {
        calls.append("diff(\(lane))")
        diffEntries += 1
        for w in diffEntryWaiters { w.resume() }
        diffEntryWaiters = []
        if holdingDiffs { await withCheckedContinuation { heldDiffs.append($0) } }
        return diffText
    }
}

struct FakeFailure: LocalizedError {
    var errorDescription: String? { "engine said no" }
}

/// A run of the built-in fix-issue flow with the given status, for model tests.
func makeRun(_ title: String = "run", status: RunStatus = .running, revision: Int = 0,
             createdAt: Date = Date(timeIntervalSince1970: 1_000), id: RunID = RunID(),
             nodes: [NodeKey: NodeRun] = [:]) -> Run {
    Run(id: id, flow: BuiltinFlows.fixGitHubIssue, title: title, repo: URL(fileURLWithPath: "/repo"),
        baseBranch: "main", branch: "mf/\(title)", worktree: URL(fileURLWithPath: "/wt"),
        createdAt: createdAt, status: status, nodes: nodes, revision: revision)
}

/// Lets a test hold `loadFlow` for one file and learn that it has been entered, with no sleeping.
final class LoadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held: URL?
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?

    func hold(_ url: URL) { condition.lock(); held = url; entered = false; condition.unlock() }
    func release() { condition.lock(); held = nil; condition.broadcast(); condition.unlock() }
    func waitForEntry() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            condition.lock()
            if entered { condition.unlock(); c.resume() } else { waiter = c; condition.unlock() }
        }
    }
    func pass(_ url: URL) {
        condition.lock()
        defer { condition.unlock() }
        guard held == url else { return }
        entered = true
        waiter?.resume()
        waiter = nil
        while held == url { condition.wait() }
    }
}

/// What the fake client was asked to save, readable from any context.
final class FileLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: [(Flow, URL)] = []
    private var _failLoad = false
    /// Every saved flow and its file, in order.
    var saved: [(flow: Flow, url: URL)] { lock.withLock { _saved.map { (flow: $0.0, url: $0.1) } } }
    /// When true, `loadFlow` throws.
    var failLoad: Bool {
        get { lock.withLock { _failLoad } }
        set { lock.withLock { _failLoad = newValue } }
    }
    private var _names: [URL: String] = [:]
    /// The flow name `loadFlow` returns for a file (the built-in's name for the others).
    var names: [URL: String] {
        get { lock.withLock { _names } }
        set { lock.withLock { _names = newValue } }
    }
    private var _flows: [URL: Flow] = [:]
    /// The flow `loadFlow` returns for a file (the built-in for the others).
    var flows: [URL: Flow] {
        get { lock.withLock { _flows } }
        set { lock.withLock { _flows = newValue } }
    }
    let gate = LoadGate()
    private var _failSave = false
    /// When true, `saveFlow` throws.
    var failSave: Bool {
        get { lock.withLock { _failSave } }
        set { lock.withLock { _failSave = newValue } }
    }
    func record(_ flow: Flow, _ url: URL) { lock.withLock { _saved.append((flow, url)) } }
}

/// Seedable catalog state for `FakeEngineClient`.
final class CatalogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [FlowEntry] = []
    private var _library = URL(fileURLWithPath: "/tmp/fake-library", isDirectory: true)
    var entries: [FlowEntry] {
        get { lock.withLock { _entries } }
        set { lock.withLock { _entries = newValue } }
    }
    private let gate = LoadGate()
    private let gateURL = URL(fileURLWithPath: "/catalog-gate")
    private var holdNext = false
    /// Makes the next `scan` return what the catalog holds now, but only once `release()` is called.
    func holdNextScan() { lock.withLock { holdNext = true }; gate.hold(gateURL) }
    /// Lets a held `scan` return.
    func release() { gate.release() }
    /// Returns once a held `scan` has started.
    func waitForHeldScan() async { await gate.waitForEntry() }
    /// The entries now; a held scan returns this snapshot after it is released.
    func scan() -> [FlowEntry] {
        let snapshot = entries
        let hold = lock.withLock { () -> Bool in defer { holdNext = false }; return holdNext }
        if hold { gate.pass(gateURL) }
        return snapshot
    }
    var library: URL {
        get { lock.withLock { _library } }
        set { lock.withLock { _library = newValue } }
    }
}

/// A lock-guarded URL list for `FakeEngineClient`.
final class URLList: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL]
    init(_ urls: [URL]) { _urls = urls }
    var urls: [URL] { lock.withLock { _urls } }
    func add(_ url: URL) { lock.withLock { if !_urls.contains(url) { _urls.append(url) } } }
}

/// A lock-guarded integer for `FakeEngineClient`.
final class IntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int
    init(_ value: Int) { _value = value }
    var value: Int {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
