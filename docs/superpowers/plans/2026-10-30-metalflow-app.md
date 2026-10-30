# MetalFlow App (Plan 2 of 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the MetalFlow macOS app on MetalUI: a Dashboard for managing many runs and a Flow Studio for building flows and picking results. It sits on the finished `MetalFlowCore` engine and closes the v1 loop end to end in a window: open or build a flow, launch it with an issue, watch it alongside other runs, get notified, compare candidates, then pick and merge.

**Architecture:** A new `MetalFlowKit` library holds all UI and app state. An executable target `MetalFlow` holds only `main.swift`. `AppModel` (an `@Observable @MainActor` class) is the single source of UI state. It talks to the engine through an `EngineClient` protocol, so UI tests use a scripted fake instead of git and Claude. Engine updates flow in through one `.task` on the root view. Canvas maths (transform, ports, wires, hit tests) lives in a pure `CanvasGeometry` type with plain unit tests. Views are thin.

**Tech Stack:** Swift 6.4, SwiftPM, MetalUI (path dependency `../MetalUI`), MetalUITesting, Swift Testing, `MetalFlowCore`. On macOS, AppKit/UserNotifications are used only behind the `Notifier` protocol, and only until MetalUI ships an API for them.

**Spec:** `docs/superpowers/specs/2026-10-30-metalflow-v1-design.md`. Mockups: `design/V1Dashboard.dc.html`, `design/V1Studio.dc.html`. MetalUI API facts: `docs/notes/metalui-api.md` (written in Task 1).

## Global Constraints

- MetalUI app conventions:
  - Kit library + thin executable + tests, as in `MetalUI/Examples/Jotter`.
  - `swiftLanguageModes: [.v6]`, `platforms: [.macOS(.v14)]`.
  - UI types are `@MainActor`.
  - `openWindow`'s `content` returns exactly one Element and is re-run every frame. Keep it cheap and keep work out of it.
- UI tests use `MetalUITesting` (`TestWindow`, `tick()`, `advance(by:)`, `runUntilIdle()`, element queries by `.accessibilityIdentifier`).
  - Tests never sleep, never run real `claude`/`gh`/`git`, and never touch the real Application Support.
- **Never steal focus.** Nothing calls window activation or ordering except in direct response to a user click: a notification click or a menu item.
- **Never auto-merge.** Only an explicit Pick & merge click calls `pick`.
- Dark theme only for v1, with colours taken from the mockups:

  | Token | Value |
  |---|---|
  | ground | `#111316` |
  | panel | `#14161a` |
  | chrome | `#0d0f12` |
  | line | `#23272e` |
  | text | `#e6e8eb` |
  | muted | `#9aa1ab` |
  | accent | `#5aa9ff` |
  | warn | `#f0a35e` |
  | ok | `#56d364` |
  | bad | `#ff7b72` |

  Use `Color(Hsla.rgb(0x...))`. Inter is not bundled: use the system font, and `Font.monospaced()` / `.font(family: "Menlo", size:)` for code.
- Every interactive element gets an `.accessibilityIdentifier`. Tests find elements by identifier, never by coordinates alone.
- MetalUI gaps:
  - Requested from the MetalUI session (2026-10-30): split panes, notifications + Dock badge, window activation, `.app` bundling, public `Color(hex:)`.
  - Until they land, use the fallbacks named in each task.
  - Never patch MetalUI from this repo.
  - New gaps found during implementation are reported to the controller, who forwards them.
- Public declarations get `///` doc comments.

## Review Focus

