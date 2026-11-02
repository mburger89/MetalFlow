# Review Node Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Review node: an agent reads each candidate's diff after the gate, approves it or asks for changes, and can send it back to the implementing agent through the Fix loop.

**Architecture:** A new `NodeKind.review(ReviewConfig)` that runs through the existing `runAgent`, inside a lane, with read-only tools. Its reply ends in a `VERDICT:` line. "Changes" goes through a generalised `beginFix`, which resumes the implementing agent and reruns the gate and the review. The outcome is stored on `Lane.reviewPassed` and shown to the judge, the candidate card, `mflow` and the pull request body.

**Tech Stack:** Swift, Swift Testing, MetalUI (path dependency, do not patch it).

**Spec:** None. The user asked to skip the questions and will flag anything off in this plan, so the Decisions section below is the authority.

## Decisions

These are the planner's calls; the user has not confirmed them yet.

1. **Opt-in.** The built-in "Fix GitHub issue" flow does not change, because a review per candidate adds cost to every run. Add it from the palette, under CHECKS.
2. **Candidates only.** A Review must be lane-scoped: after a step with several candidates, before the judge. Anything else is a validation error. A flow with a single agent cannot use it in this version.
3. **Read-only.** A reviewer never edits or commits. The implementing agent makes the changes, in its own session, so it keeps its context.
4. **Verdict format.** The last line matching `VERDICT: approve` or `VERDICT: changes`, case-insensitive. The engine appends the instruction to every fresh review prompt, so editing the prompt cannot lose it.
5. **No verdict never passes.** Without a readable verdict the lane is `reviewPassed = false` with a logged warning. No fix is attempted, since there is nothing to act on.
6. **Failing code is not reviewed.** If `lane.gatePassed == false`, the review costs nothing: no agent runs, the node succeeds with output `Skipped: tests failed`, and `reviewPassed` stays nil.
7. **Default of 1 fix attempt**, 0–5 in the inspector, like a gate's picker.
8. **Budgets do not refill.** Sending work back reruns the gate, but the gate keeps its `fixAttemptsUsed`. So a lane's agent runs at most `1 + gate attempts + review attempts` times, and a run's cost stays predictable.
9. **An unapproved candidate can still be picked,** like one with failing tests. The card, the judge and the PR body all say so.

## Global Constraints

- Test command (zsh, literal flags): `swift test --no-parallel -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`. Redirect long runs to a file.
- Baseline on master `bf3d48d`: mflow 58, Kit 294, Core 298. Kit and Core each have 1 known issue, the deliberate `recordsAnIssueAtTheDeadline`.
- Old flow files and run files must still load. New fields use `decodeIfPresent`, and optional ones are omitted when nil.
- MetalUI gaps go to the MetalUI session; never patch `../MetalUI` or work around a gap.
- Do not commit anything under `.claude/`. No push, no merge; the user approves each merge.
- Commit message trailers:
  ```
  Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_0195iKYn69jgc6AKCLYiUKab
  ```

## Review Focus

1. A reviewer that replies without a `VERDICT:` line, or says `VERDICT: maybe`: the lane is not approved, and no fix runs. Test in Task 2.
2. A reviewer that keeps asking for changes until attempts run out: the run still reaches the judge, with that lane shown as changes requested. Test in Task 2.
3. A fix that breaks the tests after a review: the gate's remaining attempts apply, and a gate that gives up skips the second review. Test in Task 2.
4. A review session that errors or asks a question: only that lane fails or waits, and answering it carries on to a verdict. Test in Task 2.
5. A diff longer than the 400-line limit: the reviewer is told it was cut and how to read the rest. Test in Task 2.

---

### Task 1: The node in the flow model

**Files:**
- Modify: `Sources/MetalFlowCore/Graph/Flow.swift` (`NodeKind`, its coding, `inputNames`)
- Modify: `Sources/MetalFlowCore/Graph/FlowValidation.swift`
- Modify: `Sources/MetalFlowCore/Run/Run.swift` (`Lane`, `fixProgress`)
- Test: create `Tests/MetalFlowCoreTests/ReviewFlowTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ReviewConfig: Codable, Hashable, Sendable {
      public var agent: PromptConfig   // candidates stays empty
      public var fixAttempts: Int      // decode default 1
      public init(agent: PromptConfig = ReviewConfig.defaultAgent, fixAttempts: Int = 1)
      public static let defaultAgent: PromptConfig
  }
  NodeKind.review(ReviewConfig)
  FlowError.reviewOutsideCandidates(NodeID)
  Lane.reviewPassed: Bool?             // omitted when nil
  ```
