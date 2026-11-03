# Finish the v1 Design Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the five things the v1 design describes that the app still lacks.

**Architecture:** The engine gains a `followUp` beside `retry`, sharing one downstream reset, and a Prompt or Judge node can name an earlier Prompt whose session it continues. The session limit becomes a small settings file the engine reads and can change live. The palette filter and zoom buttons are view state on `FlowDraft` only.

**Tech Stack:** Swift 6, MetalUI, Swift Testing, `MetalUITesting`.

**Spec:** `docs/superpowers/specs/2026-10-30-metalflow-v1-design.md`

## The list

1. "Find a node" field on the palette (Task 1)
2. − and + zoom buttons on the canvas (Task 1)
3. Session limit setting (Task 2)
4. Follow-up message to a finished node (Tasks 3, 4)
5. A later node continues an earlier node's session (Tasks 5, 6)

Task 7 proves 4 and 5 against the real `claude`.

## Global Constraints

- Default limit: "At most 4 Claude sessions run at once by default, and that is a setting."
- "Auto-merging" stays an anti-goal: a follow-up never merges or picks.
- "Stealing focus" stays an anti-goal: nothing here opens a window or changes the screen on its own.
- Tests never sleep; drive time explicitly. Run: `swift test --no-parallel -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` (zsh, literal flags). Add `--filter <Suite>` for one suite.
- Views stay thin: behaviour goes on `FlowDraft` / `AppModel` / Core, and tests drive it there or through `MetalUITesting`.
- Don't patch `../MetalUI`. If it lacks something, stop and report it; the controller asks the MetalUI session.
- No pushing. Commit on branch `finish-v1-design`. `.claude/` stays uncommitted.

## Review Focus

1. Typing in the Find field, including `n`, Delete, Tab and Esc, never reaches the canvas: no note added, no node deleted, no search pane. Pinned in Task 1.
2. A follow-up to a run that has merged, been discarded, opened a PR or is still running is refused, because its worktree is gone or busy, and the app doesn't offer it. Pinned in Tasks 3 and 4.
3. `settings.json` that is missing, corrupt, or holds 0 or 9999 still gives a working limit, and raising the limit starts waiting sessions without a restart. Pinned in Task 2.
4. Deleting the node a session continues from clears the reference in the same undo step, and undo restores both. Pinned in Task 6.
5. Flow files saved before `continuesSessionOf` still load, and a flow that doesn't use it doesn't write it. Pinned in Task 5.

---

### Task 1: Find field and zoom buttons

**Files:**
- Modify: `Sources/MetalFlowKit/Studio/PaletteView.swift`, `Sources/MetalFlowKit/Studio/FlowDraft+Adding.swift`, `Sources/MetalFlowKit/Studio/FlowDraft.swift`, `Sources/MetalFlowKit/Studio/CanvasView.swift`
- Test: `Tests/MetalFlowKitTests/CanvasChromeTests.swift` (create)

**Interfaces:**
- Produces, on `FlowDraft`: `var paletteFilter: String` (default ""), `var visiblePaletteGroups` (same element type as `PaletteEntry.groups`, groups with no match left out), `func addFirstPaletteMatch()`, `func zoomCanvas(by factor: Double)`, `static let zoomStep = 1.25`.
- Accessibility ids: `palette.find`, `palette.empty`, `canvas.zoomIn`, `canvas.zoomOut`.