1. **Many runs at once** (10+ running, frequent log updates) must keep the Dashboard responsive. `AppModel.apply` is O(1) per update, and views don't rebuild every run per update. Test: Task 2's `applyManyUpdatesIsCheap` counts work, not time.
2. **Relaunch with interrupted runs** shows them in Needs-you with a Resume action, and never auto-resumes. Test: Task 2's `restoredInterruptedRunsNeedYou`.
3. **Pick blocked (dirty checkout / conflict)** shows the reason inline on the candidate card and leaves the run in Needs-you. Test: Task 4's `pickBlockedShowsReason`.
4. **Editing a flow that has a run open** never mutates that run's snapshot. Runs keep `run.flow`, and the Studio edits a separate draft. Test: Task 6's `editingDraftDoesNotChangeShownRun`.
5. **Invalid graph** (a cycle from a bad wire, an unwired placeholder) is refused at save and launch with the validation message shown. The draft is never lost. Test: Task 6's `invalidDraftCannotSaveOrLaunch`.

---

## File Structure

```
Package.swift                                   + MetalUI dep, MetalFlowKit, MetalFlow exe, MetalFlowKitTests
Sources/MetalFlowCore/Run/RunEngine+Retry.swift  retry(node)                                   (Task 1)
Sources/MetalFlowKit/
  App/EngineClient.swift      protocol + LiveEngineClient (wraps RunEngine)
  App/AppModel.swift          @Observable state: runs, selection, screen, activity, drafts, notices
  App/Activity.swift          ActivityItem ring buffer derivation from Run diffs
  App/Theme.swift             colour tokens, fonts, spacing
  App/RootView.swift          window root: top bar + Dashboard | Studio switch + updates .task
  App/Commands.swift          menu commands
  App/Notifier.swift          Notifier protocol, UserNotificationsNotifier, NoopNotifier
  Dashboard/DashboardView.swift, LaunchBar.swift, NeedsYouSection.swift, RunCard.swift, StepPills.swift, FinishedList.swift, ActivityFeed.swift
  RunDetail/RunDetailView.swift, CandidateCard.swift, DiffView.swift, AnswerBox.swift
  Studio/StudioView.swift, CanvasGeometry.swift, CanvasView.swift, NodeCardView.swift, WireLayer.swift, PaletteView.swift, InspectorView.swift, FlowDraft.swift
Sources/MetalFlow/main.swift
Tests/MetalFlowKitTests/ Support/FakeEngineClient.swift, Support/Windows.swift, <one file per area>
scripts/bundle.sh, packaging/Info.plist
docs/notes/metalui-api.md
```

---

### Task 1: Engine additions the app needs

**Files:** Create `Sources/MetalFlowCore/Run/RunEngine+Retry.swift`. Modify `Run/RunEngine.swift`. Test `RunEngineRetryTests.swift`, `RunEngineLockReloadTests.swift`. Create `docs/notes/metalui-api.md`: copy the controller-provided MetalUI facts file verbatim (see the dispatch).

**Interfaces (Produces):**
- `RunEngine.retry(_ id: RunID, node: NodeKey) async throws`.
  - Allowed when that node is `.failed` and the run is `.needsYou`, `.failed` or `.completed`. Otherwise throws `RunEngineError.notRetryable(NodeKey)`.
  - Resets the node to `.waiting`, keeping `sessionID` and `pendingReply` (a resume with the pending reply if present, otherwise a fresh templated run).
  - For a lane node, also resets that lane's later lane nodes that never ran.
  - Sets the status to `.running` and requests a pass.
- Lock reload: when an engine acquires a run's lock (`ensureLock` / pass start), it first reloads that run from disk via a new `RunStore.load(_ id: RunID) throws -> Run?` (skip mapping), so it never acts on a stale snapshot.
- `RunEngine.flows(in repo: URL) -> [URL]`: the `.flow` files under `<repo>/.flows`, sorted.

- [ ] **Step 1: Failing tests.**
  - `retryFailedLaneReRunsIt`: lane c's implement fails, retry `implement@c`, lane c reaches gate. The judge then runs once over all three lanes. This works because the run was `.needsYou` at pick and the judge/pick re-run when a lane changed. The rule: retrying a lane node resets the judge and pick nodes to `.waiting` too.
  - `retryRejectsNonFailedNode`.
  - `lockAcquisitionReloadsRunFromDisk`: engine B restores while A holds the lock. A finishes and writes. B answers and sees A's latest state, not its stale copy.
  - `flowsListsDotFlowsFiles`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Full core suite → PASS. **Step 5:** Commit `"Add retry, lock reload and flow listing for the app"`.