- `defaultAgent` is model `sonnet`, `maxTurns` nil, `allowedTools` `["Read", "Grep", "Glob", "Bash(git log:*)", "Bash(git diff:*)", "Bash(git show:*)", "Bash(git status:*)"]`, and this prompt:
  `Review this change. Look for bugs, missing tests and anything that does not do what it should. Do not edit files. List only the problems worth fixing, each with its file and line.\n\n{diff}`

- [ ] **Step 1: Write the failing tests** in `ReviewFlowTests.swift`:
  - `reviewRoundTrips`: a `.review` node encodes and decodes equal; JSON without `fixAttempts` decodes to 1.
  - `diffIsNotAnInput`: `inputNames(of:)` on a review with prompt `{issue} {diff}` is `["issue"]`.
  - `reviewInCandidatesIsValid`: fan-out → gate → review → judge → pick validates, and `plan.laneScoped` contains the review.
  - `reviewWithoutFanOutIsInvalid` and `reviewAfterJudgeIsInvalid`: both throw `.reviewOutsideCandidates(id)`, with the message `A Review has to sit after a step with several candidates and before the judge.`
  - `laneDecodesWithoutReviewPassed`: old lane JSON gives nil, and a nil value is not encoded.
  - `fixProgressCountsReviews`: a review node with `fixAttemptsUsed: 1` reports `FixProgress(used: 1, of: 1)`.
- [ ] **Step 2: Run them.** Expected: fail to compile, because `ReviewConfig` does not exist.
- [ ] **Step 3: Implement.** Follow how `.openPR` was added to `NodeKind`. In `validate()`, check after `scoped` is computed. `Lane` currently synthesises `Codable`, and synthesis already omits a nil optional and decodes a missing one; confirm with the test before adding code. Exhaustive switches in other targets will stop compiling: add a minimal case there and leave the real behaviour to Task 3 (`runNode` may `finish(... .failed("Review is not implemented"))` until Task 2).
- [ ] **Step 4: Run the tests.** Expected: the new tests pass and the whole package builds.
- [ ] **Step 5: Commit** as `Add the Review node to the flow model`.

### Task 2: Running a review

**Files:**
- Modify: `Sources/MetalFlowCore/Run/RunEngine+Nodes.swift` (`runNode`, `runAgent`, `candidatesText`, `runOpenPR`, `recommendation`)
- Modify: `Sources/MetalFlowCore/Run/RunEngine+Fix.swift` (`beginFix`, `laneCommitMessage`)
- Modify: `Sources/MetalFlowCore/Run/RunEngine+Retry.swift` (lane reset)
- Modify: `Sources/MetalFlowCore/Run/Run.swift` (`PendingFix`)
- Test: create `Tests/MetalFlowCoreTests/RunEngineReviewTests.swift`; `RunEngineFixLoopTests.swift` shows the harness and how to script a lane.

**Interfaces:**
- Consumes: `ReviewConfig`, `Lane.reviewPassed` from Task 1.
- Produces:
  ```swift
  enum ReviewVerdict { case approve, changes }
  static func reviewVerdict(in text: String) -> ReviewVerdict?
  static func reviewFixMessage(findings: String) -> String
  func beginFix(_ id: RunID, _ key: NodeKey, attempts: Int, message: String,
                source: PendingFix, logLine: String, plan: FlowPlan) -> Bool
  PendingFix.label: String   // decode default "Gate"; "Review" for reviews
  ```