- [ ] **Step 1: Write failing tests** in `CanvasChromeTests`:
  - `findFiltersPaletteIgnoringCase`: filter `"GATE"` leaves only the Gate entry; `""` shows every group.
  - `findUsesSameMatchingAsTabSearch`: for a query, the flattened `visiblePaletteGroups` labels equal the `nodeSearchMatches` labels with that query in the pane.
  - `findShowsEmptyState`: filter `"zzz"` renders `palette.empty` reading "No matches".
  - `returnInFindAddsFirstMatchAtCentre`: Return adds the first match at the canvas centre, selects it and clears the filter; with no match it adds nothing.
  - `escapeInFindClearsIt`.
  - `typingInFindStaysInTheField`: with the field focused and the pointer over the canvas, typing `n` adds no note, Delete with a node selected keeps the node, Tab opens no search pane.
  - `filterIsNotAnEdit`: changing the filter leaves `isDirty` false and pushes no undo.
  - `zoomInStepsAboutCentre`: from 100%, `canvas.zoomIn` shows 125%, and the canvas point at the canvas centre stays put.
  - `zoomOutStops`: pressing `canvas.zoomOut` repeatedly ends at 25% and the button is disabled; same for `canvas.zoomIn` at 400%.
  - `zoomIsNotAnEdit`: zooming leaves `isDirty` false.

- [ ] **Step 2: Run** `--filter CanvasChromeTests`. Expected: fails to compile on the missing names.

- [ ] **Step 3: Implement.** Move Tab search's label match into one `PaletteEntry` helper that both use. The field goes at the top of `PaletteView` with placeholder "Find a node", using `TextField.onSubmit` for Return. Zoom order in the canvas overlay is −, %, +, Fit, matching `design/V1Studio.dc.html`. `zoomCanvas` anchors on `canvasSize` centre and does nothing while `canvasSize` is nil.

- [ ] **Step 4: Run** the same filter. Expected: pass.

- [ ] **Step 5: Commit** `Add a Find field to the palette and zoom buttons to the canvas`.

### Task 2: Session limit setting

**Files:**
- Create: `Sources/MetalFlowCore/Run/RunSettings.swift`
- Modify: `Sources/MetalFlowCore/Run/SessionLimiter.swift`, `RunStore.swift`, `RunEngine.swift`, `Sources/mflow/main.swift`, `Sources/MetalFlowKit/App/EngineClient.swift`, `Sources/MetalFlowKit/App/AppModel.swift`, `Sources/MetalFlowKit/Dashboard/DashboardView.swift`, `Tests/MetalFlowKitTests/Support/FakeEngineClient.swift`
- Test: `Tests/MetalFlowCoreTests/SessionLimiterTests.swift`, `RunStoreTests.swift`, `Tests/MetalFlowKitTests/SessionLimitTests.swift` (create)

**Interfaces:**
- Produces, in Core: `public struct RunSettings: Codable, Equatable, Sendable { public var maxSessions: Int; public static let defaultMaxSessions = 4; public static let sessionRange = 1...16 }`; `RunStore.settings() -> RunSettings`; `RunStore.saveSettings(_:) throws` (file `settings.json` in the store root, atomic); `SessionLimiter.setMax(_ max: Int)`; `RunEngine.setMaxSessions(_ max: Int) async`.
- Produces, in Kit: `EngineClient.maxSessions() -> Int`, `EngineClient.setMaxSessions(_ max: Int) async throws`; `AppModel.maxSessions: Int`, `AppModel.setMaxSessions(_ max: Int) async`.
- Accessibility id: `dashboard.maxSessions`.

- [ ] **Step 1: Write failing tests:**
  - Limiter: `raisingMaxStartsWaiters` (max 1, one holding, one waiting; `setMax(2)` lets the waiter run while the first still holds); `loweringMaxStopsNoOneAndAdmitsNoOneUntilBelow` (max 2 with both held, `setMax(1)`, one releases, a waiter still waits; second releases, waiter runs).
  - Store: `settingsDefaultWhenMissing`, `settingsDefaultWhenCorrupt`, `settingsClampOnRead` (0 reads as 1, 9999 as 16), `settingsRoundTrip`.
  - Kit: `limitLoadsFromClient`, `changingLimitReachesClientAndSaves`, `limitControlShowsOnDashboard`.

- [ ] **Step 2: Run** `--filter SessionLimiterTests`, then `--filter RunStoreTests`, then `--filter SessionLimitTests`. Expected: compile failures on the missing names.