---

### Task 2: App skeleton, EngineClient, AppModel

**Files:**
- Modify `Package.swift`:
  - Add `.package(name: "MetalUI", path: "../MetalUI", traits: [.defaults])`.
  - Target `MetalFlowKit` depends on `MetalUI` and `MetalFlowCore`.
  - Executable `MetalFlow` depends on `MetalFlowKit`, `MetalUI`, `MetalUIPortableText`, `MetalUISystemFonts`. Copy the Jotter manifest pattern exactly, including the comment about why the text products are unconditional.
  - Test target `MetalFlowKitTests` depends on `MetalFlowKit`, `MetalUI`, `MetalUITesting`, `MetalUIPortableText`, `MetalUISystemFonts`.
- Create `App/EngineClient.swift`, `App/AppModel.swift`, `App/Activity.swift`, `App/Theme.swift`, `App/RootView.swift`, `Sources/MetalFlow/main.swift`.
- Test: `AppModelTests.swift`, `RootViewTests.swift`, `Support/FakeEngineClient.swift`, `Support/Windows.swift`.

**Interfaces (Produces):**
- `protocol EngineClient: Sendable`:
  - `updates: AsyncStream<Run> { get }`
  - `restore() async throws -> [Run]`
  - `launch(flow: Flow, repo: URL, input: String) async throws -> RunID`
  - `answer(_:node:reply:allowTools:) async throws`
  - `resumeInterrupted(_:) async throws`
  - `retry(_:node:) async throws`
  - `cancel(_:) async`
  - `pick(_:lane:) async throws -> MergeResult`
  - `discard(_:) async throws`
  - `branchFromHere(_:lane:name:) async throws`
  - `knownRepos() -> [URL]`
  - `flows(in:) -> [URL]`
  - `loadFlow(_ url: URL) throws -> Flow`
  - `saveFlow(_:to:) throws`
  - `diff(_ id: RunID, lane: LaneID) async -> String`. This needs a small public `RunEngine.laneDiff(_:lane:) async -> String`; add it in this task with a test.
- `LiveEngineClient(engine: RunEngine, store: RunStore)` implements it. Wire it exactly like `mflow`'s `main.swift`: resolver, ProcessRunner, ClaudeCLI, GitHubIssues, RunStore, PATH shellEnvironment. `METALFLOW_HOME` overrides the root.
- `@Observable @MainActor final class AppModel`:
  - `init(client: EngineClient, notifier: Notifier)`
  - `var runs: [RunID: Run]`
  - `var order: [RunID]` (newest first)
  - `var screen: Screen` (`.dashboard`, `.studio`)
  - `var selectedRun: RunID?`
  - `var activity: [ActivityItem]` (ring buffer of 200)
  - `var workingOn: [WorkingItem]` (`.flow(URL)`, `.run(RunID)`; added when opened, removed on dismiss)
  - `var notice: Notice?` (inline error/info banner text)
  - `func start() async`: restore, then consume `updates` forever, skipping any snapshot whose `revision` is ≤ the stored one
  - `func apply(_ run: Run)`
  - Derived lists: `needsYou`, `running`, `finished`. These are cached arrays updated in `apply`, not recomputed in views.
  - Action methods that call the client and turn errors into `notice` (`error.localizedDescription`): `launch`, `answer`, `resume`, `retry`, `cancel`, `pick`, `discard`, `branchFromHere`.
- `ActivityItem { time: Date; runID: RunID; runTitle: String; text: String; kind: .info/.needsYou/.ok/.bad }`. It is derived in `apply` by diffing old and new node states and status. Examples: "judge recommends b — waiting on you", "gate failed on 3 candidates", "edited Foo.swift" (from the last log line of a running node).
- `RootView(model:)`:
  - Top bar with app name, a Dashboard | Flow Studio segmented Picker (id `nav`), and a "N running · M need you" counter.
  - Body switches on `screen`.
  - `.task { await model.start() }`.
