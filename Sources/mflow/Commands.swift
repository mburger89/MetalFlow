import Foundation
import os
import MetalFlowCore

let usageText = """
usage: mflow <command> [options]

commands:
  init-flow [--repo DIR] [--force]                write .flows/fix-issue.flow (--force replaces an existing one)
  launch [VALUE] [--flow FILE|NAME] [--repo DIR] [--set name=value]...
                                                  start a run and follow it
  list                                            id  status  title, newest first ("running in another mflow" if locked)
  show <id>                                       nodes, needs-you items, lanes, recommendation
  answer <id> <nodeKey> [--] <reply...> [--allow Tool]
                                                  answer a paused node (-- ends options) and follow the run
  resume <id>                                     resume interrupted nodes and follow the run
  pick <id> <lane>                                merge a candidate into the base branch; when the flow has an Open PR
                                                  node, push it and open a pull request instead, follow the run and
                                                  print the pull request's URL
  discard <id>                                    throw the run away
  branch <id> <lane> <name>                       keep a candidate as a local branch

Runs execute only while an mflow command is running: launch, answer and resume
stay alive until the run settles (needs you, completed, failed or cancelled).
Press Ctrl-C (or send SIGTERM/SIGHUP) to cancel a running run (exit 130). pick, discard and branch
ignore these signals until they finish.

launch: VALUE fills the flow's first input (not the repo); --set name=value fills any input by name and
can be repeated. --flow takes a flow file, or a flow name (case-insensitive) from the built-in, library and
known-repo flows. Without --flow, <repo>/.flows/fix-issue.flow is used if it exists, else the built-in flow.
--repo fills a flow whose repo is asked at launch; with no --repo the git top-level of the current directory is
used. A flow bound to one repo (this repo or fixed) refuses a different --repo ("this flow always runs on <path>").
--repo defaults to the git top-level of the current directory. Set METALFLOW_HOME to use another run store.
Exit codes: 0 ok / needs you / completed / merged / pull request opened, 1 failed / cancelled / not merged /
pull request not opened, 64 usage error.
"""

struct UsageError: Error { var message: String }
struct CommandFailure: Error { var message: String }

struct Arguments {
    var positionals: [String] = []
    var repo: String?
    var flow: String?
    var allow: [String] = []
    var force = false
    var sets: [(String, String)] = []
}

/// Splits `--repo`, `--flow`, `--force` and repeatable `--set` and `--allow` from positionals; they may appear anywhere.
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
        case "--force":
            out.force = true
            i += 1
        case "--repo", "--flow", "--allow", "--set":
            guard i + 1 < args.count else { throw UsageError(message: "\(a) needs a value") }
            let v = args[i + 1]
            switch a {
            case "--repo": out.repo = v
            case "--flow": out.flow = v
            case "--set":
                do { out.sets.append(try LaunchArguments.parseSet(v)) } catch {
                    throw UsageError(message: "expected --set name=value, got '\(v)'")
                }
            default: out.allow.append(v)
            }
            i += 2
        default:
            if a.hasPrefix("--") { throw UsageError(message: "unknown option \(a)") }
            out.positionals.append(a)
            i += 1
        }
    }
    return out
}

/// Throws unless `init-flow` may write `file`: it must not exist, or `force` must be set.
func checkInitFlowTarget(_ file: URL, force: Bool) throws {
    if !force, FileManager.default.fileExists(atPath: file.path) {
        throw CommandFailure(message: "\(file.path) already exists; not overwriting (pass --force to replace it)")
    }
}

func requirePositionals(_ a: Arguments, min: Int, max: Int? = nil, name: String) throws {
    if a.positionals.count < min || (max.map { a.positionals.count > $0 } ?? false) {
        throw UsageError(message: "wrong arguments for \(name)")
    }
}

/// The commands `run()` dispatches.
let knownCommands: Set<String> = ["init-flow", "launch", "list", "show", "answer", "resume", "pick", "discard", "branch"]

/// The stderr text for a missing or unknown command (exit 64), or nil when `argv` names a known one.
func commandLineProblem(_ argv: [String]) -> String? {
    guard let command = argv.first else { return usageText }
    guard knownCommands.contains(command) else { return "mflow: unknown command '\(command)'\n\n\(usageText)" }
    return nil
}