Behaviour:
- `runNode`'s `.review` case: skip when `lane.gatePassed == false` (Decision 6), else `runAgent` with the review's agent config.
- A fresh review's prompt has `{diff}` filled and this appended: `\n\nEnd your reply with a final line that is exactly `VERDICT: approve` or `VERDICT: changes`.`
- `{diff}` is `git.diff(worktree:base: run.branch)` clipped to `maxCandidateDiffLines`. Share the clipping with `candidatesText`. When clipped, add `(cut at 400 lines; read the rest with git diff <run.branch>)`.
- A review never commits, so `runAgent`'s lane commit is skipped for it.
- At the end of a turn, a question still wins (`needsYou`). Otherwise:
  - `approve`: `reviewPassed = true`, node succeeds.
  - `changes`: `beginFix` with the node's `fixAttempts`; if it declines, `reviewPassed = false` and the node succeeds with the reply as output.
  - no verdict: `reviewPassed = false`, log `⚠ no VERDICT line`, node succeeds.
- `reviewVerdict` and `recommendation` share one "value of the last line with this marker" helper. Only `approve` and `changes` count; `VERDICT: maybe` is nil.
- `reviewFixMessage` is: `A reviewer asked for changes to your work:\n\n<findings, last 200 lines>\n\nMake the changes that are right. If you disagree with one, leave it and say why in your reply.`
- `beginFix` is generalised, and the gate's existing behaviour must not change:
  - It sets `pendingFix` from `source`, and resets `gatePassed` and `reviewPassed` to nil on the lane.
  - The reset of nodes between the agent and the checker keeps `fixAttemptsUsed` (Decision 8), and the checker's own `sessionID` and `output` are cleared so the rerun is a fresh review.
- `laneCommitMessage`'s last body line becomes `<label>: <command>`. For a review that is `Review: <node title>`, and the subject stays `Fix attempt n of m: …`.
- `candidatesText` adds to the header `, review approved`, `, review asked for changes` or nothing. When changes were asked for, the review's output (last 40 lines) goes under the diff.
- The PR body becomes `Candidate a (sonnet), tests passed, review approved, chosen in MetalFlow.`, with the review part left out when `reviewPassed` is nil and `review asked for changes` when false.
- Retry: when a review key is reset, `reviewPassed` is reset to nil, alongside the gate logic in `RunEngine+Retry.swift`.

- [ ] **Step 1: Write the failing tests** in `RunEngineReviewTests.swift`, each asserting on the run's final state:
  - `approvalMarksTheLane`: `reviewPassed == true`; the review request's tools are the configured ones and its prompt contains the diff and the `VERDICT` instruction.
  - `reviewDoesNotCommit`: a review turn adds no commit to the lane.
  - `changesResumeTheAgentAndRerunGateAndReview`: the agent's next request resumes its session with the findings; the gate runs twice and the review twice; the second review is a new session, and approves; `reviewPassed == true`; `fixAttemptsUsed == 1`; the branch has a `Fix attempt 1 of 1: …` commit whose body has `Review: <title>`.
  - `changesRunOutReachesTheJudge`: with attempts 1 and two `changes` verdicts, `reviewPassed == false`, the judge ran once, and its prompt says `review asked for changes` and contains the findings.
  - `zeroAttemptsMeansNoFix`: attempts 0, `changes`: no resumed agent.
  - `missingOrUnknownVerdictIsNotApproved`: no `VERDICT` line and `VERDICT: maybe`, both give `reviewPassed == false`, no fix, and the warning in the log.
  - `verdictIsTheLastMatchingLine`: a reply quoting `VERDICT: approve` and ending in `VERDICT: changes` is `.changes`; lower case and backticks are accepted.
  - `failingGateSkipsTheReview`: no review request; output `Skipped: tests failed`; `reviewPassed == nil`.
  - `fixThatBreaksTheTestsUsesTheGatesAttempts`: review asks for changes, the gate then fails and has attempts left, so the gate's fix runs and the review runs again.
  - `gateBudgetIsNotRefilled`: gate attempts 1, used once before the review, then a gate failure after the review's fix: no further fix, `gatePassed == false`, the second review is skipped.
  - `reviewSessionErrorFailsOnlyThatLane`, and `reviewQuestionWaitsThenReachesAVerdict`.
  - `longDiffIsCutAndSaysSo`: more than 400 lines gives the `(cut at 400 lines…` note, naming the branch.
  - `pullRequestBodyMentionsTheReview`: approved, changes and no-review forms.
  - `retryingAReviewClearsItsResult`.
  - `oldPendingFixDecodes`: JSON without `label` gives `"Gate"`.