- [ ] **Step 3: Implement.** `release()` hands a slot on only while `active <= max`; `setMax` resumes waiters while `active < max`. `LiveEngineClient.makeDefault` and `mflow` pass `maxSessions: store.settings().maxSessions` to `RunEngine`. The app has no settings screen and MetalUI has no settings window, so put a `Stepper("Sessions at once: \(n)", ...)` from MetalUI above the Activity feed on the Dashboard. Each process keeps its own limiter, as it does today; `mflow` picks up a change on its next start.

- [ ] **Step 4: Run** the three filters. Expected: pass.

- [ ] **Step 5: Commit** `Make the session limit a setting`.

### Task 3: Follow-up in the engine and `mflow`

**Files:**
- Create: `Sources/MetalFlowCore/Run/RunEngine+FollowUp.swift`
- Modify: `Sources/MetalFlowCore/Run/RunEngine+Retry.swift`, `RunEngine.swift` (the error enum), `Sources/mflow/main.swift`, `Sources/mflow/Commands.swift`
- Test: `Tests/MetalFlowCoreTests/RunEngineFollowUpTests.swift` (create), `Tests/mflowTests/`

**Interfaces:**
- Produces: `extension Run { public func canFollowUp(_ key: NodeKey) -> Bool }`, true when the node is a Prompt or Judge, its state is `.succeeded`, it has a `sessionID`, and the run's status is `.needsYou`, `.failed` or `.completed`.
- Produces: `RunEngine.followUp(_ id: RunID, node: NodeKey, message: String) throws`; `RunEngineError.notFollowable(NodeKey)` reading "Only a finished Prompt or Judge step of an open run can take a follow-up."
- Produces, internal: `RunEngine.resetForRerun(_ node: NodeKey, plan: FlowPlan, in run: inout Run)`, extracted unchanged from `retry`.
- CLI: `mflow follow-up <id> <nodeKey> [--] <message...>`, which follows the run like `answer`.

Reviews are left out: `runAgent` sends only the reply on resume, so a resumed reviewer gets no `VERDICT` instruction and would read as not approved.

- [ ] **Step 1: Write failing tests** in `RunEngineFollowUpTests`, using the fake agent the other `RunEngine*Tests` use:
  - `resumesTheSameSessionWithTheMessage`: the node's next `AgentRequest` has `resumeSessionID` equal to its session and `prompt` equal to the message.
  - `rerunsLaterStepsOfThatCandidateOnly`: follow up Implement in lane `a` of a fan-out flow; lane `a`'s gate and the judge and pick rerun, lane `b`'s nodes keep their outputs and `gatePassed`, and `recommendation` is cleared until the judge reports again.
  - `commitsTheFollowUpsChanges`: the lane's worktree has a new commit after the turn.
  - `judgeFollowUpWithoutARecommendationLeavesNone`: the run still reaches pick with `recommendation == nil`.
  - `refusedWhile` parameterised over `.running`, `.merged`, `.discarded`, `.cancelled`, `.prOpened`: throws `notFollowable`.
  - `refusedForNodesThatCannot`: a gate, a Review, a failed Prompt and a Prompt with no `sessionID` throw `notFollowable`.
  - `refusesAnEmptyMessage`: whitespace only throws `notFollowable`, and the run doesn't change.
  - `survivesQuitting`: suspend before the turn starts, then `resumeInterrupted` sends the follow-up text, not "Continue where you left off."
- [ ] Add to `mflowTests`: `followUp` is a known command and appears in `usageText`; missing arguments exit 64.

- [ ] **Step 2: Run** `--filter RunEngineFollowUpTests`. Expected: compile failure.

- [ ] **Step 3: Implement.** Extract `resetForRerun` from `retry`, then `followUp` mirrors `retry`'s guards (`ensureLock`, `picking`, `deciding`, `validate`, `clearSuspension`), sets `pendingReply` and calls `resetForRerun`.

- [ ] **Step 4: Run** `--filter RunEngineFollowUpTests`, `--filter RunEngineRetryTests` and `--filter mflowTests`. Expected: pass; the retry suite proves the extraction changed nothing.

