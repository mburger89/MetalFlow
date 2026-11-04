# Follow-Up to a Finished Node Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user send a finished candidate's agent a follow-up message ("also handle the empty case") while the run is waiting for a winner. The agent resumes its own session, its lane's gate and review rerun, and the judge and pick are put back up for a decision.

**Architecture:** A new `RunEngine.followUp(_:node:message:)` built on the same mechanics as `answer` and `beginFix`: set `pendingReply` on the node, reset what lies downstream of it, and request a pass. The lane agent's session resumes via `resumeSessionID`, so the agent keeps its context. Eligibility lives in Core (`canFollowUp`) so the engine, the app and `mflow` agree on what is allowed.

**Tech Stack:** Swift, Swift Testing, MetalUI (path dependency, do not patch it).

**Spec:** None. The Decisions section below is the authority. The user approved the plan in chat on 2026-11-04.

## Decisions

These are the planner's calls.

1. **Only while the run is waiting for a winner.** Eligible when `run.status == .needsYou`, the pick node is `.needsYou(.pickWinner)`, and nothing is picking. Not while other lanes are still running, not after a pick, merge, discard or PR. This keeps the rerun simple: nothing is in flight in the run.
2. **Only candidate agents.** The node must be a `.prompt` node inside a lane (`NodeKey.lane != nil`), in state `.succeeded`, with a `sessionID`. Single-agent flows and gates, reviews and judges are out of scope for v1.
3. **Same lane, plus everything after the fan-out.** Reset the node's descendants in its own lane (gate, review), and all non-lane descendants (judge, pick, anything after them). Other lanes are not touched. Lane agents in other lanes keep their results.
4. **Reset works like `beginFix`.** Downstream nodes are replaced with a fresh `NodeRun` that keeps `costUSD`, `extraAllowedTools`, and `fixAttemptsUsed`. Budgets do not refill. The lane's `gatePassed` and `reviewPassed` go back to nil. `run.recommendation` goes back to nil. The pick node goes back to `.waiting`.
5. **Session resumes.** The follow-up node keeps its `sessionID`, sets `pendingReply = message`, and gets `state = .waiting`. The existing node runner already sends `pendingReply` with `resumeSessionID`, so no runner change is needed.
6. **Commit message.** A follow-up turn commits as the lane commit, with a `Follow-up:` line naming the first line of the message. It is not labelled as a fix attempt.
7. **Message required.** Trimmed, non-empty. An empty message throws `RunEngineError.emptyFollowUp`.
8. **Refusal is an error, not a silent no-op.** `followUp` throws `RunEngineError.notFollowable(node)` for an ineligible node or run, and `runBusy` when the lock is held, as `answer` does.
9. **UI.** The candidate card for an eligible lane agent shows a "Follow up" button. It opens a single-line field and a Send button. The field is hidden for ineligible nodes. The run detail shows a "Working on follow-up" note while the node is waiting or running with a follow-up pending. `mflow follow-up <run> <node> <lane> <message...>` covers the CLI.

## Global Constraints

- Test command (zsh, literal flags): `swift test --no-parallel -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`. Redirect long runs to a file and read the summary.
- Record the baseline counts for `MetalFlowCoreTests`, `MetalFlowKitTests`, and `mflowTests` before changing anything, and report them.
- Known issue: one deliberate `recordsAnIssueAtTheDeadline` in each of Kit and Core. It is expected.
- Do not add attribution lines to commits unless asked. Do not push.
- Files to read first: `Sources/MetalFlowCore/Run/RunEngine+Decide.swift` (`answer`, `resumeInterrupted`), `RunEngine+Fix.swift` (`beginFix`, `fixingAgent`, `nodesBetween`), `RunEngine+Nodes.swift` (the node runner, `pendingReply` handling near line 182), `RunEngine+Retry.swift` (downstream reset), `Run.swift` (`NodeRun`, `NodeState`, `NeedsYou`), `Sources/MetalFlowKit/App/EngineClient.swift`, `AppModel.swift` (around line 448), `Sources/mflow/main.swift` (the `answer` command near line 81).

## Task 1: Engine

**Files:** `Sources/MetalFlowCore/Run/RunEngine+FollowUp.swift` (new), `Sources/MetalFlowCore/Run/RunEngine.swift` (error cases), `Sources/MetalFlowCore/Run/Run.swift` if a helper belongs there, `Tests/MetalFlowCoreTests/RunEngineFollowUpTests.swift` (new).