- `main.swift` follows Jotter: build `AppModel(client: LiveEngineClient(...), notifier: NoopNotifier())`, `openWindow(title: "MetalFlow", size: 1440×900, minSize: 1000×640)`, `app.run()`.
- Test support:
  - `FakeEngineClient` is an actor. It holds scripted runs, records calls, and exposes `send(_ run:)` to push updates.
  - `Windows.swift` has `appWindow(model:) -> TestWindow` and `settled(window)`, as in Jotter's Support.swift.

- [ ] **Step 1: Failing tests.**
  - `applyBucketsRunsByStatus`.
  - `staleRevisionIsIgnored`.
  - `restoredInterruptedRunsNeedYou` (Review Focus 2).
  - `activityRecordsNeedsYouAndGateFailures`.
  - `applyManyUpdatesIsCheap` (Review Focus 1): 20 runs × 200 updates. Assert `apply` touched only the updated run's bucket entries by counting rebuilds through an internal counter. Do not measure time.
  - `actionErrorsBecomeNotice`.
  - `rootShowsDashboardAndSwitchesToStudio` (TestWindow: click `nav` segment, assert the `studio` identifier exists).
- [ ] **Steps 2–5:** FAIL → implement → `swift build --product MetalFlow` succeeds and the full suite passes → commit `"Add MetalFlow app skeleton and app model"`.

---

### Task 3: Dashboard

**Files:** Create `Dashboard/*.swift`. Test `DashboardTests.swift`.

**Interfaces:**
- `DashboardView(model:)` has a vertical ScrollView main column and the `ActivityFeed` on the right (fixed 320 pt, `Divider` between). Sections in order, as in `design/V1Dashboard.dc.html`:
  - `LaunchBar` (ids `launch.flow`, `launch.issue`, `launch.repo`, `launch.go`):
    - Repo Picker over `knownRepos`, plus an "Add repo…" TextField that takes a path.
    - Flow Picker over `flows(in: repo)`.
    - Issue TextField.
    - Launch is disabled until all three are set. Launching clears the issue field.
  - `NeedsYouSection`: a card per needs-you item (id `needs.<runID>.<nodeKey>`):
    - pickWinner → "Compare & pick" (opens run detail)
    - question → inline `AnswerBox`
    - interrupted → "Resume"
    - failed node → "Retry"
    - plus "Open run" on every card
  - Working on: chips (id `working.<…>`), each with Open and a dismiss ×.
  - Running: an adaptive grid (min 300) of `RunCard`s. Each shows the title, flow name, branch, elapsed time, `StepPills` (one pill per flow node in plan order with lanes collapsed, coloured done/run/wait/fail as in the mockup), the latest log line in monospace, and Cancel.
  - `FinishedList`: merged/discarded/completed/failed/cancelled, newest first, max 20.
  - `ActivityFeed`: from `model.activity`.
- Elapsed time uses `TimelineView` (or a 1 s `.task` tick). Tests drive it with `advance(by:)`.
- [ ] **Step 1: Failing tests** (TestWindow + FakeEngineClient):
  - `launchBarLaunchesWithSelections`: the fake records `launch(flow, repo, "42")`.
  - `needsYouCardsAppearPerKind` (one each of pick/question/interrupted/failed).
  - `answerFromDashboardCallsClient`.
  - `runningCardShowsStepPillsAndLastLog`.
  - `cancelFromRunCard`.
  - `finishedListsMergedRuns`.
- [ ] **Steps 2–5:** FAIL → implement → PASS → commit `"Add Dashboard"`.

---

### Task 4: Run detail, candidates, diff

**Files:** Create `RunDetail/*.swift`. Test `RunDetailTests.swift`, `DiffViewTests.swift`.

