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

    nonisolated let repos: [URL]
    nonisolated let flowFiles: [URL]
    nonisolated let gitRepoPaths: Set<String>

    init(restored: [Run] = [], repos: [URL] = [], flowFiles: [URL] = [], gitRepoPaths: Set<String> = []) {
        self.restored = restored
        self.repos = repos
        self.flowFiles = flowFiles
        self.gitRepoPaths = gitRepoPaths
        (updates, continuation) = AsyncStream.makeStream(of: Run.self, bufferingPolicy: .unbounded)
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

    func launch(flow: Flow, repo: URL, input: String) async throws -> RunID {
        if holding { await withCheckedContinuation { held.append($0) } }
        try record("launch(\(flow.name), \(repo.path), \(input))")
        return RunID()
    }
    func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String]) async throws {
        try record("answer(\(node), \(reply), \(allowTools))")
    }
    func resumeInterrupted(_ id: RunID) async throws { try record("resume") }
    func retry(_ id: RunID, node: NodeKey) async throws { try record("retry(\(node))") }
    func cancel(_ id: RunID) async { calls.append("cancel") }
    func suspend(_ id: RunID) async { calls.append("suspend") }
    /// The runs the fake reports as driven by another process.
    var elsewhere: Set<RunID> = []
    func setElsewhere(_ ids: Set<RunID>) { elsewhere = ids }
    func isRunningElsewhere(_ id: RunID) async -> Bool { elsewhere.contains(id) }
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
    /// Holds `flows(in:)` (called off the main actor) until released.
    nonisolated let scanGate = ScanGate()
    nonisolated func flows(in repo: URL) -> [URL] { scanGate.pass(); return flowFiles }
    func isGitRepo(_ url: URL) async -> Bool { gitRepoPaths.contains(url.path) }
    /// Every `saveFlow` call, and whether `loadFlow` fails.
    nonisolated let files = FileLog()
    nonisolated func loadFlow(_ url: URL) throws -> Flow {
        if files.failLoad { throw FakeFailure() }
        var flow = BuiltinFlows.fixGitHubIssue
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

/// Lets a test hold the flow scan and learn that it has been entered, with no sleeping.
final class ScanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// Makes the next scans block.
    func hold() { condition.lock(); held = true; entered = false; condition.unlock() }
    /// Unblocks scans.
    func release() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
    /// Returns once a scan is blocked in the gate.
    func waitForEntry() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            condition.lock()
            if entered { condition.unlock(); c.resume() } else { waiter = c; condition.unlock() }
        }
    }
    func pass() {
        condition.lock()
        entered = true
        waiter?.resume()
        waiter = nil
        while held { condition.wait() }
        condition.unlock()
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
    private var _failSave = false
    /// When true, `saveFlow` throws.
    var failSave: Bool {
        get { lock.withLock { _failSave } }
        set { lock.withLock { _failSave = newValue } }
    }
    func record(_ flow: Flow, _ url: URL) { lock.withLock { _saved.append((flow, url)) } }
}
