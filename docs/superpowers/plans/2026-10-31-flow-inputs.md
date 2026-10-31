# Flow Inputs (Repo node + exposed inputs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make flows independent of any one repo. A Repo node (This repo / Fixed / Exposed) picks the repo. Every node input is fed by a wire, a fixed value, or an exposed launch field. Flows live in a library by default, or in a repo's `.flows/`.

**Architecture:**
- Core first:
  - additive model and Codable changes
  - load-time normalisation of old files
  - launch-time checks kept out of `Flow.validate()`, so in-flight runs keep resuming
  - a new `RunEngine.launch(flow:location:values:)` that resolves the repo and records every launch value in `Run.inputs`, which `templateValues` reads
- A `FlowCatalog` lists built-ins, the library and repo flows.
- Then the Kit: the launch form is driven by `LaunchField`s, saving asks for a destination, and the inspector edits bindings. The CLI comes last.

**Tech Stack:** Swift 6.4, SwiftPM, MetalFlowCore, MetalFlowKit on MetalUI (`../MetalUI`), Swift Testing, MetalUITesting.

**Spec:** `docs/superpowers/specs/2026-10-31-flow-inputs-design.md` (builds on `docs/superpowers/specs/2026-10-30-metalflow-v1-design.md`). MetalUI API facts: `docs/notes/metalui-api.md`.

## Global Constraints

- Run the tests with `swift test --no-parallel -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`. Every suite passes at the end of every task. The baseline is Kit 210 and Core 149.
- Flow file format: stays `formatVersion` 1, and every change is additive. Files written before this plan must decode. Runs saved before this plan must decode, resume and retry.
- `Flow.validate()` must accept every flow it accepted before. The new launch rules live in `Flow.launchFields(location:)`, not in `validate()`.
- Tests never sleep, never run real `claude`, `gh` or `git` (use the existing fakes), and never touch real Application Support. Kit fixtures use `waitUntilReady()` and `waitUntil`.
- Kit UI:
  - Every interactive element has an `.accessibilityIdentifier`.
  - Ids go on leaves or on `.accessibilityElement(children: .contain)` containers.
  - Menu Pickers are driven by `window.click` → `presentedMenu` → `chooseMenuItem`.
