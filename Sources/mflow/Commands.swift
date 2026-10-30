import Foundation
import os
import MetalFlowCore

let usageText = """
usage: mflow <command> [options]

commands:
  init-flow [--repo DIR]                          write .flows/fix-issue.flow (refuses to overwrite)
  launch <issue> [--repo DIR] [--flow FILE]       start a run for a GitHub issue and follow it
  list                                            id  status  title, newest first ("running in another mflow" if locked)
  show <id>                                       nodes, needs-you items, lanes, recommendation
  answer <id> <nodeKey> [--] <reply...> [--allow Tool]
                                                  answer a paused node (-- ends options) and follow the run
  resume <id>                                     resume interrupted nodes and follow the run
  pick <id> <lane>                                merge a candidate into the base branch
  discard <id>                                    throw the run away
  branch <id> <lane> <name>                       keep a candidate as a local branch

Runs execute only while an mflow command is running: launch, answer and resume
stay alive until the run settles (needs you, completed, failed or cancelled).
Press Ctrl-C (or send SIGTERM/SIGHUP) to cancel a running run (exit 130). pick, discard and branch
ignore these signals until they finish.

--repo defaults to the git top-level of the current directory; --flow defaults to
<repo>/.flows/fix-issue.flow. Set METALFLOW_HOME to use another run store.
Exit codes: 0 ok / needs you / completed / merged, 1 failed / cancelled / not merged, 64 usage error.
"""

struct UsageError: Error { var message: String }
struct CommandFailure: Error { var message: String }

struct Arguments {
    var positionals: [String] = []
    var repo: String?
    var flow: String?
    var allow: [String] = []
}

/// Splits `--repo`, `--flow` and repeatable `--allow` from positionals; they may appear anywhere.
func parseArguments(_ args: [String]) throws -> Arguments {
    var out = Arguments()
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--" {
            out.positionals.append(contentsOf: args[(i + 1)...])
            break
        }
        switch a {
        case "--repo", "--flow", "--allow":
            guard i + 1 < args.count else { throw UsageError(message: "\(a) needs a value") }
            let v = args[i + 1]
            if a == "--repo" { out.repo = v } else if a == "--flow" { out.flow = v } else { out.allow.append(v) }
            i += 2
        default:
            if a.hasPrefix("--") { throw UsageError(message: "unknown option \(a)") }
            out.positionals.append(a)
            i += 1
        }
    }
    return out
}

func requirePositionals(_ a: Arguments, min: Int, max: Int? = nil, name: String) throws {
    if a.positionals.count < min || (max.map { a.positionals.count > $0 } ?? false) {
        throw UsageError(message: "wrong arguments for \(name)")
    }
}

func stderrPrint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// MARK: - Formatting

func stateText(_ s: NodeState) -> String {
    switch s {
    case .waiting: "waiting"
    case .running: "running"
    case .succeeded: "succeeded"
    case .failed(let m): "failed: \(m)"
    case .needsYou(let n): "needs you (\(needsYouText(n)))"
    case .interrupted: "interrupted"
    case .cancelled: "cancelled"
    }
}

func needsYouText(_ n: NeedsYou) -> String {
    switch n {
    case .question(let q): "question: \(q)"
    case .deniedTools(let t): "denied tools: \(t.joined(separator: ", "))"
    case .pickWinner(let rec, let allFailed):
        "pick a winner" + (rec.map { ", recommended \($0)" } ?? "") + (allFailed ? ", all gates failed" : "")
    }
}

func statusText(_ s: RunStatus) -> String {
    switch s {
    case .running: "running"
    case .needsYou: "needs you"
    case .merged(let lane): "merged (\(lane))"
    case .discarded: "discarded"
    case .failed(let m): "failed: \(m)"
    case .cancelled: "cancelled"
    case .completed: "completed"
    }
}

func gateText(_ g: Bool?) -> String {
    switch g {
    case true?: "gate passed"
    case false?: "gate failed"
    case nil: "gate pending"
    }
}

func runSummary(_ run: Run) -> [String] {
    var lines = ["\(run.id.rawValue)  \(statusText(run.status))  \(run.title)",
                 "  repo \(run.repo.path)  base \(run.baseBranch)  branch \(run.branch)"]
    lines.append("nodes:")
    for (key, node) in run.nodes.sorted(by: { $0.key.description < $1.key.description }) {
        lines.append("  \(key) \(stateText(node.state))")
    }
    let pending = run.needsYou
    if !pending.isEmpty {
        lines.append("needs you:")
        for (key, item) in pending { lines.append("  \(key): \(needsYouText(item))") }
    }
    if !run.lanes.isEmpty {
        lines.append("lanes:")
        for l in run.lanes {
            lines.append("  \(l.id)  \(l.model)  \(gateText(l.gatePassed))  +\(l.added) -\(l.removed)  \(l.branch)")
        }
    }
    if let r = run.recommendation { lines.append("recommendation: \(r)") }
    return lines
}