/// The exit code and stderr text for an error that ended a command.
func failureReport(_ error: Error) -> (code: Int32, message: String) {
    switch error {
    case let e as LaunchArgumentError:
        if case .badSet = e { return (64, "mflow: \(e.localizedDescription)\n\n\(usageText)") }
        return (1, "mflow: \(e.localizedDescription)")
    case let e as UsageError: return (64, "mflow: \(e.message)\n\n\(usageText)")
    case let e as CommandFailure: return (1, "mflow: \(e.message)")
    default: return (1, "mflow: \(error.localizedDescription)")
    }
}

/// The flow `launch` runs: `--flow` as a file or a catalog name, else `<repo>/.flows/fix-issue.flow` if present, else the built-in.
func selectFlow(flowArgument: String?, cwdRepo: URL?, library: URL, repos: @autoclosure () -> [URL]) throws -> (Flow, FlowLocation) {
    if let arg = flowArgument {
        let url = URL(fileURLWithPath: arg)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            return (try loadFlow(url), FlowLocation.of(file: url))
        }
        let entries = FlowCatalog.entries(library: library, repos: repos())
        let entry = try FlowCatalog.resolve(flowArgument: arg, entries: entries)
        if let file = entry.file { return (try loadFlow(file), entry.location) }
        return (BuiltinFlows.fixGitHubIssue, .builtin)
    }
    let file = cwdRepo?.appendingPathComponent(FlowFile.directoryName).appendingPathComponent("fix-issue.flow")
    if let file, FileManager.default.fileExists(atPath: file.path) {
        return (try loadFlow(file), FlowLocation.of(file: file))
    }
    return (BuiltinFlows.fixGitHubIssue, .builtin)
}

/// The launch values from VALUE, `--set` and the repo. An exposed repo is filled from `--repo` or the current
/// directory; a bound flow only takes an explicit `--repo` (the engine refuses one that differs). `cwdError` is why
/// the current directory is no repo, thrown when nothing else names a required repo.
func launchValues(flow: Flow, location: FlowLocation, args: Arguments, cwdRepo: URL?, cwdError: Error?) throws -> [String: String] {
    let fields: [LaunchField]
    do { fields = try flow.launchFields(location: location) } catch {
        throw CommandFailure(message: flow.message(for: error))
    }
    var values = try LaunchArguments.values(fields: fields, positional: args.positionals.first, sets: args.sets)
    if fields.contains(where: { $0.kind == .repo }) {
        if let cwdRepo, values["repo"] == nil { values["repo"] = cwdRepo.path }
        // Nothing names the repo and the current directory is not one: say why, not just that a value is missing.
        if let cwdError, values["repo"] == nil, fields.first(where: { $0.kind == .repo })?.defaultValue == nil {
            throw cwdError
        }
    } else if args.repo != nil, let cwdRepo {
        values["repo"] = cwdRepo.path
    }
    return values
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

/// A node's state, and for a gate that has used fix attempts how many: "running (fix 1 of 2)".
func nodeText(_ key: NodeKey, in run: Run) -> String {
    let text = stateText(run.nodes[key]?.state ?? .waiting)
    guard let fix = run.fixProgress(key) else { return text }
    return "\(text) (fix \(fix.used) of \(fix.of))"
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
    case .prOpened(let lane, let url): "PR opened (\(lane)): \(url)"
    case .discarded: "discarded"
    case .failed(let m): "failed: \(m)"
    case .cancelled: "cancelled"
    case .completed: "completed"
    }
}

/// The pull request's URL when the run opened one, else nil.
func pullRequestLine(_ run: Run?) -> String? {
    if case .prOpened(_, let url)? = run?.status { return url }
    return nil
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
        lines.append("  \(key) \(nodeText(key, in: run))")
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
    case .handedToPullRequest: "not merged: opening a pull request instead"
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

func loadFlow(_ url: URL) throws -> Flow {
    do { return try FlowFile.load(from: url) } catch {
        throw CommandFailure(message: "cannot load flow \(url.path): \(error.localizedDescription)")
    }
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
    var last: [NodeKey: String] = seed.map { run in
        Dictionary(uniqueKeysWithValues: run.nodes.keys.map { ($0, nodeText($0, in: run)) })
    } ?? [:]
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
        for key in run.nodes.keys.sorted(by: { $0.description < $1.description }) {
            let text = nodeText(key, in: run)
            guard last[key] != text else { continue }
            last[key] = text
            print("\(key) \(text)")
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