- MetalUI gaps: if an API is missing or broken, stop and report it. Don't patch `../MetalUI` and don't work around it. "Add repo…" inside the new pickers waits for MetalUI's folder `.fileImporter` and is **out of scope here**. Adding repos stays on the Dashboard's existing field.
- Commits end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_0195iKYn69jgc6AKCLYiUKab
  ```
- The issue-input error strings, and the existing user-visible strings that tests assert, stay unchanged unless a task says otherwise.

## Review Focus

1. **A pre-plan flow file loads and launches exactly as before.** This covers a file with a bare `"repo"` node and a file with no Repo node, each in `.flows/`. Owned by Task 1 (`legacyFlowFileLoadsWithThisRepo`, `flowWithoutRepoNodeGetsOne`) and Task 3 (`legacyFlowLaunchesOnSameRepo`).
2. **A run saved before this plan, waiting or interrupted, resumes after upgrade.** Its stored flow has no bindings, so `validate()` and `templateValues` behave the same. Owned by Task 3 (`preplanRunResumes`).
3. **An exposed or fixed value with shell metacharacters fills a shell or gate command quoted.** Owned by Task 3 (`exposedValueIsShellQuoted`).
4. **The same exposed name on two nodes with different defaults** is a launch error, not a silent pick. Owned by Task 2 (`conflictingDefaultsRejected`).
5. **A This-repo flow saved into the library launches.** It becomes Exposed with its origin repo as the default, and launches without the user typing a repo. Owned by Task 4 (`thisRepoSavedToLibraryBecomesExposedWithDefault`) and Task 5 (`launchFormPrefillsRepoDefault`).

---

### Task 1: Core model — Repo config, input bindings, Codable compatibility

**Files:**
- Modify: `Sources/MetalFlowCore/Graph/Flow.swift`, `Sources/MetalFlowCore/Graph/FlowFile.swift`, `Sources/MetalFlowCore/Graph/BuiltinFlows.swift`
- Test: `Tests/MetalFlowCoreTests/FlowFileTests.swift`, plus a new `Tests/MetalFlowCoreTests/FlowModelTests.swift`

**Interfaces (produces):**
```swift
public enum RepoMode: Codable, Hashable, Sendable { case thisRepo; case fixed(path: String); case exposed(default: String?) }
public struct RepoConfig: Codable, Hashable, Sendable { public var mode: RepoMode }
public enum InputBinding: Codable, Hashable, Sendable { case fixed(String); case exposed(default: String?) }
// NodeKind: `case repo` becomes `case repo(RepoConfig)`.
// Node gains `public var inputs: [String: InputBinding]` (default [:]), decoded with decodeIfPresent.
// FlowInputConfig gains `public var binding: InputBinding` (default .exposed(default: nil)), decoded with decodeIfPresent.
extension Flow {
    /// Distinct placeholder names of a node's prompt or command, in order of first appearance. A judge's `candidates` is excluded.
    public func inputNames(of id: NodeID) -> [String]
    /// The Repo nodes of the flow.
    public var repoNodes: [Node] { get }
}
public enum FlowFile {
    public static func load(from url: URL) throws -> Flow   // now normalises; see Step 3
}
```

- [ ] **Step 1: Write failing tests.**
  - `legacyRepoNodeDecodes`: decoding a node JSON written by the pre-plan encoder (`"kind": {"repo": {}}`) gives `.repo(RepoConfig(mode: .thisRepo))`.
  - `legacyFlowInputDecodes`: decoding a `flowInput` without `binding` gives `.exposed(default: nil)`. A node without `inputs` gives `[:]`.
  - `repoConfigRoundTrips`: each `RepoMode` encodes and decodes unchanged.
  - `legacyFlowFileLoadsWithThisRepo`: a fixture file in `<tmp>/repo/.flows/x.flow` with a bare repo node loads as `.thisRepo`.
  - `legacyFlowOutsideFlowsDirLoadsExposed`: the same file outside a `.flows` folder loads as `.exposed(default: nil)`.
  - `flowWithoutRepoNodeGetsOne`: a `.flows` file with no repo node loads with exactly one Repo node.
    - Its id is `repo`, or `repo2` if `repo` is taken.
    - Its title is "Repo" and its mode is `.thisRepo`.
    - Its position is `x = minX - 240, y = minY` of the existing nodes, or `(24, 24)` for an empty flow.
    - It has no wires.
  - `inputNamesListsPlaceholders`: for a prompt `"{a} {b} {a}"` the result is `["a", "b"]`. For a judge prompt with `{candidates}` and `{x}` the result is `["x"]`.
  - `builtinRepoIsExposed`: `BuiltinFlows.fixGitHubIssue`'s repo node is `.exposed(default: nil)`.
- [ ] **Step 2: Run them and confirm they fail.** The behaviour tests should fail, not only fail to compile. Add the types with stub behaviour first if needed.
- [ ] **Step 3: Implement.**
  - **Encoding.** `NodeKind` keeps Swift's synthesized enum encoding for every case, so existing files are byte-compatible. Give it a custom `init(from:)` that decodes `repo` with or without its `_0` payload; a missing payload means `RepoConfig(mode: .thisRepo)`.
  - **`FlowFile.load` normalisation.** After decoding, check whether `url.deletingLastPathComponent().lastPathComponent == FlowFile.directoryName`.
    - If it is not, map every `.thisRepo` to `.exposed(default: nil)`.
    - If the flow has no Repo node, insert one, using `.thisRepo` inside `.flows` and `.exposed(nil)` outside.
  - **`FlowFile.save`** is unchanged.
  - **Call sites.** Update every `case .repo` pattern in Core and Kit (`case .repo:` becomes `case .repo:` with a wildcard payload). Behaviour must not change.
- [ ] **Step 4: Run the full suite.** It all passes.
- [ ] **Step 5: Commit** with the message "Repo node config and input bindings, with legacy decoding".

### Task 2: Launch fields and launch-time checks

**Files:**
- Create: `Sources/MetalFlowCore/Graph/FlowLaunch.swift`
- Modify: `Sources/MetalFlowCore/Graph/FlowValidation.swift`
- Test: create `Tests/MetalFlowCoreTests/FlowLaunchTests.swift`; also `FlowValidationTests.swift`

**Interfaces (produces):**
```swift
public enum FlowLocation: Hashable, Sendable {
    case builtin
    case unsaved
    case library(file: URL)
    case repo(root: URL, file: URL)
    /// `.repo` when the file's folder is named `.flows` (root = its parent), otherwise `.library`.
    public static func of(file: URL) -> FlowLocation
}
public struct LaunchField: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case text, githubIssue, repo }
    public var name: String          // "repo" for the repo field
    public var kind: Kind
    public var defaultValue: String?
    public var isRequired: Bool { defaultValue == nil }
}
public enum LaunchError: Error, Equatable, Sendable {
    case invalid(FlowError)
    case noRepoNode, multipleRepoNodes
    case thisRepoOutsideRepo
    case exposedShadowsFlowInput(NodeID, String)   // exposed placeholder named like a Flow input
    case reservedName(NodeID)                      // exposed placeholder named "repo"
    case conflictingDefaults(String)
}
extension Flow {
    /// Runs validate(), then the launch rules. Returns one field per exposed name, in plan order: Flow inputs
    /// and exposed placeholders in the order their nodes appear in the plan, with the repo field last.
    public func launchFields(location: FlowLocation) throws(LaunchError) -> [LaunchField]
}
// New FlowError cases, replacing the role of `.unwiredPlaceholder` for unbound inputs:
//   case unboundInput(NodeID, String)      // no wire and no binding
//   case inputBoundTwice(NodeID, String)   // a wire and a binding
```

- [ ] **Step 1: Write failing tests.**
  - `validateAcceptsBoundInput`: a prompt `{x}` with `inputs["x"] = .fixed("v")` and no wire validates.
  - `unboundInputRejected`: with no wire and no binding, validation throws `.unboundInput(id, "x")`. Keep the old `unwiredPlaceholder` message text for this case so existing assertions hold, or update them in this task, and list them.
  - `inputBoundTwiceRejected`: a wire plus a binding throws `.inputBoundTwice`.
  - `builtinLaunchFields`: the built-in at `.builtin` gives `[issue (githubIssue, required), repo (repo, required)]`.
  - `thisRepoRejectedInLibrary`: `.thisRepo` at `.library` throws `.thisRepoOutsideRepo`. At `.repo` it's fine, and there's no repo field.
  - `fixedRepoHasNoField`: a `.fixed` repo produces no repo field.
  - `noRepoNodeRejected` / `twoRepoNodesRejected`.
  - `exposedShadowingFlowInputRejected`: a prompt `{issue}` exposed, plus a Flow input named `issue`, throws `.exposedShadowsFlowInput`.
  - `exposedRepoNameReserved`: an exposed `{repo}` throws `.reservedName`. A wired `{repo}`, as in the built-in, is fine.
  - `sharedExposedNameIsOneField`: two nodes each expose `{env}` with the same default and give one field.
  - `conflictingDefaultsRejected`: the same name with defaults "a" and "b" throws `.conflictingDefaults("env")`.
  - `fixedFlowInputHasNoField`: a Flow input with `.fixed("42")` produces no field.
  - `locationOfFile`: `<r>/.flows/a.flow` gives `.repo(root: r, file:)`, and `<lib>/a.flow` gives `.library`.
- [ ] **Step 2: Run them and confirm the RED is behavioural.**
- [ ] **Step 3: Implement.** In `validate()`, replace the placeholder loop. Use `inputNames(of:)` for each node:
  - wired and bound → `inputBoundTwice`
  - neither → `unboundInput`
  - `.flowInput`, `.repo` and `.pick` have no placeholder inputs.

  Pre-plan flows have no bindings and every placeholder wired, so they validate exactly as before. Add a test for that, `preplanFlowsStillValidate`, run against the built-in and every Core fixture flow.
- [ ] **Step 4: Run the full suite.** It all passes.
- [ ] **Step 5: Commit** with the message "Launch fields and launch-time flow checks".

### Task 3: Engine launch with values; templates read bindings

**Files:**
- Modify: `Sources/MetalFlowCore/Run/RunEngine.swift`, `Sources/MetalFlowCore/Run/RunEngine+Nodes.swift`
- Modify (to keep the build green): `Sources/MetalFlowKit/App/EngineClient.swift`, the Kit fakes in `Tests/MetalFlowKitTests/Support`, `AppModel.launch` / `launchGuarded`, and `Sources/mflow/main.swift`
- Test: create `Tests/MetalFlowCoreTests/RunEngineLaunchValuesTests.swift`; also `RunEngineTests.swift`

**Interfaces:**
```swift
// RunEngineError gains: missingInput(String), repoMismatch(expected: URL), launch(LaunchError)
extension RunEngine {
    /// Replaces launch(flow:repo:input:). `values` maps launch-field names to values; "repo" is the repo path.
    public func launch(flow: Flow, location: FlowLocation, values: [String: String]) async throws -> RunID
}
// EngineClient.launch(flow:repo:input:) becomes launch(flow:location:values:) everywhere.
```

Launch algorithm (the order matters):
1. `let fields = try flow.launchFields(location:)`, wrapping a `LaunchError` in `.launch`.
2. Resolve the repo:
   - `.thisRepo` gives the location's root.
   - `.fixed(p)` gives `p`.
   - `.exposed(d)` gives `values["repo"] ?? d`, or throws `missingInput("repo")`.
   - For This repo and Fixed: if `values["repo"]` is present and its standardized, symlink-resolved path differs from the resolved repo, throw `repoMismatch`.
3. For every field, compute `value = values[name] ?? defaultValue`, or throw `missingInput(name)`. Fixed Flow inputs use their fixed value.
4. Every Flow input node, in plan order, becomes a succeeded first node, as today: GitHub-issue inputs are fetched, text inputs passed through. The **first** Flow input in plan order sets the title, issue and branch exactly as the code does today.
5. `Run.inputs` gets every resolved field value, including `repo` when exposed, and every fixed Flow input value.
6. The rest is unchanged: worktree, lock, persist.

`templateValues`: after the wired values, for each `(name, binding)` in `node.inputs`:
- `.fixed(v)` gives `v`.
- `.exposed` gives `run.inputs[name] ?? default ?? ""`.

Shell and gate nodes already quote everything through `Template.shellQuote`; keep that.

Kit and CLI changes in this task are mechanical and keep today's UI:
- `launchGuarded` builds `values: [firstFieldName: typed, "repo": repo.path]` with `location: .unsaved`.
- The dashboard passes the flow file's `FlowLocation.of(file:)`, or `.builtin`.
- `mflow launch` passes `[first field: positional, "repo": resolved repo]` with `FlowLocation.of(file: flowURL)`.

- [ ] **Step 1: Write failing tests**, with the existing fake runner, agent and issues:
  - `launchResolvesExposedRepo`: the built-in with `values ["issue": "7", "repo": tmpRepo]` gives `run.repo == tmpRepo`, and `run.inputs` holds `issue` and `repo`.
  - `launchMissingRequiredThrows`: no `issue` throws `missingInput("issue")`.
  - `launchUsesExposedDefault`: an exposed `{env}` with default "dev" fills the prompt with "dev" (assert the prompt text the fake agent received).
  - `fixedInputFillsPrompt`: `.fixed("hello")` reaches the agent's prompt.
  - `exposedValueIsShellQuoted`: an exposed value `a'; rm -rf /` in a shell node's command arrives as one quoted word (assert the fake runner's argv or command string).
  - `thisRepoUsesLocationRoot`: a flow at `.repo(root: R, file:)` launches on R. Passing `values["repo"] = other` throws `repoMismatch`.
  - `legacyFlowLaunchesOnSameRepo`: a pre-plan `.flows` file, loaded through `FlowFile.load` and launched with the same repo, gives the same `run.repo`, title and branch as on master. Compare against literal expected values.
  - `textInputKeepsTitle`: a `.text` Flow input titles the run with its first 60 characters, as today.
  - `preplanRunResumes`: a stored run JSON from before the plan, at needs-you or interrupted, decodes and resumes to completion with the same filled prompts. Add a fixture under `Tests/MetalFlowCoreTests/Fixtures`.
- [ ] **Step 2: Run them and confirm a behavioural RED.**
- [ ] **Step 3: Implement**, then update the Kit and CLI call sites so everything builds. Existing Kit and Core launch tests keep passing unchanged, apart from call-site updates.
- [ ] **Step 4: Run the full suite.** It all passes.
- [ ] **Step 5: Commit** with the message "Launch with named values; templates read fixed and exposed inputs".

### Task 4: Library, catalog, and save normalisation

**Files:**
- Create: `Sources/MetalFlowCore/Graph/FlowCatalog.swift`
- Modify: `Sources/MetalFlowCore/Run/RunStore.swift`, `Sources/MetalFlowCore/Run/RunEngine+Retry.swift` (where `flows(in:)` lives), `Sources/MetalFlowKit/App/EngineClient.swift`, and the fakes
- Test: create `Tests/MetalFlowCoreTests/FlowCatalogTests.swift`

**Interfaces:**
```swift
extension RunStore { public var flowsDirectory: URL { get } }   // <root>/flows
public struct FlowEntry: Hashable, Sendable, Identifiable {
    public var id: String           // file path, or "builtin:<name>"
    public var name: String         // the flow's name (read from the file), or the file stem if it can't be read
    public var location: FlowLocation
    public var file: URL?           // nil for built-ins
}
public enum FlowCatalog {
    /// Built-ins, then library flows (sorted by file name), then each repo's `.flows` (repos in the given order).
    public static func entries(library: URL, repos: [URL]) -> [FlowEntry]
    /// Prepares `flow` for saving at `destination`, returning the flow to write and an optional notice.
    /// Library: `.thisRepo` becomes `.exposed(default: origin?.path)`, with notice
    ///   "Saved to the library: the repo is now asked at launch (defaults to <name>)."
    /// Repo: `.exposed(default: nil)` becomes `.thisRepo`, with no notice. Every other mode is unchanged.
    public static func prepareForSave(_ flow: Flow, destination: FlowLocation, origin: URL?) -> (Flow, String?)
    /// The file to write a new flow named `name` into `directory`: `<slug>.flow`, or `-2`, `-3`… when taken. Never overwrites.
    public static func newFileURL(name: String, in directory: URL) -> URL
}
// EngineClient gains: func flowCatalog() -> [FlowEntry]   (library = store.flowsDirectory, repos = knownRepos())
//                     var libraryDirectory: URL { get }
```

- [ ] **Step 1: Write failing tests.**
  - `catalogOrdersBuiltinsLibraryRepos`
  - `catalogReadsFlowNames`
  - `catalogSkipsMissingRepoFolder`
  - `thisRepoSavedToLibraryBecomesExposedWithDefault`
  - `exposedSavedToRepoBecomesThisRepo`
  - `fixedUnchangedOnSave`
  - `newFileURLNeverOverwrites`: move the logic from `AppModel.newFlowURL` here, and make the Kit call it.
- [ ] **Step 2: Confirm RED.**
- [ ] **Step 3: Implement.** Make `AppModel.newFlowURL` delegate to `FlowCatalog.newFileURL`.
- [ ] **Step 4: Run the full suite.**
- [ ] **Step 5: Commit** with the message "Flow library, catalog, and save normalisation".

### Task 5: Dashboard launch form driven by launch fields

**Files:**
- Modify: `Sources/MetalFlowKit/Dashboard/AppModel+Dashboard.swift` (`LaunchForm`, `launchFromForm`, `launchGuarded`, the repo scan), `Sources/MetalFlowKit/Dashboard/LaunchBar.swift`, `Sources/MetalFlowKit/App/AppModel.swift` (`repoFlows` becomes `catalog: [FlowEntry]`)
- Test: `Tests/MetalFlowKitTests/DashboardTests.swift`

**Interfaces:**
```swift
public struct LaunchForm {   // replaces the repo/flow/issue trio
    public var flow: FlowEntry.ID?
    public var values: [String: String]   // typed values, keyed by field name
    public var newRepoPath = ""           // the existing Add repo field, unchanged
}
extension AppModel {
    public var catalog: [FlowEntry] { get }                 // refreshed on start, after add-repo, and after save
    public var launchFields: [LaunchField] { get }          // for the selected entry; [] if it fails, plus launchError: String?
    public var canLaunch: Bool { get }                      // every required field filled (trimmed)
    public func launchFromForm() async -> RunID?            // same isLaunching guard and snapshot semantics as today
}
```

UI:
- **Flow picker** (`launch.flow`): a menu listing the catalog entries as "`name` — Library", "`name` — `<repo folder name>`" or "`name` — Built-in".
- **One control per field, in order:**
  - text and githubIssue fields: a `TextField` with id `launch.field.<name>`, placeholder = name, pre-filled with the default
  - the repo field: a menu Picker over the known repos, id `launch.field.repo`, pre-selected to the default when it's a known repo
- **This repo or Fixed flows:** a read-only Text (id `launch.repo.resolved`) shows the repo folder name.
- **Launch** (`launch.go`) is disabled unless `canLaunch`.
- **Errors:** an invalid flow shows `launchError` (id `launch.error`) in `Palette.bad`.
- The separate repo picker that scoped the flows goes away.
- The Add-repo field stays as it is.

- [ ] **Step 1: Write failing tests**, with the FakeEngineClient's catalog seeded:
  - `launchBarListsCatalog` (assert the rendered menu items)
  - `builtinShowsIssueAndRepoFields`
  - `launchDisabledUntilRequiredFilled`
  - `launchFormPrefillsRepoDefault`
  - `thisRepoFlowShowsResolvedRepo`
  - `launchPassesValuesAndLocation` (assert what the fake's `launch` received)
  - `invalidFlowShowsLaunchError`
  - the existing `doubleSubmitLaunchesOnce`, adapted
- [ ] **Step 2: Confirm RED.** **Step 3: Implement.** **Step 4: Run the full suite.**
- [ ] **Step 5: Commit** with the message "Launch form driven by the flow's launch fields".

### Task 6: Studio without a repo, save destination, and Studio launch

**Files:**
- Modify: `Sources/MetalFlowKit/Studio/AppModel+Studio.swift`, `Sources/MetalFlowKit/Studio/StudioView.swift`, `Sources/MetalFlowKit/Studio/FlowDraft.swift` (where `repo` becomes `location: FlowLocation`), `Sources/MetalFlowKit/App/OpenFlowPanel.swift`, `Sources/MetalFlowKit/App/Commands.swift` (New Flow)
- Test: `StudioViewTests.swift`, `FlowEditingTests.swift`, `CommandTests.swift`

Behaviour:
- **Opening the Studio.** The Studio always opens:
  - with no draft, it creates a draft of the built-in at `.unsaved`
  - the "Add a repo…" empty state (`studio.empty`) goes away
  - New Flow (⌘N) no longer needs a repo
- **A new flow** starts with one Repo node at `.exposed(default: nil)`, id `repo`, at (24, 24), and nothing else.
- **First save** of a draft whose location is `.unsaved` or `.builtin` shows an in-window destination panel, like `openFlow.panel`, with id `save.panel`:
  - buttons `save.dest.library`, then `save.dest.<repo folder name>` for each known repo, then `save.cancel`
  - Escape cancels
  - choosing one runs `FlowCatalog.prepareForSave`, writes to `newFileURL(name:, in: library or <repo>/.flows)`, sets `draft.location`, records `lastSavedFlow`, and refreshes the catalog
  - the notice, if any, goes to `model.notice`
- **Later saves** write to the same file, as today.
- **Dirty-switch and quit "Save"** on an unsaved draft go through the same panel. If the user cancels the panel, the pending action is cancelled too.
- **Open Flow… (⌘O)** lists `catalog` grouped as the flow picker labels them. Ids are `openFlow.<entry id's last path component>` and `openFlow.builtin`.
- **Studio launch row** (replaces "Launch with issue…"): one control per `launchFields(location: draft.location)`, the same controls as Task 5. Ids are `studio.field.<name>`, and the button is `studio.launch`. It goes through `launchGuarded` with the draft's location and values. Unsaved drafts launch at `.unsaved`, where This repo is invalid; that's correct, because a new draft is Exposed.
- **The Studio run picker** matches runs on `flow.name` only. `draft.repo` no longer exists.

- [ ] **Step 1: Write failing tests:**
  - `studioOpensWithoutRepo`
  - `newFlowWithoutRepo`
  - `firstSaveAsksDestination`
  - `saveToLibraryWritesThere`
  - `saveToRepoMakesThisRepo`
  - `saveCancelKeepsDraftUnsaved`
  - `dirtySwitchSaveOnUnsavedAsksDestination`
  - `openFlowListsCatalog`
  - `studioLaunchUsesFields`
  - Update or remove `emptyStudioWithoutRepo`, and say so in the report.
- [ ] **Step 2: Confirm RED.** **Step 3: Implement.** **Step 4: Run the full suite.**
- [ ] **Step 5: Commit** with the message "Studio works without a repo; first save picks a destination".

### Task 7: Inspector — input bindings and Repo node

**Files:**
- Modify: `Sources/MetalFlowKit/Studio/InspectorView.swift`, `Sources/MetalFlowKit/Studio/FlowDraft.swift` (edit helpers), `Sources/MetalFlowKit/Studio/NodeCardView.swift` (exposed tag)
- Test: `FlowEditingTests.swift`

Behaviour:
- **An "Inputs" section** for prompt, judge, shell and gate nodes, with one row per `flow.inputNames(of:)`:
  - The row shows the name and a segmented Picker with Wire, Value and Exposed. The id is `inspector.input.<name>`, and its segments use MetalUI segment ids `inspector.input.<name>.wire|value|exposed`.
  - **Wire:** shows the source node title, or "not wired" in `Palette.bad`, with id `inspector.input.<name>.source`.
  - **Value:** a TextField with id `inspector.input.<name>.value`.
  - **Exposed:** a TextField for an optional default, with id `inspector.input.<name>.default` and placeholder "no default (required)".
- **Switching modes:**
  - to Value or Exposed removes any wire into that input, and sets `node.inputs[name]`
  - to Wire removes `node.inputs[name]`
  - Each switch is one undo step. Typing into a field coalesces, as today.
- **Wires and bindings:** drawing a wire onto an input that has a binding removes the binding, in the same undo step as the new wire. This rule lives in `FlowDraft.connect`.
- **Flow input node:** a "Value" row with Fixed or Exposed (no Wire), ids `inspector.flowInput.mode` and `inspector.flowInput.value`.
- **Repo node:**
  - a Mode menu Picker (This repo / Fixed / Exposed), id `inspector.repo.mode`
  - For Fixed and for the Exposed default: a menu Picker over the known repos, id `inspector.repo.path`, plus a TextField for a typed path, id `inspector.repo.pathField`.
- **Node cards** show a small "⇢ launch" Text (id `node.<id>.exposed`) when any input is exposed, in `Palette.accent` at size 10 × zoom. NodeCardView stays `Equatable`; the tag derives from `node`.
- **Studio validation banner:** shows `launchFields(location:)` errors too, using `LaunchError`'s readable text. Add `errorDescription` for every `LaunchError` case, with the spec's wording.

- [ ] **Step 1: Write failing tests:**
  - `inspectorListsInputs`
  - `switchToValueRemovesWire`
  - `switchToExposedSetsBinding`
  - `wireOntoBoundInputClearsBinding`
  - `bindingSwitchIsOneUndoStep`
  - `repoModePickerSetsMode`
  - `exposedTagShowsOnCard`
  - `launchErrorShowsInBanner`
- [ ] **Step 2: Confirm RED.** **Step 3: Implement.** **Step 4: Run the full suite.**
- [ ] **Step 5: Commit** with the message "Inspector edits input bindings and the Repo node".

### Task 8: `mflow` CLI syntax

**Files:**
- Modify: `Sources/mflow/Commands.swift` (`Arguments`, `parseArguments`, usage), `Sources/mflow/main.swift`
- Create: `Sources/MetalFlowCore/Graph/LaunchArguments.swift`. No test target imports `mflow`, so the pure logic goes in Core: `LaunchArguments.parseSet(_ s: String) throws -> (String, String)` and `FlowCatalog.resolve(flowArgument: String, entries: [FlowEntry]) throws -> FlowEntry`. `mflow` calls them.
- Test: create `Tests/MetalFlowCoreTests/LaunchArgumentsTests.swift`.

Syntax:
```
mflow launch [VALUE] [--flow FILE|NAME] [--repo DIR] [--set name=value]...
```
- **`VALUE`** fills the first non-repo launch field.
- **`--set`** can be repeated. A malformed `--set` exits 64 with "expected --set name=value".
- **`--flow`:**
  - a path to an existing file is loaded with its `FlowLocation.of(file:)`
  - otherwise it is matched as a name, case-insensitively, against `FlowCatalog.entries`
  - several matches is an error that lists them
  - no `--flow` keeps today's default: `<repo>/.flows/fix-issue.flow` if that exists, else the built-in
- **`--repo`** fills an Exposed repo. With no `--repo`, the current directory's git root fills it, as today. For This repo or Fixed flows it is checked: a different repo exits with the engine's `repoMismatch` message, "this flow always runs on <path>".
- **`init-flow`** writes the built-in prepared with `prepareForSave(destination: .repo(...))`, so its repo node is This repo.
- **Usage text** documents all of the above.

- [ ] **Step 1: Write failing tests:**
  - `parsesRepeatedSet`
  - `badSetFails`
  - `flowByName`
  - `flowNameAmbiguous`
  - `positionalFillsFirstField`
  - `repoMismatchForFixedFlow`
  - `initFlowWritesThisRepo`
- [ ] **Step 2: Confirm RED.** **Step 3: Implement.** **Step 4: Run the full suite.**
- [ ] **Step 5: Commit** with the message "mflow launch takes --flow names, --set values, and checks --repo".