**Interfaces:**
- `RunDetailView(model:, run: RunID)` opens as the main area when `selectedRun` is set; it has a Back button (id `detail.back`). It shows:
  - the node list with states
  - needs-you actions
  - the judge output
  - the **candidates strip**: one `CandidateCard` per lane (id `cand.<lane>`) showing model, tests passed/failed/no gate, +/−, branch, a "JUDGE RECOMMENDS" tag, and buttons Pick & merge (`cand.<lane>.pick`, accent on the recommended lane), View diff (`cand.<lane>.diff`), Branch from here (`cand.<lane>.branch`, shows a name TextField + OK)
  - a run-level Discard (`detail.discard`), behind a confirmation `.alert`
- Pick results are shown inline on that card (id `cand.<lane>.result`):
  - `.merged` → the detail shows "Merged" and returns to the dashboard
  - `.blockedDirty(url)` → "Your checkout at <path> has uncommitted changes — commit or stash, then pick again."
  - `.conflict(files)` → "Conflicts in: a, b — nothing was merged."
  - thrown error → its description
- `DiffView(text: String)` renders a unified diff as one `Text(AttributedString)` per hunk, inside a vertical ScrollView with a monospace font. Lines are coloured: `+` ok on a translucent green background, `-` bad on translucent red, `@@` muted. Show at most 2000 lines, then "… N more lines".
- `diffAttributed(_ text: String) -> [AttributedString]` is a pure function, so it can be unit tested.
- [ ] **Step 1: Failing tests:**
  - `candidatesShowRecommendation`.
  - `pickCallsClientOnlyOnClick`: no pick call happens until the click.
  - `pickBlockedShowsReason` (Review Focus 3).
  - `conflictShowsFiles`.
  - `branchFromHereAsksForName`.
  - `discardNeedsConfirmation`.
  - `diffAttributedColoursLines`.
  - `diffTruncatesLongOutput`.
- [ ] **Steps 2–5:** FAIL → implement → PASS → commit `"Add run detail and candidate comparison"`.

---

### Task 5: Flow Studio canvas (view and navigate)

**Files:** Create `Studio/CanvasGeometry.swift`, `CanvasView.swift`, `NodeCardView.swift`, `WireLayer.swift`, `StudioView.swift`, `FlowDraft.swift`. Test `CanvasGeometryTests.swift`, `StudioViewTests.swift`.

**Interfaces:**
- `struct CanvasGeometry: Equatable`:
  - Properties `pan: Point<Pixels>`, `zoom: Double` (clamped 0.25…4).
  - `toScreen(_ p: Point) -> Point<Pixels>`, `toCanvas(_ p: Point<Pixels>) -> Point`.
  - `zoom(to:about:)`: the point under the cursor stays fixed, using CanvasDemo's formula.
  - `nodeRect(_ n: Node) -> Rect`: node size 200×(140, or 120 for input/repo/pick nodes).
  - `outPort(_ n:)` (right middle) and `inPort(_ n:)` (left middle).
  - `wirePath(from:to:) -> (Point, Point, Point, Point)`: a cubic with control points at the horizontal midpoint, as in the mockup.
  - `hitNode(at canvas: Point, in flow: Flow) -> NodeID?` (topmost).
  - `hitPort(at:in:) -> (NodeID, PortSide)?` (8 pt radius).
  - `fit(_ flow: Flow, in size: Size<Pixels>) -> CanvasGeometry`.
- `FlowDraft` (`@Observable @MainActor`):
  - Properties `flow: Flow`, `url: URL?`, `repo: URL`, `isDirty`, `validation: Result<FlowPlan, FlowError>` (recomputed on each change), `undoStack`/`redoStack: [Flow]` (capped at 100).
  - `func edit(_ name: String, _ change: (inout Flow) -> Void)` pushes undo. `undo()`, `redo()`.
- `StudioView(model:)` layout, as in `design/V1Studio.dc.html`:
  - a toolbar with flow name, file, a run picker ("Definition only" or a run of this flow), Save (⌘S), and Launch with issue…
  - Palette (200 pt) | Canvas | Inspector (320 pt). Use fixed widths with `Divider`s until MetalUI split panes land.
  - a candidates strip under the canvas when a run is shown (reuses `CandidateCard`)
