# Flows without a home repo: Repo node and exposed inputs

Date: 2026-10-31. Builds on `2026-10-30-metalflow-v1-design.md`.

## Why

Today a flow is tied to one repo in three ways: its file lives in that repo's `.flows/`, the Studio won't open without a selected repo, and Launch takes the repo from the launch bar. The built-in flow has a "Repo" node, but it does nothing. The user wants a flow to be a reusable thing that stands on its own. Which repo a run works on should be part of the flow, as a node. More generally, a value a node needs can come from the flow itself, from another node, or from whoever launches the flow.

## Goals

- A flow can be built, edited and saved with no repo selected.
- Flows live in a **library** by default. A repo can also **carry** its own flows in `.flows/`. On the first save of a new flow, the user chooses the destination: the library or one of the known repos. Later saves go back to the same file.
- The **Repo node** decides which repo a run works on, in one of three modes:
  - **This repo:** the repo the flow file sits in. This is the default for a flow carried by a repo.
  - **Fixed:** a repo path stored in the flow.
  - **Exposed:** asked for at launch.
- **Every node input can be fed three ways:** a wire from another node, a fixed value typed into the flow, or exposed (asked for at launch).
- Launch shows one field per exposed input, wherever you launch from: the Dashboard, the Studio, or `mflow`.

## Non-goals

- Exposing node *settings* such as the model, candidate count, allowed tools or max turns. Those stay in the flow.
- More than one repo per run.
- Syncing or sharing the library across machines.

## Anti-goals

- Existing flows and runs must not break. A flow file saved before this change loads and launches as it did before.
- A run must never start with an unfilled input. The old behaviour of leaving `{name}` literally in the prompt is now a validation error.

## Decisions (the user's)

- The Repo node has three modes: This repo, Fixed, Exposed.
- A flow carried by a repo defaults to This repo.
- Flows are stored in the library by default, and repos can carry their own. The user picks the destination when saving.
- An input can be fed by a wire, a fixed value or exposed. This applies to any node with an input.

## Design

### Inputs and bindings

A node's **inputs** are the `{name}` placeholders in its prompt (prompt and judge nodes) or its command (shell and gate nodes), as `Template.placeholders` finds them today. Each distinct placeholder name on a node is one input.

Each input has one **binding**:
- **wire:** a `Wire` whose `input` equals the name. This is how inputs are fed today.
- **fixed(value):** a string stored in the flow.
- **exposed(default?):** a launch field. If the default is nil, the field is required. Otherwise launch pre-fills the field with the default, and it may be left as the default.

Bindings are stored per node as `inputs: [String: InputBinding]`, covering the fixed and exposed cases only. A wire is still a `Wire`, so `Flow` keeps one source of truth for edges.
- A placeholder with a wire is wire-bound.
- A placeholder with an entry in `inputs` is fixed or exposed.
- A placeholder with both is a validation error.
- A placeholder with neither is a validation error: "`<node title>`: input `{name}` has no value — wire it, give it a value, or expose it."

**Exposed names are shared.** Two exposed inputs with the same name, on any nodes, are one launch field and get the same value. If their defaults differ, validation reports it. (My call; the alternative is node-qualified field names, which make a confusing launch bar.)

### Flow input node

The node keeps its job of fetching typed values. A GitHub issue is fetched with `gh` and gives the run its title and branch name. Its value is now itself an input, named by the node's `name` (e.g. `issue`), with the same three bindings except wire: either fixed or exposed. The built-in flow's Issue node is exposed, required.

More than one Flow input node is now allowed. The first Flow input in plan order names the run and its branch, as today (see the rulings below).

### Repo node

`NodeKind.repo` gets a config `RepoConfig { mode: .thisRepo | .fixed(path) | .exposed(default: path?) }`.
- A runnable flow has **exactly one** Repo node. Validation reports "A flow needs a Repo node" or "A flow can have only one Repo node." (My call: runs need a repo for branches and worktrees.)
- **This repo** is valid only for a flow carried by a repo. In the library it is a validation error: "This repo only works for a flow saved in a repo — choose Fixed or Exposed."
- **Saving and moving flows:**
  - Saving a This-repo flow into the library switches it to Exposed, with the repo it came from as the default, and shows a notice.
  - Saving a library flow into a repo leaves its mode alone.
  - A new flow in the Studio starts with a Repo node set to Exposed (no default) if it's headed for the library, or This repo if it was created from a repo context. Since the destination is chosen at first save, a new flow is Exposed until then. (My call.)
- **Resolution at launch:**
  - This repo: the git root containing the flow file.
  - Fixed: the stored path.
  - Exposed: the launch field.
- The resolved path must be a git repo, otherwise launch shows the existing error. It is added to known repos, as today.
- **Old files** decode `"repo"` with no config as `.thisRepo` when the file sits in a repo's `.flows/`, and as `.exposed(nil)` otherwise. The built-in "Fix GitHub issue" ships with Exposed.

### Library and discovery