- [ ] **Step 2: Run them.** Expected: they fail on assertions, because the Task 1 stub fails the node.
- [ ] **Step 3: Implement the behaviour above.**
- [ ] **Step 4: Run the full suite.** Expected: new tests pass, and all existing fix loop and Open PR tests pass unchanged except for the PR body and commit body forms this task specifies.
- [ ] **Step 5: Commit** as `Run Review nodes: verdicts, sending work back, and showing the result`.

### Task 3: Studio, run detail and mflow

**Files:**
- Modify: `Sources/MetalFlowKit/Studio/FlowDraft.swift` (`PaletteKind`, `id "review"`, in the CHECKS group, default `.review(ReviewConfig())`)
- Modify: `Sources/MetalFlowKit/Studio/InspectorView.swift` (`editPrompt` covers `.review`'s `agent`; `editReview`; `acceptsInputs` true; reuse the prompt fields without the candidates control; a Fix attempts picker)
- Modify: `Sources/MetalFlowKit/Studio/NodeCardView.swift` (label `REVIEW`, the gate's accent colour, subtitle is the model)
- Modify: `Sources/MetalFlowKit/RunDetail/CandidateCard.swift`
- Modify: `Sources/MetalFlowKit/App/Activity.swift`
- Modify: `Sources/mflow/Commands.swift`
- Test: create `Tests/MetalFlowKitTests/ReviewViewTests.swift`; extend the mflow tests.

**Interfaces:**
- Consumes: `ReviewConfig`, `Lane.reviewPassed`, `Run.fixProgress`.
- Produces identifiers: `palette.review`, `inspector.review.fixAttempts`, `inspector.review.fixHint`, `<candidate id>.review`.

Copy:
- Inspector hint: `Sends the requested changes back to the agent up to this many times.` Below it: `{diff} is filled in with the candidate's changes.`
- Candidate card, under the tests line: `Review approved` (ok), `Review asked for changes` (warn); nothing when nil.
- Activity, when a lane's `reviewPassed` becomes false: `review asked for changes on candidate <lane>` (warn); when true: `review approved candidate <lane>` (ok).
- `mflow` lanes line: after the gate text, `review approved` or `review asked for changes`, omitted when nil. `(fix 1 of 2)` works through `fixProgress` already.
- The picker has `.labelsHidden()`, like every other `Picker("",…)`. Reuse `GateFixFields`' 0–5 range constant.

- [ ] **Step 1: Write the failing tests**: palette adds a review node with defaults; the inspector shows the prompt and the Fix attempts picker but no candidates control; changing the picker edits the config and is undoable; a new default review validates once placed between a gate and a judge; the card shows each of the three states; Activity emits each line; `runSummary` has both forms and omits nil. Check the picker sits on its label's left edge, as `launchColumnsStartAtTheirLeftEdge` does.
- [ ] **Step 2: Run them.** Expected: fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite.** Expected: all pass with only the 2 known issues.
- [ ] **Step 5: Commit** as `Add Review to the Studio, run detail and mflow`.

### Task 4: Live check

Controller only, not delegated. Needs the user's OK first: it spends about $1–2 on real agents. It publishes nothing, because the run is discarded at the pick.

- [ ] **Step 1:** Scratch `METALFLOW_HOME` and a fresh clone of `mburger89/metalflow-e2e`. The flow: implement ×2 (sonnet, haiku) → `swift test` gate → Review → judge → pick. To force "changes" for real, the review prompt asks for a doc comment on the changed function, which the implement prompt does not mention.
- [ ] **Step 2:** Run it with `mflow launch 1 --flow … --repo …`, then `mflow show`. Expected: review asks for changes, `Fix attempt 1 of 1` commit, gate and review rerun, `review approved`, the judge mentions it, cost within budget.
- [ ] **Step 3:** `mflow discard`. Confirm no branches on origin other than `main` and what was there before, and that issue #1 is unchanged.
- [ ] **Step 4:** Write `docs/notes/e2e-<date>-review.md`, in the form of `e2e-2026-11-01-open-pr.md`, and commit it.