- `CanvasView`:
  - a `ZStack(alignment: .topLeading)` with a dotted grid: one `Path` of dots, only the visible ones, spacing 20 × zoom doubled until ≥ 12 pt.
  - `WireLayer`: one `Path` holding every wire, stroked muted. Wires touching the selected node are accented.
  - `NodeCardView`s placed with `.offset`.
  - pan by middle/secondary drag or the wheel; zoom with ⌘-wheel or pinch; click to select (CanvasDemo patterns).
  - A Fit button and a zoom % readout.
  - With a run shown, each node card shows that run's node state and status line. Lane nodes show "A ✓ B ✓ C ✕".
- [ ] **Step 1: Failing tests:**
  - CanvasGeometry: `roundTripScreenCanvas`, `zoomAboutPointKeepsItFixed`, `zoomClamps`, `hitNodeTopmostWins`, `hitPortRadius`, `fitContainsAllNodes`.
  - Studio: `studioShowsBuiltinFlowNodes` (identifier per node `node.<id>`), `clickSelectsNode`, `runOverlayShowsLaneStates`.
- [ ] **Steps 2–5:** FAIL → implement → PASS → commit `"Add Flow Studio canvas"`.

---

### Task 6: Flow Studio editing

**Files:** Create `Studio/PaletteView.swift`, `Studio/InspectorView.swift`. Modify `CanvasView.swift` and `FlowDraft.swift`. Test `FlowEditingTests.swift`.

**Interfaces:**
- Palette groups:
  - Inputs: Flow input, Repo
  - Steps: Prompt, Shell
  - Checks: Gate
  - Decide: Judge, You pick
- Clicking a palette item adds a node at the canvas centre with a unique id (`<kind><n>`, valid per `[A-Za-z0-9_-]+`) and selects it.
- Drag a node (primary drag on the node) to move it. Commit position on drag end as one undo step.
- Drag from an out-port to an in-port to create a wire. The wire's input name defaults to the source node id; edit it in the inspector.
- Delete or Backspace with a selection removes the node and its wires, or the selected wire.
- ⌘Z / ⇧⌘Z undo/redo.
- Inspector per kind:
  - title, id (read-only)
  - Prompt/Judge: model Picker (opus/sonnet/haiku), candidates Stepper 1…6 with per-candidate model pickers, prompt `TextEditor` (Menlo 12), allowed tools (one per line in a TextEditor), max turns
  - Shell/Gate: command TextField
  - Flow input: name, source Picker
  - Incoming wires, each with an editable input name
- Validation:
  - `draft.validation` errors show as a red banner (`studio.validation`) using `FlowError.errorDescription`.
  - Save and Launch are disabled while invalid.
  - Saving writes with `FlowFile.save`, clears `isDirty`, and adds the flow to Working on.
  - Opening another flow while dirty asks to Save, Discard or Cancel (`.alert`).
