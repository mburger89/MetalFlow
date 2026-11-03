# MetalFlow

A macOS app and command-line tool for building repeatable flows of coding agents
and managing many runs of them at once.

A flow is like a function: define it once as a graph of steps, then launch it many
times with different inputs. A flow can send the same task to several agents, test
each result, and ask you to pick the one to keep. MetalFlow is built on
[MetalUI](https://github.com/mburger89/MetalUI) and runs agents through
[Claude Code](https://claude.com/claude-code).

> **Status: experimental.** Flow files and the command-line interface may still change.

## What's in it

- **Flow Studio:** a node canvas for building flows and inspecting runs. Drag nodes
  from the palette or press Tab to search for one, select several, and add notes
  around them.
- **Dashboard:** every run in one place, showing what needs you, what's running and
  what's finished.
- **`mflow`:** the same engine from the terminal.

Nodes cover flow inputs, the repo, agent prompts, shell commands, test gates, agent
reviews, a judge that recommends a candidate, picking a result, and opening a pull
request. Each agent works in its own git worktree, so candidates don't touch each
other or your checkout.

Two flows are built in:

- **Fix GitHub issue:** takes an issue number or URL.
- **Build a feature:** takes a text description.

Flows you save are plain files, and a repo keeps its own in `.flows/`.

## Requirements

- macOS 14 or later
- Swift 6.4
- [MetalUI](https://github.com/mburger89/MetalUI) checked out next to this repo,
  because the package depends on it by the path `../MetalUI`
- `git`
- The [`claude`](https://claude.com/claude-code) CLI, signed in
- The [`gh`](https://cli.github.com) CLI, signed in, for flows that read issues or
  open pull requests

Runs use your Claude account, so they cost whatever those agents use. Agents can edit
files in their worktrees and run the commands a node's tool list allows, so check a
flow's settings before running it on a repo you care about.

## Build

```sh
git clone https://github.com/mburger89/MetalUI.git
git clone https://github.com/mburger89/MetalFlow.git
cd MetalFlow
scripts/bundle.sh
open build/MetalFlow.app
```

`scripts/bundle.sh` builds an ad-hoc signed `build/MetalFlow.app`.

## Use the command line

Run these from inside the git repo you want the agents to work on, with `mflow` on
your `PATH`, or use `swift run --package-path <path to MetalFlow> mflow` from there.

```sh
mflow launch 12                                      # Fix GitHub issue on issue 12
mflow launch --flow "Build a feature" "Add dark mode"
mflow list
mflow show <id>
mflow pick <id> <lane>                               # keep a candidate
```

Run `mflow` with no arguments for every command and option. A run only progresses
while an `mflow` command is running, and Ctrl-C cancels it.

Run data lives in `~/Library/Application Support/MetalFlow`. Set `METALFLOW_HOME` to
use another location.

## Test

```sh
swift test --no-parallel
```

With only the Command Line Tools installed, not Xcode, point the compiler at the
testing plugin:

```sh
swift test --no-parallel -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

## License

MetalFlow is released under the [MIT License](LICENSE).
