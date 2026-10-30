# MetalFlow v1 — design

Date: 2026-10-30. Mockups: `design/V1Dashboard.dc.html`, `design/V1Studio.dc.html`
(live canvas: https://claude.ai/artifact/BKRwKMDmXVosRHQJX94bBz, row "MetalFlow v1").

## Intent

The user runs many coding agents at once and loses track of them. MetalFlow is a
macOS app, built on their own UI framework MetalUI, for building **repeatable
flows** — trees of operations and decisions that produce an output — and for
managing many runs of those flows at the same time.

A flow is like a function: define it once, launch it many times with different
inputs. The first real flow is **Fix GitHub issue**: the input is an issue, each run
fixes a different issue.

Two screens:

- **Flow Studio** — node-graph editor for a flow, and the place to inspect a run and
  pick its result.
- **Dashboard** — manage all runs: what needs you, what you're working on, what's
  running, what finished.

## Goals (v1 finish line, agreed)

End to end, for one local git repo:

1. Open (or build) the *Fix GitHub issue* flow in Flow Studio. It is saved as a file
   in the repo.
2. Launch it with an issue (number or URL).
3. Leave Flow Studio; watch the run next to other runs on the Dashboard.
4. Get a macOS notification when the run needs you (judge has a recommendation,
   agent asked something, every candidate failed).
5. Compare the candidates, pick one, and have its branch merged back.

## Non-goals for v1

- A large node library (only the node kinds listed below).
- Sharing flows with other people, cloud runs, anything but local git repos.
- Running on Linux/Windows (MetalUI supports them; MetalFlow v1 is macOS-only —
  builder's call, because notifications and `gh`/`claude` CLIs are the target).
- A full code editor or IDE features.

## Anti-goals (would make it a failure even if it works)

- **Stealing focus.** Runs that need you notify you and wait in the Needs-you queue;
  the app never pulls you into a run or pops a window on its own.
- **Auto-merging.** The judge only recommends. The user always picks. Nothing merges
  without an explicit "Pick & merge".
- **Runs stepping on each other or on the user's checkout.** Every run, and every
  candidate inside a fan-out, works in its own git worktree.

## How it works (decided with the user)

### Runs and worktrees

- Launching a flow on a repo creates a run branch `flow/<issue>-<slug>` and a
  worktree for it, outside the user's checkout.
- A fan-out node (e.g. *Implement ×3*) gives each candidate its own branch and
  worktree off the run branch (`flow/<issue>-<slug>--a`, `--b`, `--c`; git can't hold both `x` and `x/a` as branch names).
- Picking a winner merges that candidate's branch back into the branch the run
  started from. Losing worktrees are cleaned up afterwards; until then the user can
  *Branch from here* on any of them.

### Nodes run as headless Claude Code

- A **Prompt** node runs `claude -p` in its worktree with streaming JSON output. Its
  prompt is a template whose `{placeholders}` are filled from wired inputs. Events
  stream into the node, the run card and the activity feed. A later node can resume
  an earlier node's session when it needs that context.
- A **Shell command / Gate** node runs a command (e.g. `swift test`) in each
  candidate's worktree. A failing gate marks that candidate failed; it is not
  dropped, and the user can still pick it.
- When a session asks a question or needs a permission it doesn't have, that node
  pauses, the run shows "waiting on you", a macOS notification fires, and the item
  sits in Needs-you until answered.
- Each Prompt node declares what its session may do without asking (edit files in
  its worktree, run listed commands); everything else comes back to the user.

### Node kinds in v1

Flow input · Repo (context) · Prompt (Claude Code) · Fan-out (on a Prompt node: N
candidates, model per candidate) · Shell command · Gate · Judge (recommends) · You
pick (merge).

### The Fix GitHub issue flow

Issue (flow input; fetched with `gh issue view`) + Repo → Plan (Opus) → Implement ×3
(Sonnet / Opus / Haiku, own worktrees, stop when tests pass; MetalFlow commits) → `swift test` gate →
Judge (passing tests first, then smallest diff) → You pick & merge.

### Persistence

- A flow definition is a file in the repo under `.flows/` (e.g.
  `.flows/fix-issue.flow`).
- Each run's history (inputs, node outputs, events, candidates, outcome) is kept so
  past runs can be reopened and compared.

## Screens (see mockups)

### Dashboard

- **Launch bar:** flow, issue (number or URL), repo, Launch.
- **Needs you** (first): pick a winner, agent question, gate failed on all
  candidates. Stays until acted on.
- **Working on:** flows being edited and runs being steered.
- **Running:** a card per run: issue title, flow, run branch, elapsed, step pills
  (Plan → Implement ×3 → Gate → Judge → You pick), latest log line.
- **Recently finished:** merged / discarded, when.
- **Activity feed** on the right.

### Flow Studio

- Node palette (left), pannable/zoomable dotted canvas with bezier wires (center),
  inspector for the selected node (right): model, candidate count, inputs, prompt
  template, permissions.
- Toolbar: flow name and file, a run picker ("show run 7 · #42" or definition only),
  *Launch with issue…*.
- Candidates strip: one card per candidate with tests, +/− lines, branch, judge
  recommendation highlighted, and *Pick & merge*, *View diff*, *Branch from here*.

## Constraints

- Built on MetalUI (`/Users/maxburger/Developer/MetalUI`), following its app shape
  (`metalui new` / `Examples/Jotter`): Kit library target + thin executable +
  tests, Swift 6 language mode, `@MainActor` UI, tests through `MetalUITesting`,
  tests never sleep (drive time explicitly), `swift test --no-parallel`.
- MetalUI has a pan/zoom node-canvas demo (`Sources/MetalUIDemoContent/CanvasDemo.swift`)
  to start from. It lacks: macOS notifications, tab views, resizable split panes,
  syntax-highlighted text. Build what's needed inside MetalFlow first; promote to
  MetalUI later.
- MetalNodes' graph model (`MetalNodes/MetalNodesKit/Sources/MetalNodesCore`) is
  prior art for a Codable graph model, undo and canvas geometry; borrow patterns,
  not code dependencies.
- Requires `claude` and `gh` on the PATH and an authenticated `gh`.

## Decided after review

**The user's decisions:**

- **Pick & merge merges locally when it's clean to do so.** The candidate branch is
  merged into the run's base branch with a merge commit (`--no-ff`). If the base branch
  is checked out in the user's checkout with uncommitted changes, nothing is merged:
  the user is told why and the item stays in Needs-you. Nothing is pushed. No PRs in v1.
- **Flow Studio does full graph editing.** That means adding, deleting and rewiring
  nodes from the palette, editing them in the inspector, with undo. Flows are DAGs run
  in dependency order. There are no if/else nodes in v1.

**Builder's calls (made by the designer, not the user, so check them):**

- *Questions and permissions in headless mode:* "Pause" means the session ends and is
  resumed later with `claude --resume <session-id>`, not that a live process waits
  around. Each Prompt node starts with `--allowedTools` from its permissions. A session
  whose last turn asks a question, or that was denied a tool, goes to Needs-you. The
  user's answer resumes it. **The first task is a spike** that confirms the installed
  `claude` (2.1.x) stream-json event shapes and resume behaviour before the engine is
  built on them.
- *App lifetime:* runs survive the app being in the background, not the app quitting.
  Quitting while runs are active asks for confirmation. On relaunch, interrupted nodes
  show as *interrupted* with a Resume action that uses the stored session id.
- *Data between nodes:* text only. A node's output is the final result text of its
  session, or for Shell/Gate nodes the exit code plus the output tail. Placeholders
  are filled from wired inputs. Candidates are compared through their git diffs.
- *Judge:* a Prompt node (Opus by default). Its inputs are each candidate's diff and gate
  result, plus the issue. The rubric is in its prompt: passing tests first, then the
  smallest diff. It outputs a recommended candidate and reasons. It never merges.
- *Commits:* after a candidate's session ends, the engine commits any uncommitted
  changes in its worktree, so commits never depend on the agent remembering.
- *Gate:* the command is configurable per node (default `swift test`). There is no
  automatic retry loop in v1. Every run can be cancelled. At most 4 Claude sessions run
  at once by default, and that is a setting. Prompt nodes take an optional max-turns
  limit.
- *Storage:* run history and worktrees live in `~/Library/Application Support/MetalFlow/`.
  Flow files in `.flows/` are written by the app and committed by the user, never by
  the app. The app keeps a list of known repos for the launch bar.
- *Notifications:* `UNUserNotificationCenter` needs an app bundle, so v1 includes a
  script that builds an ad-hoc-signed `MetalFlow.app`. Under plain `swift run`,
  notifications are skipped. Clicking a notification opens the app on that item. That
  is fine because the user started it.
- *Steering:* v1 steering means answering a paused node or sending a follow-up message
  to a finished node, either of which resumes its session. *Branch from here* keeps that
  candidate's worktree and makes a named local branch from it. *Working on* lists the
  flows open in Studio and runs the user has opened, until they're dismissed.
- *MetalUI:* a path dependency on `/Users/maxburger/Developer/MetalUI`, not modified in
  v1. Missing pieces (split panes, tabs, notifications) are built in MetalFlow.

## Left to the builder

- Module boundaries, type names, file layout.
- Flow file format details (JSON is fine) and where run history is stored.
- How streaming JSON events map to UI state, as long as runs keep going while the
  app is in the background and the UI never blocks.
- Exact visual styling beyond the mockups (dark theme, Inter + JetBrains Mono feel).
- How the diff view is rendered (plain monospace is acceptable for v1).
- Build order — but the engine (worktrees, running `claude -p`, run state) should be
  testable without the UI.