- The shown run's `run.flow` is never mutated (Review Focus 4). The draft is a copy made when the flow file is opened.
- [ ] **Step 1: Failing tests:**
  - `addNodeFromPalette`.
  - `dragNodeMovesAndUndoes`.
  - `connectPortsAddsWire`.
  - `deleteRemovesNodeAndWires`.
  - `inspectorEditsPrompt`.
  - `invalidDraftCannotSaveOrLaunch` (Review Focus 5).
  - `editingDraftDoesNotChangeShownRun` (Review Focus 4).
  - `saveWritesFlowFile` (temp dir via the fake client's `saveFlow`).
  - `dirtySwitchAsks`.
- [ ] **Steps 2–5:** FAIL → implement → PASS → commit `"Add Flow Studio editing"`.

---

### Task 7: Notifications, menus, quit, packaging

**Files:** Create `App/Notifier.swift`, `App/Commands.swift`, `scripts/bundle.sh`, `packaging/Info.plist`. Modify `main.swift`, `AppModel.swift`. Test `NotifierTests.swift`, `CommandTests.swift`.

**Interfaces:**
- `protocol Notifier: Sendable`:
  - `requestAuthorization() async`
  - `post(id: String, title: String, body: String) async`
  - `remove(id: String) async`
  - `setBadge(_ count: Int) async`
  - `var clicks: AsyncStream<String> { get }`
- Implementations:
  - `NoopNotifier`.
  - `RecordingNotifier` (tests).
  - `UserNotificationsNotifier`. If MetalUI has shipped its notification API by now, wrap that. Otherwise use `UNUserNotificationCenter` directly, guarded by `Bundle.main.bundleIdentifier != nil` (else it acts as Noop). Plus `NSApp.dockTile.badgeLabel` for the badge.
- `AppModel` posts when a run newly enters needs-you:
  - id `<runID>`
  - title = run title
  - body = "Judge recommends b — pick a candidate" / "<node> asks: <question>" / "Gate failed on every candidate" / "Interrupted — resume when ready"
  - It removes the notification when the run leaves needs-you.
  - Badge = the needs-you count.
  - It never posts for a run whose detail is currently open, and never activates the window itself.
  - A notification click opens that run's detail. Bringing the window forward on a click is allowed; use MetalUI's activation API if available, otherwise `NSApp.activate()`.
- Commands:
  - File: New Flow (⌘N), Open Flow… (⌘O via a repo/flow picker sheet), Save (⌘S)
  - Run: Launch… (⌘L, focuses `launch.issue`), Go to Dashboard (⌘1), Go to Studio (⌘2)
- Quit: when any run is `.running`, `app.onTerminateRequest` returns `.later` and shows an alert: "N runs are still running. Quitting stops them — you can resume later." Quit cancels them and replies true; Cancel replies false.
- `scripts/bundle.sh`:
  - If `metalui bundle` exists, use it.
  - Otherwise follow `MetalUI/docs/packaging.md` exactly: release build, `MetalFlow.app/Contents/{MacOS,Resources}`, copy `MetalUI_MetalUIRender.bundle` into Resources, `packaging/Info.plist` (bundle id `com.mburger.MetalFlow`, LSMinimumSystemVersion 14.0, NSHighResolutionCapable), `codesign --force --sign -`, `codesign --verify --strict`.
- [ ] **Step 1: Failing tests:**
  - `postsWhenRunNeedsYouAndClearsAfter`.
  - `noPostForOpenRun`.
  - `badgeTracksNeedsYouCount`.
  - `clickOpensRun`.
  - `shortcutsSwitchScreens`.
  - `quitWhileRunningAsks` (drive `onTerminateRequest` through the TestApp, if MetalUITesting exposes it. If not, unit-test the decision function `quitDecision(runningCount:) -> QuitDecision`.)
- [ ] **Step 2:** FAIL → implement → PASS.
- [ ] **Step 3:** `scripts/bundle.sh` builds `MetalFlow.app` and `codesign --verify` passes.
- [ ] **Step 4:** Commit `"Add notifications, commands, quit handling and bundling"`.

---

### Task 8: Live check in the app (manual, with the user)

- [ ] Open `MetalFlow.app` and add the e2e repo (`mburger89/metalflow-e2e`).
- [ ] Open its flow in the Studio and make one harmless edit, then save.
- [ ] Launch issue #1 and switch to the Dashboard. Confirm the run card progresses and that no window steals focus.
- [ ] When the notification arrives, click it. The detail view opens: compare the diffs and Pick & merge. Check that `main` has the merge commit and no `flow/*` branches are left.
- [ ] Record what happened in `docs/notes/e2e-app-<date>.md`.

## After this plan

Follow-ups:
- Adopt MetalUI split panes once they land.
- Follow-up messages to finished nodes ("steering").
- A Mission Control–style multi-run compare view.
- Light theme.