- [ ] Add `RunEngineError.notFollowable(NodeKey)` and `.emptyFollowUp`, with messages, next to the existing cases.
- [ ] Add `public func canFollowUp(_ run: Run, node: NodeKey) -> Bool` (pure, no I/O), implementing decisions 1 and 2.
- [ ] Add `public func followUp(_ id: RunID, node: NodeKey, message: String) throws`, following `answer`'s lock, `clearSuspension`, and `requestPass` pattern. Implement decisions 3 to 5 and 7.
- [ ] Give `laneCommitMessage` an optional follow-up label, or add a sibling helper, so the commit carries a `Follow-up:` line (decision 6). Keep the existing fix commit messages unchanged, and keep their tests passing.
- [ ] Tests, using the existing review and fix-loop test harnesses (`RunEngineFixLoopTests.swift`, `RunEngineReviewTests.swift`) for how to build a run waiting at the pick:
  - follow-up resumes the same session (the stub agent records `resumeSessionID`) and its reply is the message;
  - the lane gate and review rerun, and the judge and pick are reset to waiting;
  - another lane's nodes and results are unchanged;
  - budgets (`fixAttemptsUsed`, `costUSD`) survive the reset;
  - refused when the run is running, when the node is not `.succeeded`, when it is not a lane agent, after a pick, and when another lane is still running;
  - an empty message throws `emptyFollowUp`;
  - the commit message carries the `Follow-up:` line.
- [ ] Run the Core suite. Expect the baseline plus the new tests, with only the known issue failing.
- [ ] Commit: `Add a follow-up to a finished candidate's agent`.

## Task 2: Plumbing

**Files:** `Sources/MetalFlowKit/App/EngineClient.swift` (protocol, live client), `Sources/MetalFlowKit/App/AppModel.swift`, `Tests/MetalFlowKitTests/Support/FakeEngineClient.swift`, `Sources/mflow/main.swift`, `Sources/mflow/Commands.swift` (usage text), `Tests/mflowTests/ArgumentParsingTests.swift`, `Tests/MetalFlowKitTests/AppModelTests.swift`.

- [ ] Add `followUp(_:node:message:)` to `EngineClient`, the live client (forwarding to the engine), and `FakeEngineClient` (recording the calls).
- [ ] Add `AppModel.followUp(_:node:message:) async -> Bool`, mirroring `answer`'s `perform`.
- [ ] `mflow follow-up <run> <node> <lane> <message...>`: parse like `answer`, add it to `knownCommands` and the usage text. Tests for parsing and for the missing-argument error.
- [ ] Tests: `AppModel` forwards to the client and returns false on error.
- [ ] Run the Kit and mflow suites. Expect baseline plus new, with the known issue only.
- [ ] Commit: `Expose follow-ups through the app and mflow`.

## Task 3: Interface

**Files:** `Sources/MetalFlowKit/RunDetail/CandidateCard.swift`, `Sources/MetalFlowKit/RunDetail/RunDetailView.swift`, related view model if one exists, `Tests/MetalFlowKitTests/RunDetailTests.swift`.

- [ ] Show the "Follow up" button only when `canFollowUp` is true for that candidate's agent node. The button opens a single-line text field with a Send button. Empty text disables Send.
- [ ] Send calls `AppModel.followUp`. On success the field clears. On failure, show the error the way other run actions do.
- [ ] While a follow-up is pending (the node is `.waiting` or `.running` after a follow-up was sent), show "Working on follow-up" on that candidate card.
- [ ] Accessibility identifiers: `\(node).followUp`, `\(node).followUp.field`, `\(node).followUp.send`, following the existing `.resume` naming pattern.
- [ ] Tests: button visibility for eligible and ineligible candidates; Send disabled on empty text; the pending label.
- [ ] Run the Kit suite. Expect baseline plus new, with the known issue only.
- [ ] Commit: `Show a follow-up field on a candidate waiting for a winner`.

## Verification

- [ ] All three suites pass, apart from the known issues.
- [ ] Then a live run through the packaged app, once the desktop is free and computer use is granted. Create a flow with two candidates, let the run reach the pick, follow up on one candidate, and check on screen that its session resumes, its gate and review rerun, and the pick comes back. Write the result to `docs/notes/e2e-2026-11-04-follow-up.md`.
- [ ] Report anything not verified on screen as unverified.