func mergeResultText(_ r: MergeResult) -> String {
    switch r {
    case .merged(let c): "merged as \(c)"
    case .blockedDirty(let url): "not merged: the base branch is checked out at \(url.path) with uncommitted changes"
    case .conflict(let files): "not merged: conflicts in \(files.joined(separator: ", "))"
    }
}

// MARK: - Repo and wiring

func resolveRepo(_ option: String?, runner: any CommandRunner) async throws -> URL {
    let dir = URL(fileURLWithPath: option ?? FileManager.default.currentDirectoryPath).standardizedFileURL
    let result = try await runner.run(Command(
        executable: "git", arguments: ["rev-parse", "--show-toplevel"], workingDirectory: dir))
    guard result.succeeded else { throw CommandFailure(message: "\(dir.path) is not inside a git repository") }
    return URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
}

func storeRoot() -> URL {
    if let home = ProcessInfo.processInfo.environment["METALFLOW_HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home)
    }
    return RunStore.defaultRoot
}

func parseRunID(_ s: String) throws -> RunID {
    guard UUID(uuidString: s) != nil else { throw CommandFailure(message: "'\(s)' is not a run id") }
    return RunID(rawValue: s.uppercased())
}

// MARK: - Following a run

/// Routes the given signals to `handler` through dispatch sources (the default action is suppressed meanwhile).
func handleSignals(_ signals: [Int32], _ handler: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
    signals.map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}

/// Runs a short, must-finish operation (pick, discard, branch) with SIGINT, SIGTERM and SIGHUP ignored, so the
/// repository cannot be left mid-merge. A signal that arrives meanwhile only prints a notice.
func uninterruptible<T>(_ body: () async throws -> T) async rethrows -> T {
    let sources = handleSignals([SIGINT, SIGTERM, SIGHUP]) {
        stderrPrint("finishing… (Ctrl-C ignored)")
    }
    defer {
        sources.forEach { $0.cancel() }
        for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, SIG_DFL) }
    }
    return try await body()
}

/// Prints node state changes until the run leaves `.running`; returns the exit code.
/// SIGINT, SIGTERM or SIGHUP cancels a running run, waits for it to settle, prints "cancelled" and returns 130.
func follow(engine: RunEngine, id: RunID, seed: Run?) async -> Int32 {
    var last: [NodeKey: NodeState] = seed?.nodes.mapValues(\.state) ?? [:]
    var lastStatus: RunStatus? = seed?.status
    let interrupted = OSAllocatedUnfairLock(initialState: false)

    // Ctrl-C, kill and a closing terminal all cancel the run and let it settle. Once the first signal has been
    // handled the default disposition returns, so a second one ends mflow at once.
    let sources = handleSignals([SIGINT, SIGTERM, SIGHUP]) {
        interrupted.withLock { $0 = true }
        Task { await engine.cancel(id) }
        for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, SIG_DFL) }
    }
    defer { sources.forEach { $0.cancel() } }

    var lastRevision = -1
    /// Prints changes; returns false for a stale snapshot (revision not newer than one already shown).
    func report(_ run: Run) -> Bool {
        guard run.revision > lastRevision else { return false }
        lastRevision = run.revision
        for (key, node) in run.nodes.sorted(by: { $0.key.description < $1.key.description })
        where last[key] != node.state {
            last[key] = node.state
            print("\(key) \(stateText(node.state))")
        }
        if run.status != lastStatus {
            lastStatus = run.status
            print("run \(statusText(run.status))")
        }
        return true
    }

    if let run = await engine.run(id) {
        _ = report(run)
        if run.status != .running { return await finish(engine, id, run, interrupted) }
    }
    for await run in engine.updates where run.id == id {
        guard report(run) else { continue }
        if run.status != .running { return await finish(engine, id, run, interrupted) }
    }
    return 1
}

private func finish(_ engine: RunEngine, _ id: RunID, _ run: Run, _ interrupted: OSAllocatedUnfairLock<Bool>) async -> Int32 {
    if interrupted.withLock({ $0 }), run.status == .cancelled {
        await engine.waitUntilSettled(id)
        print("cancelled")
        return 130
    }
    if case .needsYou = run.status {
        for (key, item) in run.needsYou { print("needs you: \(key): \(needsYouText(item))") }
        if let r = run.recommendation { print("recommendation: \(r)") }
    }
    switch run.status {
    case .failed, .cancelled: return 1
    default: return 0
    }
}