- [ ] **Step 5: Commit** `Send a follow-up to a finished step`.

### Task 4: Follow-up in the app

**Files:**
- Create: `Sources/MetalFlowKit/RunDetail/FollowUpBox.swift`
- Modify: `Sources/MetalFlowKit/RunDetail/RunDetailView.swift`, `AppModel+RunDetail.swift`, `Sources/MetalFlowKit/App/EngineClient.swift`, `Tests/MetalFlowKitTests/Support/FakeEngineClient.swift`
- Test: `Tests/MetalFlowKitTests/FollowUpTests.swift` (create)

**Interfaces:**
- Consumes: `Run.canFollowUp`, `RunEngine.followUp`.
- Produces: `EngineClient.followUp(_ id: RunID, node: NodeKey, message: String) async throws`; on `AppModel`: `followUpDrafts: [String: String]`, `followingUp: Set<String>` (keyed by `AppModel.draftKey`), `toggleFollowUp(run:node:)`, `@discardableResult sendFollowUp(run:node:) async -> Bool`.
- Accessibility ids: `detail.node.<key>.followUp`, `followUp.<runID>.<key>.field`, `.send`, `.hint`.

- [ ] **Step 1: Write failing tests** in `FollowUpTests`:
  - `offeredOnAFinishedPrompt`, `notOfferedOnGate`, `notOfferedOnceMerged`, `notOfferedWhileRunningElsewhere`.
  - `pressingShowsFieldAndHint`: the hint reads "The steps after this one run again."
  - `sendGoesToTheEngineAndClosesTheBox`: the client gets the trimmed text, the draft clears and the box closes.
  - `refusalKeepsTheText`: when the client throws, a notice shows and the draft stays.
  - `sendDisabledWhenEmpty`.

- [ ] **Step 2: Run** `--filter FollowUpTests`. Expected: compile failure.

- [ ] **Step 3: Implement.** Add a bordered "Follow up" button in `StepRow.action`. Model `sendFollowUp` on `sendAnswer`, including keeping text typed while the send was in flight.

- [ ] **Step 4: Run** `--filter FollowUpTests`. Expected: pass.

- [ ] **Step 5: Commit** `Offer a follow-up on finished steps in the run view`.

### Task 5: Continue an earlier session in the engine

**Files:**
- Modify: `Sources/MetalFlowCore/Graph/Flow.swift`, `FlowValidation.swift`, `Sources/MetalFlowCore/Run/RunEngine+Nodes.swift`
- Test: `Tests/MetalFlowCoreTests/ContinueSessionTests.swift` (create)

**Interfaces:**
- Produces: `PromptConfig.continuesSessionOf: NodeID?`, added as the last initialiser parameter with default `nil`.
- Produces: `FlowError.badSessionSource(NodeID)` reading "<title> can only continue the session of a Prompt that runs before it." `FlowError.sessionScopeMismatch(NodeID)` reading "<title> and the step it continues have to run in the same worktree: both candidates, or neither." `FlowError.sessionContinuedTwice(NodeID)` reading "Only one step can continue a given session." Name nodes by title through `Flow.message(for:)`.
- Produces: `Flow.sessionSources(for id: NodeID) -> [NodeID]`, the Prompts upstream of `id` in the same scope that no other node continues, in plan order. Empty for anything but a Prompt or Judge.

Rules, each because of how `claude` behaves: the worktrees must match because `claude` looks a session up by working directory; one continuer per source because `--resume` keeps the same session id (`docs/notes/claude-stream-json.md`), so two continuers would share and interleave one conversation. Only Prompt and Judge can continue, so a Review stays a fresh reader.