- The library is at `~/Library/Application Support/MetalFlow/flows/*.flow`, sitting next to the run store. Exactly where it goes follows wherever RunStore keeps its data.
- The flow list (the Dashboard launch bar, Open Flow… and the Studio) is: the built-ins, then library flows, then each known repo's `.flows/`, each labelled with where it lives.
- The current "flows of the selected repo" list goes away.
- `RunEngine.flows(in:)` stays for repo folders. Add `flows(inLibrary:)` or similar, plus one function that lists everything.

### Saving

- **First save** of a draft (`url == nil`) asks where to put it: Library, or one of the known repos (with an "Add repo…" entry, which uses the folder picker coming from MetalUI's `.fileImporter` folder support). It then writes `<dest>/<slug>.flow` with the existing no-overwrite `-2` suffix.
- Later saves overwrite the same file, as today.
- "Move to…", for moving an already-saved flow, is not in scope.

### Launching

- The launch form shows: flow picker, then one field per exposed input in plan order, plus the Repo field when the Repo node is Exposed. The repo field is a picker over known repos with "Add repo…".
- A GitHub-issue field accepts a number or a URL, as today.
- Launch is disabled until every required field is filled and the resolved repo is set.
- The launch bar's separate repo picker goes away. If the flow is This repo or Fixed, the form shows the resolved repo as read-only text.
- The Studio's "Launch with issue…" becomes the same field set, as a compact row or popover.
- `RunEngine.launch(flow:repo:input:)` becomes `launch(flow:, source: FlowLocation, values: [String: String])`.
  - The engine resolves the repo and validates that every required exposed value is present (throws `missingInput(name)`).
  - It fills fixed and exposed values into the placeholders the same way wired outputs are filled.
  - `Run.inputs` records every exposed value, and `Run.repo` the resolved repo.
- `mflow launch <flow> [--repo PATH] [--set name=value]...`. Any positional argument stays as the value of the first exposed input, for backward compatibility.

### Inspector

- For each input of the selected node, the inspector shows its name and a three-way control: Wire / Value / Exposed.
  - Wire: shows the source node, or "not wired".
  - Value: a text field.
  - Exposed: an optional default field.
- Choosing Wire with no wire attached keeps it as an error until one is drawn. Drawing a wire onto an input that's set to Value or Exposed switches it to Wire.
- The Repo node's inspector has Mode (This repo / Fixed / Exposed) and a path picker for Fixed and for Exposed's default.
- The canvas marks exposed inputs, for example with a small "⇢ launch" tag on the card. (Builder's call on the visual; match the mockup style.)

### Compatibility and edge rulings (my calls, from the builder check)

- **Old flows with no Repo node.** On load, these get an implicit Repo node:
  - This repo, when the file sits in a repo's `.flows/`
  - Exposed, otherwise; this covers the built-in and runs' stored flows
  
  It's placed left of the first node. So every flow has one, and old files launch as before.
- **Where the Repo rule is checked.** The "exactly one Repo node" and "This repo only in a repo" rules are checked when launching and saving, not in `Flow.validate()`. `validate()` runs on every execute pass, including resume and retry, so putting the rule there could fail old in-flight runs. Unfilled-input checks belong to launch for the same reason. A resumed run already has its values in `Run.inputs`.
- **New flows saved into a repo.** On first save into a repo, a Repo node that is still Exposed with no default becomes This repo. This matches the user's decision that a repo-carried flow defaults to This repo. `mflow init-flow` writes the built-in into `.flows/` as This repo.
- **Launch field namespace.** There is one namespace, keyed by name.
  - Exposed placeholders and Flow input nodes share it.
  - An exposed placeholder whose name matches a Flow input node's name is a validation error: "`{issue}` is the Issue input's name — wire it from that node instead." This stops a prompt from silently getting the raw "42" while wired consumers get the fetched issue.
  - The Repo field's key is `repo`, which is reserved. An exposed placeholder named `repo` is a validation error, but a wired or fixed `{repo}` is fine.
  - `Run.inputs` records every launch value, including `repo` when it was exposed.
- **mflow launch.** The syntax is `mflow launch [VALUE] [--flow FILE|NAME] [--repo DIR] [--set name=value]...`. `mflow launch 42` keeps working.
  - `VALUE` fills the first exposed input in plan order, not counting the repo. `--set` fills any input by name.
  - `--flow` takes a path, or a name looked up across the built-ins, the library and known repos. Without `--flow`, it uses `<repo>/.flows/fix-issue.flow` if that file exists, and the built-in otherwise, as today.
  - For an Exposed repo, `--repo` fills it; with no `--repo`, the current directory's git root does, as today.
  - For This repo or Fixed, a `--repo` that resolves to a different repo is an error ("this flow always runs on <path>"). The same repo is accepted.
- **Run title and branch.** These stay as they are today:
  - A GitHub-issue input gives `#N title`.
  - A Text input gives its first 60 characters.
  - With no Flow input at all, the flow's name is used, and the branch is `flow/<slug>`.

## Constraints

- Swift and MetalUI as today. Any missing UI primitive goes to the MetalUI session, not a local workaround.
- Flow file format: additive and backward-compatible. Old files decode; new fields are optional.
- Runs saved before this change keep loading. `Run.inputs` already exists.

## Left to the builder

- Exact type names, file layout, and how the inspector lays out the three-way control.
- How to bring launch fields into the Studio toolbar.
- Test structure, following the existing harness patterns.
