# MetalFlow Engine (Plan 1 of 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A UI-free engine, `MetalFlowCore`, that loads a flow graph, launches a run of it on a local repo with a GitHub issue, runs headless Claude Code sessions in per-run and per-candidate git worktrees, pauses for the user, and merges the picked candidate. Plus a small `mflow` CLI that drives the whole v1 loop from the terminal.

**Architecture:** Pure Swift package with no UI dependencies. Every external program (`git`, `gh`, `claude`, gate commands) goes through one `CommandRunner` protocol, so the engine is tested with fakes. `git` is tested against real throwaway repos. A `RunEngine` actor executes a flow DAG from persisted `Run` state, so pausing, answering and resuming after relaunch are all "run the pass again, skipping finished nodes". Plan 2 (MetalUI app: Dashboard, Flow Studio, notifications, `.app` bundle) builds on this plan's public API and is written once this lands.

**Tech Stack:** Swift 6.4, SwiftPM (swift-tools 6.1), Swift Testing, Foundation `Process`, macOS 14+. External CLIs: `git`, `gh`, `claude` (2.1.x).

**Spec:** `docs/superpowers/specs/2026-10-30-metalflow-v1-design.md`

## Global Constraints

- `swiftLanguageModes: [.v6]`, `platforms: [.macOS(.v14)]`; strict concurrency clean (no `@unchecked Sendable` except the `Process` wrapper).
- `MetalFlowCore` imports Foundation only — no MetalUI, AppKit or SwiftUI.
- Tests: Swift Testing (`import Testing`), run with `swift test --no-parallel`. Tests never sleep; they await fakes. No test calls the real `claude` or `gh`.
- The judge only recommends. Nothing merges without an explicit `pick`.
- Every run and every candidate gets its own worktree under the storage root; the user's checkout is only touched by `pick`, and only when the base branch's checkout is clean.
- Merge is `git merge --no-ff`. Nothing is ever pushed.
- Storage root default: `~/Library/Application Support/MetalFlow/` (injectable in every API that touches disk).
- At most 4 concurrent Claude sessions across all runs by default (`maxSessions`).
- Branch names: run `flow/<issue>-<slug>`, candidate `flow/<issue>-<slug>--<lane>` (git cannot hold both `x` and `x/a` as refs, so the spec's `/a` becomes `--a`).
- Public declarations get a doc comment (MetalUI convention, kept here).

## Review Focus

1. **Odd issue titles** (slashes, emoji, quotes, 200 chars, empty) must produce a valid, short branch name; launching the same issue twice must not collide — Task 5 `slugAndUniqueBranch` test.
2. **Dirty base checkout at pick time** must merge nothing and change nothing — Task 10 `pickBlockedWhenBaseCheckoutDirty`.
3. **Merge conflict** must abort cleanly, leave the base branch unchanged and keep the run in Needs-you — Task 10 `pickConflictAborts`.
4. **`claude`/`gh` missing or failing** must fail the node with a readable message, never hang the run — Task 4 `missingExecutableThrows`, Task 9 `agentErrorFailsLaneNotRun`.
5. **App killed mid-run** must load as `interrupted` and resume from the stored session id without re-running finished nodes — Task 8 `loadMarksRunningAsInterrupted`, Task 10 `resumeInterruptedSkipsFinishedNodes`.

---

## File Structure

```
Package.swift
Sources/MetalFlowCore/
  Graph/Flow.swift            Flow, Node, NodeID, Wire, NodeKind + configs, Point
  Graph/FlowValidation.swift  validate(), topologicalOrder(), fan-out/lane analysis
  Graph/FlowFile.swift        JSON load/save of .flow files
  Graph/Template.swift        {placeholder} filling
  Graph/BuiltinFlows.swift    BuiltinFlows.fixGitHubIssue
  Process/CommandRunner.swift Command, CommandResult, CommandRunner protocol, ProcessRunner, ExecutableResolver
  Git/Git.swift               worktrees, commits, diffs, merge
  Git/BranchNaming.swift      slug(), uniqueBranch()
  GitHub/GitHubIssues.swift   fetch issue via gh
  Agent/AgentSession.swift    AgentRequest, AgentEvent, AgentResult, AgentSession protocol
  Agent/ClaudeStreamParser.swift  stream-json line → AgentEvent
  Agent/ClaudeCLI.swift       AgentSession over `claude -p`
  Run/Run.swift               Run, RunID, NodeRun, NodeKey, Lane, statuses
  Run/RunStore.swift          persistence (runs/, repos.json)
  Run/SessionLimiter.swift    async semaphore
  Run/RunEngine.swift         launch / execute pass / answer / cancel
  Run/RunEngine+Decide.swift  pick / discard / branchFromHere / cleanup
Sources/mflow/main.swift      CLI
Tests/MetalFlowCoreTests/
  Fixtures/*.jsonl            recorded claude stream-json (Task 1)
  Support/FakeCommandRunner.swift, FakeAgent.swift, TempRepo.swift
  <one test file per source file above>
docs/notes/claude-stream-json.md   spike findings
```

---

### Task 1: Package skeleton and Claude CLI spike

**Files:**
- Create: `Package.swift`, `Sources/MetalFlowCore/MetalFlowCore.swift` (one doc comment + `public enum MetalFlowCore { public static let version = "0.1.0" }`), `Sources/mflow/main.swift` (prints version), `Tests/MetalFlowCoreTests/SmokeTests.swift`
- Create: `Tests/MetalFlowCoreTests/Fixtures/success.jsonl`, `denied.jsonl`, `resume.jsonl`, `docs/notes/claude-stream-json.md`

**Interfaces:**
- Produces: targets `MetalFlowCore` (library), `mflow` (executable), `MetalFlowCoreTests` (resources: `.copy("Fixtures")`).

- [ ] **Step 1:** Write `Package.swift`: swift-tools 6.1, products `.library(MetalFlowCore)`, `.executable(mflow)`; test target depends on `MetalFlowCore` with `resources: [.copy("Fixtures")]`; `swiftLanguageModes: [.v6]`.
- [ ] **Step 2:** Smoke test `@Test func versionIsSet() { #expect(MetalFlowCore.version == "0.1.0") }`; run `swift test --no-parallel` → PASS.
- [ ] **Step 3: Spike — record real output.** In a scratch git repo (`mktemp -d`, `git init`, one commit), run with the real binary (`whence -p claude` in `zsh -lic` — `claude` in the user's shell is a wrapper function):
  - `claude -p "Reply with exactly: OK" --output-format stream-json --verbose --model haiku > success.jsonl`
  - `claude -p "Create a file named x.txt containing hi" --output-format stream-json --verbose --model haiku --allowedTools Read > denied.jsonl` (Write not allowed → expect a permission denial)
  - `claude -p "Now say DONE" --resume <session_id from success.jsonl> --output-format stream-json --verbose --model haiku > resume.jsonl`
- [ ] **Step 4:** Write `docs/notes/claude-stream-json.md`: the `type`/`subtype` of each line seen; where `session_id`, final `result` text, `is_error`, `total_cost_usd`, `num_turns` and `permission_denials` (field name and element shape) live; whether `--resume` keeps the same session id. **If any of these differ from Task 7's assumptions, edit Task 7 in this plan before continuing.**
- [ ] **Step 5:** Commit: `git add -A && git commit -m "Add package skeleton and claude stream-json fixtures"`

---

### Task 2: Flow graph model and validation

**Files:** Create `Sources/MetalFlowCore/Graph/Flow.swift`, `Graph/FlowValidation.swift`; Test `Tests/MetalFlowCoreTests/FlowValidationTests.swift`

**Interfaces:**
- Produces (all `public`, `Codable, Hashable, Sendable`):
  - `struct NodeID: RawRepresentable` (String), `ExpressibleByStringLiteral`
  - `struct Point { var x: Double; var y: Double }`
  - `struct Node { var id: NodeID; var title: String; var kind: NodeKind; var position: Point }`
  - `struct Wire { var from: NodeID; var to: NodeID; var input: String }` — `input` is the placeholder name in the target node
  - `enum NodeKind { case flowInput(FlowInputConfig); case repo; case prompt(PromptConfig); case shell(ShellConfig); case gate(ShellConfig); case judge(PromptConfig); case pick }`
  - `struct FlowInputConfig { var name: String; var source: InputSource }`, `enum InputSource { case githubIssue, text }`
  - `struct PromptConfig { var model: String; var prompt: String; var candidates: [String]; var allowedTools: [String]; var maxTurns: Int? }` — `candidates` is one model per lane; `count > 1` means fan-out; empty means a single run with `model`
  - `struct ShellConfig { var command: String }`
  - `struct Flow { var name: String; var nodes: [Node]; var wires: [Wire] }` with `func node(_ id: NodeID) -> Node?`, `func inputs(of: NodeID) -> [Wire]`
  - `enum FlowError: Error, Equatable { case cycle([NodeID]), danglingWire(Wire), duplicateNode(NodeID), duplicateInput(NodeID, String), nestedFanOut(NodeID), judgeWithoutFanOut(NodeID), unwiredPlaceholder(NodeID, String) }`
  - `extension Flow { func validate() throws(FlowError) -> FlowPlan }`
  - `struct FlowPlan { let order: [NodeID]; let fanOut: NodeID?; let laneScoped: Set<NodeID> }` — `laneScoped` = the fan-out node and its descendants that are not `.judge`/`.pick` nodes or descendants of one

- [ ] **Step 1: Failing tests** in `FlowValidationTests.swift`:
  - `orderRespectsWires`: a→b→c plus a→c gives `order.firstIndex(a) < b < c`.
  - `cycleIsRejected`: a→b→a throws `.cycle` containing a and b.
  - `danglingWireIsRejected`, `duplicateInputIsRejected` (two wires into b named "x").
  - `nestedFanOutIsRejected`: two prompt nodes with 3 candidates, second downstream of the first → `.nestedFanOut(second)`.
  - `laneScopeStopsAtJudge`: plan→impl(×3)→gate→judge→pick gives `laneScoped == [impl, gate]`, `fanOut == impl`.
  - `unwiredPlaceholderIsRejected`: prompt `"Fix {issue}"` with no wire named `issue` → `.unwiredPlaceholder(node, "issue")`. Judge nodes are exempt for `{candidates}` (filled by the engine).
  - `flowRoundTripsThroughJSON`: encode/decode a 3-node flow, `==`.
- [ ] **Step 2:** `swift test --no-parallel --filter FlowValidationTests` → FAIL (types missing).
- [ ] **Step 3:** Implement. Topological order by Kahn's algorithm with ties broken by node order in `nodes` (deterministic). Placeholders found with the same scanner Task 3's `Template` uses — put `Template.placeholders(in:) -> [String]` in `Graph/Template.swift` now (regex `\{([A-Za-z_][A-Za-z0-9_]*)\}`).
- [ ] **Step 4:** Tests → PASS.
- [ ] **Step 5:** Commit `"Add flow graph model and validation"`.

---

### Task 3: Flow files, templates and the Fix GitHub issue flow

**Files:** Modify `Graph/Template.swift`; Create `Graph/FlowFile.swift`, `Graph/BuiltinFlows.swift`; Test `TemplateTests.swift`, `FlowFileTests.swift`

**Interfaces:**
- Consumes: Task 2 types.
- Produces:
  - `enum Template { static func placeholders(in: String) -> [String]; static func fill(_ template: String, with values: [String: String]) -> String }` — unknown placeholders are left as-is; `{{` is a literal `{`.
  - `enum FlowFile { static func load(from url: URL) throws -> Flow; static func save(_ flow: Flow, to url: URL) throws; static let directoryName = ".flows" }` — pretty-printed, sorted keys, plus a top-level `"formatVersion": 1` wrapper (`{"formatVersion":1,"flow":{…}}`); unknown `formatVersion` throws.
  - `enum BuiltinFlows { static let fixGitHubIssue: Flow }`

- [ ] **Step 1: Failing tests:** `fillReplacesKnownAndKeepsUnknown` (`"A {x} {y}"`, `["x":"1"]` → `"A 1 {y}"`), `doubleBraceIsLiteral`, `saveThenLoadIsEqual` (temp dir), `unknownFormatVersionThrows`, `fixGitHubIssueValidates` (`try BuiltinFlows.fixGitHubIssue.validate()` succeeds, `fanOut == "implement"`, `laneScoped == ["implement","gate"]`).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. `fixGitHubIssue` exactly:
  - nodes (id · kind · config): `issue` · flowInput(name `issue`, githubIssue); `repo` · repo; `plan` · prompt(model `opus`, candidates `[]`, allowedTools `["Read","Grep","Glob"]`); `implement` · prompt(model `sonnet`, candidates `["sonnet","opus","haiku"]`, allowedTools `["Read","Edit","Write","Grep","Glob","Bash(swift build:*)","Bash(swift test:*)"]`); `gate` · gate(`swift test`); `judge` · judge(model `opus`, allowedTools `["Read"]`); `pick` · pick. Positions copied from `design/V1Studio.dc.html` node x/y.
  - wires: issue→plan(`issue`), repo→plan(`repo`), plan→implement(`plan`), issue→implement(`issue`), implement→gate(`code`), gate→judge(`results`), issue→judge(`issue`), judge→pick(`recommendation`).
  - prompts: plan — `"Read this GitHub issue and the code in this repository ({repo}), then write a short numbered plan to fix it. Do not edit files.\n\nIssue:\n{issue}"`; implement — the prompt in `design/V1Studio.dc.html` (`vs-prompt` textarea) verbatim; judge — `"You are judging candidate fixes for this issue. Prefer candidates whose tests pass, then the smallest correct diff. Explain briefly, then end with a final line `RECOMMEND: <lane>`.\n\nIssue:\n{issue}\n\nCandidates:\n{candidates}"`.
- [ ] **Step 4:** Run → PASS. **Step 5:** Commit `"Add flow files, templates and Fix GitHub issue flow"`.

---

### Task 4: Running external commands

**Files:** Create `Process/CommandRunner.swift`; Test `CommandRunnerTests.swift`; Create `Tests/MetalFlowCoreTests/Support/FakeCommandRunner.swift`

**Interfaces:**
- Produces:
  - `struct Command: Sendable, Hashable { var executable: String; var arguments: [String]; var workingDirectory: URL?; var environment: [String:String] = [:] }`
  - `struct CommandResult: Sendable { var exitCode: Int32; var stdout: String; var stderr: String; var succeeded: Bool { exitCode == 0 } }`
  - `enum CommandError: Error, Equatable { case executableNotFound(String), failed(Command, exitCode: Int32, stderr: String) }`
  - `protocol CommandRunner: Sendable { func run(_ c: Command) async throws -> CommandResult; func lines(_ c: Command) -> AsyncThrowingStream<String, Error> }` — `lines` yields stdout line by line and throws `.failed` on non-zero exit at the end.
  - `extension CommandRunner { func check(_ c: Command) async throws -> CommandResult }` — throws `.failed` on non-zero.
  - `struct ProcessRunner: CommandRunner { init(resolver: ExecutableResolver) }` — cancelling the consuming task terminates the process (SIGTERM, then SIGKILL after 5 s).
  - `actor ExecutableResolver { init(searchPath: [String]? = nil); func resolve(_ name: String) async throws -> URL }` — absolute names pass through; otherwise searches `searchPath`, defaulting to the login shell's PATH from `/bin/zsh -lic 'print -r -- $PATH'` (GUI apps don't inherit the shell PATH), cached.
  - Test support: `final class FakeCommandRunner: CommandRunner` (Mutex-guarded) with `func stub(_ executable: String, _ argsPrefix: [String], result: CommandResult)`, `func stubLines(_ executable: String, _ argsPrefix: [String], lines: [String], exitCode: Int32 = 0)`, `var calls: [Command]`.

- [ ] **Step 1: Failing tests** (real processes, all fast): `runCapturesStdoutAndExitCode` (`/bin/sh -c "echo hi; exit 3"` → stdout `"hi\n"`, exit 3), `linesStreamsEachLine` (`printf 'a\nb\n'` → `["a","b"]`), `linesThrowsOnFailure`, `missingExecutableThrows` (resolver with `searchPath: ["/nonexistent"]`, `run(Command(executable: "nope"…))` throws `.executableNotFound("nope")`), `cancellationTerminatesProcess` (start `sleep 30` via `lines`, cancel the task, `#expect` it finishes; it awaits completion, no sleeping in the test).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5:** Commit `"Add command runner"`.

---

### Task 5: Git worktrees, commits, diffs and merges

**Files:** Create `Git/Git.swift`, `Git/BranchNaming.swift`; Test `GitTests.swift`, `BranchNamingTests.swift`; Support `Tests/.../Support/TempRepo.swift` (makes a repo in a temp dir with one commit on `main`, `user.name`/`user.email` set locally).

**Interfaces:**
- Consumes: `CommandRunner` (tests use real `ProcessRunner`).
- Produces:
  - `enum BranchNaming { static func slug(_ title: String) -> String; static func runBranch(issue: Int?, title: String, existing: Set<String>) -> String; static func laneBranch(run: String, lane: String) -> String }` — slug: lowercase ASCII letters/digits, other runs → `-`, trimmed, ≤ 30 chars, empty → `run`. Collisions append `-2`, `-3`…
  - `enum MergeResult: Equatable, Sendable { case merged(commit: String), blockedDirty(checkout: URL), conflict(files: [String]) }`
  - `struct Git: Sendable { init(runner: CommandRunner) }` with:
    `currentBranch(repo: URL) async throws -> String`, `branches(repo:) -> Set<String>`, `addWorktree(repo:path:newBranch:from:)`, `removeWorktree(repo:path:)` (force), `deleteBranch(repo:name:)`, `commitAll(worktree:message:) -> Bool` (false when nothing to commit), `diff(worktree:base:) -> String`, `diffStat(worktree:base:) -> (added: Int, removed: Int)` (from `--numstat`), `isDirty(worktree:) -> Bool`, `checkout(of branch: String, repo:) -> URL?` (parses `git worktree list --porcelain`), `merge(repo:branch:into target:message:) -> MergeResult`.

- [ ] **Step 1: Failing tests** (`GitTests`, real git): `worktreeIsIsolatedFromCheckout` (add worktree on new branch, write a file there, `isDirty(repo) == false`), `commitAllReportsNothingToCommit`, `diffStatCountsLines`, `checkoutFindsMainRepo` (`checkout(of: "main") == repo`), `mergeWhenBaseNotCheckedOut` (base `release` not checked out anywhere → merged, temp worktree removed afterwards — `git worktree list` back to its original count). `BranchNamingTests.slugAndUniqueBranch`: `slug("Fix: crash / on ✨ empty graph!!")` → `"fix-crash-on-empty-graph"`; 200-char title → ≤ 30; `""` → `"run"`; `runBranch(issue: 42, title: "Undo", existing: ["flow/42-undo"])` → `"flow/42-undo-2"`; `laneBranch(run: "flow/42-undo", lane: "a")` → `"flow/42-undo--a"`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement `merge` exactly so:
  1. `if let co = checkout(of: target)`: if `isDirty(co)` → `.blockedDirty(co)`; else `git -C co merge --no-ff -m message branch`.
  2. Otherwise add a temp worktree on `target` under the system temp dir, merge there, always remove it.
  3. On non-zero merge exit: collect `git diff --name-only --diff-filter=U`, run `git merge --abort`, return `.conflict(files)`.
- [ ] **Step 4:** PASS. **Step 5:** Commit `"Add git worktree and merge support"`.
(Tests for blocked-dirty and conflict live in Task 10, against the engine.)

---

### Task 6: GitHub issues

**Files:** Create `GitHub/GitHubIssues.swift`; Test `GitHubIssuesTests.swift`

**Interfaces:**
- Produces: `struct Issue: Codable, Sendable, Equatable { var number: Int; var title: String; var body: String; var url: String; var labels: [String] }`; `struct GitHubIssues: Sendable { init(runner:); func fetch(_ ref: String, repo: URL) async throws -> Issue }` — `ref` is `"42"`, `"#42"` or an issue URL; runs `gh issue view <ref> --json number,title,body,url,labels` in `repo`; `labels` mapped from `[{name}]`. `Issue.promptText` → `"#<n> <title>\n\n<body>"`.
- [ ] **Step 1: Failing tests** with `FakeCommandRunner`: `fetchParsesJSON` (stubbed JSON → fields), `hashPrefixIsStripped` (`"#42"` called as `42`), `ghFailureSurfacesStderr` (exit 1, stderr `"could not resolve"` → `CommandError.failed` containing it).
- [ ] **Steps 2–5:** FAIL → implement → PASS → commit `"Add GitHub issue fetch"`.

---

### Task 7: Agent sessions over `claude -p`

**Files:** Create `Agent/AgentSession.swift`, `Agent/ClaudeStreamParser.swift`, `Agent/ClaudeCLI.swift`; Test `ClaudeStreamParserTests.swift`, `ClaudeCLITests.swift`; Support `FakeAgent.swift`

**Interfaces:**
- Produces:
  - `struct AgentRequest: Sendable, Equatable { var prompt: String; var workingDirectory: URL; var model: String; var allowedTools: [String]; var maxTurns: Int?; var resumeSessionID: String? }`
  - `struct AgentResult: Sendable, Equatable, Codable { var sessionID: String; var text: String; var isError: Bool; var deniedTools: [String]; var costUSD: Double; var turns: Int }` with `var question: String?` — the text after the last line starting `QUESTION:` (trimmed), else nil.
  - `enum AgentEvent: Sendable, Equatable { case started(sessionID: String), text(String), toolUse(name: String, summary: String), finished(AgentResult) }`
  - `protocol AgentSession: Sendable { func run(_ r: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> }`
  - `struct ClaudeStreamParser { mutating func parse(line: String) throws -> [AgentEvent] }` — ignores unknown types; malformed JSON throws.
  - `struct ClaudeCLI: AgentSession { init(runner: CommandRunner, executable: String = "claude") }` — args: `-p <prompt> --output-format stream-json --verbose --permission-mode default --model <model> --allowedTools <joined by ","> [--max-turns N] [--resume ID] --append-system-prompt <ClaudeCLI.questionConvention>`; `static let questionConvention = "You are running unattended inside MetalFlow. If you cannot continue without a decision from the user, stop and end your reply with one line starting QUESTION: followed by the question."`
  - Test support: `final class FakeAgent: AgentSession` scripted per request: `func script(_ match: @Sendable (AgentRequest) -> Bool, events: [AgentEvent])`, `var requests: [AgentRequest]`; an optional `gate: AsyncStream<Void>` so a test can hold a session open until it says go.
- Assumed stream-json mapping (confirm in Task 1): `system/init` → `.started(session_id)`; `assistant` message `content[]` items: `text` → `.text`, `tool_use` → `.toolUse(name, first 80 chars of input JSON)`; `result` → `.finished` with `session_id`, `result`, `is_error`, `total_cost_usd`, `num_turns`, `permission_denials[].tool_name`. Confirmed by Task 1 (docs/notes/claude-stream-json.md), plus: ignore `system` subtypes other than `init` and assistant `thinking` blocks; `tool_use.input` is a JSON object (serialize it for the summary). `--permission-mode default` is required: under the user's default `auto` mode `--allowedTools` does not deny anything.
- [ ] **Step 1: Failing tests:** `parsesSuccessFixture` (`success.jsonl` → first event `.started`, last `.finished` with `text` containing `OK`, `isError == false`), `parsesDeniedFixture` (`deniedTools` non-empty), `questionLineIsExtracted` (`"I looked.\nQUESTION: Squash or merge?"` → `"Squash or merge?"`; no line → nil), `cliBuildsArguments` (FakeCommandRunner records argv for a request with `maxTurns: 5`, `resumeSessionID: "s1"` — assert `--max-turns 5`, `--resume s1`, `--allowedTools Read,Edit`, working directory set).
- [ ] **Steps 2–5:** FAIL → implement → PASS → commit `"Add Claude Code agent sessions"`.

---

### Task 8: Run model and persistence

**Files:** Create `Run/Run.swift`, `Run/RunStore.swift`; Test `RunStoreTests.swift`

**Interfaces:**
- Produces (`Codable, Sendable, Equatable`):
  - `struct RunID: RawRepresentable, Hashable` (UUID string); `typealias LaneID = String` (`"a"`, `"b"`, …)
  - `struct NodeKey: Hashable, Codable { var node: NodeID; var lane: LaneID? }` — `description` `"implement@b"` / `"plan"`
  - `enum NodeState { case waiting, running, succeeded, failed(String), needsYou(NeedsYou), interrupted, cancelled }`
  - `enum NeedsYou { case question(String), deniedTools([String]), pickWinner(recommended: LaneID?, allGatesFailed: Bool) }`
  - `struct NodeRun { var state: NodeState; var output: String?; var sessionID: String?; var log: [String]; var pendingReply: String?; var extraAllowedTools: [String]; var costUSD: Double; var startedAt: Date?; var endedAt: Date? }` — `log` keeps the last 50 lines.
  - `struct Lane { var id: LaneID; var model: String; var branch: String; var worktree: URL; var gatePassed: Bool?; var added: Int; var removed: Int }`
  - `enum RunStatus { case running, needsYou, merged(LaneID), discarded, failed(String), cancelled }`
  - `struct Run: Identifiable { var id: RunID; var flow: Flow; var title: String; var repo: URL; var baseBranch: String; var branch: String; var worktree: URL; var inputs: [String:String]; var createdAt: Date; var status: RunStatus; var nodes: [NodeKey: NodeRun]; var lanes: [Lane]; var recommendation: LaneID? }` with `var needsYou: [(NodeKey, NeedsYou)]` (computed).
  - `struct RunStore: Sendable { init(root: URL); static var defaultRoot: URL; func save(_ run: Run) throws; func loadAll() throws -> [Run]; func delete(_ id: RunID) throws; func knownRepos() -> [URL]; func addKnownRepo(_ url: URL) throws; var worktreesDirectory: URL }` — one file `runs/<id>.json`, written atomically.
- [ ] **Step 1: Failing tests:** `saveAndLoadRoundTrip`, `loadMarksRunningAsInterrupted` (a node saved `.running` loads as `.interrupted`; run status `.running` loads as `.needsYou`), `knownReposAreDeduplicated`, `corruptRunFileIsSkipped` (garbage `runs/x.json` → `loadAll` returns the good runs and doesn't throw).
- [ ] **Steps 2–5:** FAIL → implement → PASS → commit `"Add run model and store"`.

---

### Task 9: RunEngine — launch and the execution pass

**Files:** Create `Run/SessionLimiter.swift`, `Run/RunEngine.swift`; Test `SessionLimiterTests.swift`, `RunEngineTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `actor SessionLimiter { init(max: Int); func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T }`
  - `actor RunEngine { init(store: RunStore, runner: CommandRunner, agent: AgentSession, issues: GitHubIssues, maxSessions: Int = 4); nonisolated let updates: AsyncStream<Run>; func restore() throws -> [Run]; func launch(flow: Flow, repo: URL, input: String) async throws -> RunID; func run(_ id: RunID) -> Run?; func cancel(_ id: RunID) }`
- Execution pass `execute(_ id:)` (private; at most one live pass per run, a request during a pass sets `rerunRequested`, and the pass loops once more when it ends):

```
plan = run.flow.validate()
for node in plan.order where node ∉ plan.laneScoped:
    if node == first laneScoped node's turn: run all lanes concurrently (TaskGroup);
        each lane runs plan.laneScoped nodes in order, keyed NodeKey(node, lane)
    else run NodeKey(node, nil)
    skip any key already .succeeded; stop the pass (status .needsYou) when any key is .needsYou after its group finishes
judge runs only when every lane has finished (succeeded or failed)
```

  Per kind:
  - `flowInput` githubIssue → `issues.fetch`; output `Issue.promptText`; also sets `run.title` `"#<n> <title>"`. `text` → the raw input.
  - `repo` → output = repo path.
  - `prompt` → wait for a slot, fill the template from wired inputs' outputs, run the agent in the lane's worktree (or the run worktree); append text/tool events to `log`; on finish: `isError` → `.failed(text)`; `deniedTools` non-empty → `.needsYou(.deniedTools)`; `question` → `.needsYou(.question)`; else `.succeeded`, output = text. In a lane, then `git.commitAll(message: "<node title> (<lane>)")`. A resumed node sends `pendingReply` as the prompt with `resumeSessionID` and allowedTools + `extraAllowedTools`.
  - Fan-out: before the lanes run, `commitAll` the run worktree, then create one worktree per candidate model at `worktreesDirectory/<runID>/<lane>` on `laneBranch` from the run branch. Lanes are `a`, `b`, `c`… in `candidates` order.
  - `shell` / `gate` → run `/bin/zsh -lc <command>` in the worktree; output = `"exit <code>\n" +` last 40 lines. Gate sets `lane.gatePassed`; a failing gate is `.succeeded` for the node (the lane is marked, not dropped). After a gate, refresh `added`/`removed` from `diffStat` against the run branch.
  - `judge` → `{candidates}` = for each lane: `"## <lane> (<model>) — tests passed|failed, +A −R\n<diff, truncated to 400 lines>"`; parse `RECOMMEND: <lane>` from the last such line → `run.recommendation` (nil if missing or unknown).
  - `pick` → `.needsYou(.pickWinner(recommended:, allGatesFailed:))`; the pass ends; the run's status is `.needsYou`.
  - Launch: create the run branch from `currentBranch(repo)` via `BranchNaming.runBranch`, add the worktree at `worktreesDirectory/<runID>/run`, `store.addKnownRepo`, save, start the pass; return immediately.
  - Every state change: `store.save(run)` and `updates.yield(run)`.
- [ ] **Step 1: Failing tests** (`RunEngineTests`, real git via `TempRepo`, `FakeAgent`, `FakeCommandRunner` only for `gh` — use a `CommandRunner` that routes `gh` to the fake and everything else to `ProcessRunner`; put it in Support as `RoutingRunner`). Gate command in test flows: `test -f ok.txt` (FakeAgent's implement script writes `ok.txt` for lanes a and b only — the fake receives the worktree path in the request):
  - `fixIssueRunsToPickWinner`: the run ends with `status == .needsYou`, pick node `.needsYou(.pickWinner(recommended: "b", allGatesFailed: false))` (judge fake returns `RECOMMEND: b`), `lanes.map(\.gatePassed) == [true, true, false]`, three lane branches exist, the user's checkout `isDirty == false`.
  - `placeholdersReachPrompts`: the implement requests contain the plan's output text and the issue title.
  - `questionPausesOnlyThatLane`: lane b's fake ends with `QUESTION: Keep the API?` → `implement@b` is `.needsYou(.question("Keep the API?"))`, lanes a and c gates have run, judge has not.
  - `agentErrorFailsLaneNotRun`: lane c `isError` → `implement@c` `.failed`, judge still runs over a and b.
  - `limiterCapsConcurrentSessions` (`SessionLimiterTests`): with `max: 2`, five bodies that each await a shared gate; assert at most 2 enter before the gate opens.
  - `cancelStopsRun`: cancel while a fake session is held → `status == .cancelled`, running node `.cancelled`.
- [ ] **Steps 2–5:** FAIL → implement → PASS (`swift test --no-parallel`) → commit `"Add run engine execution"`.

---

### Task 10: Answering, resuming, picking and cleanup

**Files:** Create `Run/RunEngine+Decide.swift`; Modify `Run/RunEngine.swift`; Test `RunEngineDecideTests.swift`

**Interfaces:**
- Produces on `RunEngine`:
  - `func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String] = []) throws` — the node must be `.needsYou(.question|.deniedTools)` or `.interrupted`; sets `pendingReply`, appends `allowTools` to `extraAllowedTools`, state `.waiting`, requests a pass.
  - `func resumeInterrupted(_ id: RunID) throws` — `answer(reply: "Continue where you left off.")` for each `.interrupted` node.
  - `func pick(_ id: RunID, lane: LaneID) async throws -> MergeResult` — `git.merge(repo:, branch: lane.branch, into: run.baseBranch, message: "Merge <run.title> (candidate <lane>, MetalFlow)")`; on `.merged` → status `.merged(lane)`, pick node `.succeeded`, then `cleanup`; otherwise the run is unchanged (still Needs-you) and the result is returned for the UI to show.
  - `func discard(_ id: RunID) async throws` → status `.discarded`, cleanup.
  - `func branchFromHere(_ id: RunID, lane: LaneID, name: String) async throws` — creates local branch `name` at the lane branch's head; that lane's worktree is excluded from cleanup until the run is discarded or merged, when the worktree is removed but `name` stays.
  - `cleanup` (private): remove every lane and run worktree for the run, delete the run and lane branches (keep `branchFromHere` names), `git worktree prune`.
- [ ] **Step 1: Failing tests:**
  - `answerResumesSameSession`: after `questionPausesOnlyThatLane`'s state, `answer(…, reply: "Yes")` → FakeAgent receives a request with `resumeSessionID` = lane b's session and `prompt == "Yes"`; the run proceeds to pick.
  - `deniedToolsAnswerAddsTools`: `answer(…, allowTools: ["Bash(make:*)"])` → resumed request's `allowedTools` contains it.
  - `pickMergesAndCleansUp`: `pick(lane: "b")` → `.merged`, `git log main` has a merge commit whose second parent is lane b's head, no `flow/*` branches left, `worktreesDirectory/<runID>` gone.
  - `pickBlockedWhenBaseCheckoutDirty`: user writes an untracked change in the main checkout → `.blockedDirty(repo)`, `main` head unchanged, run still `.needsYou`, lane worktrees still exist.
  - `pickConflictAborts`: user commits a conflicting change to the same file on `main` after launch → `.conflict(files: ["ok.txt"])`, `main` head unchanged, `git status` in the checkout clean (no merge in progress).
  - `resumeInterruptedSkipsFinishedNodes`: save a run with `plan` `.succeeded` and `implement@a` `.interrupted`, build a fresh engine on the same store, `restore()`, `resumeInterrupted` → FakeAgent got no plan request, and one request for `implement@a` with its stored session id.
  - `branchFromHereSurvivesDiscard`: branch `try-c` from lane c, `discard` → `try-c` exists, all `flow/*` branches gone.
- [ ] **Steps 2–5:** FAIL → implement → PASS → commit `"Add answer, resume, pick and cleanup"`.

---

### Task 11: `mflow` CLI and an end-to-end check

**Files:** Modify `Sources/mflow/main.swift`; Create `Sources/mflow/Commands.swift`; Modify `Package.swift` (mflow depends on MetalFlowCore)

**Interfaces:**
- Consumes: `RunEngine`, `RunStore`, `FlowFile`, `BuiltinFlows`, `ClaudeCLI`, `ProcessRunner`, `GitHubIssues`.
- Produces (hand-parsed args, no new dependencies):
  - `mflow init-flow [--repo .]` → writes `.flows/fix-issue.flow` from `BuiltinFlows.fixGitHubIssue` (refuses to overwrite).
  - `mflow launch <issue> [--repo .] [--flow .flows/fix-issue.flow]` → prints the run id, then streams one line per update (`<nodeKey> <state>` changes only) until the run leaves `.running`.
  - `mflow list` → `id  status  title` for every stored run, newest first.
  - `mflow show <id>` → nodes with state, needs-you items, lanes with gate result and +/−, recommendation.
  - `mflow answer <id> <nodeKey> <reply...> [--allow Tool]...`, `mflow resume <id>`, `mflow pick <id> <lane>` (prints the `MergeResult` in words; exit 1 when not merged), `mflow discard <id>`, `mflow branch <id> <lane> <name>`.
  - Unknown command / bad args → usage on stderr, exit 64.
- [ ] **Step 1:** Implement; `swift build` succeeds; `swift run mflow` prints usage and exits 64.
- [ ] **Step 2: End-to-end check (manual, real tools; costs a few Claude runs).** In a scratch clone of a small Swift repo with an open issue the user names (ask them which repo and issue; don't pick one), run `mflow init-flow`, `mflow launch <n>`; expected: plan, three lanes and judge complete and the run ends `needsYou` with a recommendation; `mflow show` lists three lanes; `mflow pick <id> <lane>` merges into the base branch; `git worktree list` shows only the checkout. Record what happened (including any failure) in `docs/notes/e2e-<date>.md`.
- [ ] **Step 3:** Full suite `swift test --no-parallel` → all PASS.
- [ ] **Step 4:** Commit `"Add mflow CLI"`.

---

## After this plan

Plan 2 (written when this lands, against the real API above): MetalUI app target — app shell with Dashboard / Flow Studio navigation; Dashboard (launch bar, Needs-you, Working-on, Running, Finished, activity); Flow Studio (canvas from MetalUI's `CanvasDemo`, bezier wires, palette, inspector, full editing with undo, run overlay, candidates strip, diff view); `UNUserNotificationCenter` notifications; the `.app` bundle script; quit confirmation while runs are active.