- [ ] **Step 1: Write failing tests** in `ContinueSessionTests`:
  - Validation: `sourceMustExist`, `sourceMustBeAPrompt`, `sourceMustBeUpstream`, `laneCannotContinueNonLane`, `nonLaneCannotContinueLane`, `reviewCannotContinue`, `twoCannotContinueOne`, `valid` for both non-lane→non-lane and lane→lane.
  - `sessionSourcesListsOnlyValidOnes`.
  - Engine: `continuesTheSourcesSessionWithItsOwnPrompt` (`resumeSessionID` is the source's, `prompt` is the node's filled template); `laneContinuesItsOwnLanesSession` (lane `b` gets lane `b`'s session); `retryContinuesAgain`; `ownReplyWinsOverSource` (a pending answer to this node's own question resumes `current.sessionID` with the reply); `missingSessionStartsFresh` (source has no session: logs "⚠ no session to continue; starting fresh", `resumeSessionID` nil).
  - File: `oldFlowFilesLoad` (JSON without the key decodes to nil); `unusedFieldIsNotWritten` (encoding a config with nil has no `continuesSessionOf` key); `roundTrips`.

- [ ] **Step 2: Run** `--filter ContinueSessionTests`. Expected: compile failure.

- [ ] **Step 3: Implement.** The check goes in `validate()` after `scoped` is computed. `sessionSources` uses `try? validate()` for scope and treats everything as non-lane when the flow is invalid, so it needs its own descendants walk rather than `validate`'s local one; keep the rule in one private helper both call. In `runAgent`, add the source's session after the `pendingReply` check.

- [ ] **Step 4: Run** `--filter ContinueSessionTests` and `--filter FlowValidationTests`. Expected: pass.

- [ ] **Step 5: Commit** `Let a step continue an earlier step's session`.

### Task 6: Continue session in the inspector

**Files:**
- Modify: `Sources/MetalFlowKit/Studio/InspectorView.swift`, `Sources/MetalFlowKit/Studio/FlowDraft.swift`
- Test: `Tests/MetalFlowKitTests/ContinueSessionInspectorTests.swift` (create)

**Interfaces:**
- Consumes: `PromptConfig.continuesSessionOf`, `Flow.sessionSources(for:)`.
- Accessibility id: `inspector.continuesSession`.

- [ ] **Step 1: Write failing tests:**
  - `pickerShownForPromptAndJudgeNotReview`.
  - `listsNewSessionThenSources`: options are "New session" then source titles.
  - `choosingSetsTheFieldAsOneUndoStep`.
  - `invalidCurrentValueStaysVisible`: after unwiring, the picker still shows the chosen source and the validation banner shows the message.
  - `deletingTheSourceClearsItInOneUndoStep`: `deleteNode` clears the field and undo restores both the node and the field; the same for `deleteSelection`.

- [ ] **Step 2: Run** `--filter ContinueSessionInspectorTests`. Expected: compile failure or assertion failures.

- [ ] **Step 3: Implement.** Picker labelled "Continue session from", shown in the prompt/judge inspector section for `.prompt` and `.judge` only, with the hint "Sends this prompt as the next message of that step's conversation." Clear references inside `removeNodes`.

- [ ] **Step 4: Run** the filter, then the full suite. Expected: pass, with only the deliberate known issue `recordsAnIssueAtTheDeadline`.

- [ ] **Step 5: Commit** `Choose a session to continue in the inspector`.

### Task 7: Live check (controller runs this)

**Files:** Create `docs/notes/e2e-2026-11-02-followup.md`.

- [ ] **Step 1:** In a throwaway local git repo with a scratch `METALFLOW_HOME`, using cheap models and at most $2 total, no pushing and no GitHub changes: launch a two-candidate flow where Implement continues Plan is rejected with the scope message, then a flow where a second non-lane Prompt continues the first and recalls a word only the first was told. Expected: the second reply contains the word.
- [ ] **Step 2:** On a finished candidate, run `mflow follow-up` asking for a small extra change. Expected: same session id, a new commit in that lane, its gate and the judge rerun, and the other lane untouched.
- [ ] **Step 3:** Write the note with costs and any surprise. Commit `Note the live follow-up and session run`.
