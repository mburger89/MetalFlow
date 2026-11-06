# Local Models for Nodes Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an agent node run on a local model served by Ollama or LM Studio. MetalFlow runs the agent loop itself, with its own tools, instead of handing the work to the `claude` CLI.

**Architecture:** A `LocalAgentSession` implements the existing `AgentSession` protocol. It calls the server's OpenAI-compatible `POST /v1/chat/completions` with URLSession, runs the tool calls the model asks for, and loops until the model gives a final answer. Both Ollama and LM Studio serve that endpoint, so one client covers both. A router sends a request to the local session when its model name starts with `ollama:` or `lmstudio:`, and to `ClaudeCLI` otherwise. No Vapor: MetalFlow is the client of these servers, and a separate server process would add nothing.

**Tech Stack:** Swift, Swift Testing, Foundation (URLSession). MetalUI is untouched.

## Decisions

These are the planner's calls. The user approved the direct-client route ("Yes") and the Swift-only backend, not each detail.

1. **Client, not server.** MetalFlow calls Ollama (`http://localhost:11434/v1`) and LM Studio (`http://localhost:1234/v1`) directly. No Vapor, no extra process.
2. **Non-streaming v1.** One request per turn, read the full reply. Streaming is out of scope and can come later.
3. **Model names.** `ollama:<model>` and `lmstudio:<model>`, for example `ollama:qwen2.5-coder:7b`. Any other name is a Claude model, as today. The prefix is split on the first colon, so model tags with colons work.
4. **Base URLs** come from `MF_OLLAMA_URL` and `MF_LMSTUDIO_URL` (environment variables, read once at start), with the defaults above. No settings screen in v1.
5. **Tools.** `Read`, `Grep`, `Glob`, `Edit`, `Write`, and `Bash(<prefix>:*)`, using the same `allowedTools` strings the flows already use. A tool that is not allowed is denied: the model gets an error result, the name goes into `AgentResult.deniedTools`, and the turn continues. This matches how Claude's denials are reported.
6. **Paths stay inside the working directory.** Every file path is resolved against the working directory. A path that escapes it (`..`, an absolute path outside, or a symlink out) is an error result, not a read or write.
7. **Bash runs no shell.** The command is split into words, respecting simple quotes. A command containing `;`, `&`, `|`, `<`, `>`, a backtick, `$(` or a newline is refused. `Bash(git diff:*)` allows a command whose first words are `git diff`. The process runs with the working directory as its cwd, a 120-second timeout, and no inherited stdin.
8. **Sessions resume.** The transcript (messages and tool results) is stored as JSON under `<store>/local-sessions/<session-id>.json`. `resumeSessionID` loads it and appends the new prompt. The session ID is a new UUID for each fresh session.
9. **Turn limit.** `maxTurns` when the node sets one, otherwise 30. Hitting the limit ends the session with `isError: true` and says so.
10. **Cost is 0.** `costUSD` is 0 for local sessions.
11. **Question convention.** The system prompt includes the same `ClaudeCLI.questionConvention` text, so `AgentResult.question` works unchanged.
12. **UI.** The Inspector's model picker keeps its three Claude entries and gains a "Local model…" entry that opens a text field for the `ollama:` or `lmstudio:` name. The field is validated by the same prefix rule. Nothing else in the UI changes.

## Global Constraints

- Test command (zsh, literal flags): `swift test --no-parallel -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing > <scratchpad>/x.log 2>&1`, then grep the summary.
- Baseline: Core 374, Kit 446, mflow 64. Only `recordsAnIssueAtTheDeadline` may fail (Kit and Core).
- No network in tests: use a `URLProtocol` stub for the HTTP client, and a scripted fake client for the session loop.
- Commit with the messages given. No attribution trailer. Do not push.

## Task 1: HTTP chat client

**Files:** `Sources/MetalFlowCore/LocalModels/LocalChatClient.swift` (new), `Tests/MetalFlowCoreTests/LocalChatClientTests.swift` (new).

- [ ] `enum LocalProvider: String { case ollama, lmstudio }` with `baseURL` from the environment (decision 4).
- [ ] `struct ChatMessage` (role, content, optional tool calls, optional tool call id), `struct ToolCall` (id, name, arguments as JSON string), `struct ChatReply` (content, tool calls, finish reason).
- [ ] `protocol LocalChatClient: Sendable { func complete(model: String, messages: [ChatMessage], tools: [ToolSpec]) async throws -> ChatReply }`. `ToolSpec` is name, description, JSON-schema parameters.
- [ ] `URLSessionChatClient` posts to `<base>/chat/completions` with `model`, `messages`, `tools`, `stream: false`. Map HTTP errors and a missing `choices[0].message` to a thrown error that carries the server's message.
- [ ] Tests with a `URLProtocol` stub: the request body has the right shape; a tool-call reply parses; a plain reply parses; an HTTP 500 with a JSON error surfaces the message; the provider's prefix routing helper parses `ollama:qwen2.5-coder:7b` into provider `ollama` and model `qwen2.5-coder:7b`.
- [ ] Commit: `Add an HTTP client for Ollama and LM Studio`.

## Task 2: Local tools

**Files:** `Sources/MetalFlowCore/LocalModels/LocalTools.swift` (new), `Sources/MetalFlowCore/LocalModels/ToolPermissions.swift` (new), `Tests/MetalFlowCoreTests/LocalToolsTests.swift` (new).

- [ ] `ToolPermissions(allowedTools: [String])`: `allows(tool:)` for plain names, and for `Bash` with a command, prefix matching against `Bash(<prefix>:*)`.
- [ ] `LocalTools(workingDirectory:)` with `read`, `grep`, `glob`, `edit` (exact unique string replacement; error when the string is missing or not unique), `write` (create or overwrite inside the directory), and `bash` (decision 7). Each returns a string result or an error string for the model.
- [ ] Path confinement (decision 6), with tests for `..` and a symlink that points outside.
- [ ] Bash tests: an allowed prefix runs; an operator is refused; a disallowed prefix is denied; a timeout kills the process.
- [ ] Tool specs (`ToolSpec` values) for the six tools, for Task 3 to send.
- [ ] Commit: `Add the local tools with path and command limits`.

## Task 3: The local agent session

**Files:** `Sources/MetalFlowCore/LocalModels/LocalAgentSession.swift` (new), `Sources/MetalFlowCore/LocalModels/LocalTranscriptStore.swift` (new), `Tests/MetalFlowCoreTests/LocalAgentSessionTests.swift` (new).

Depends on Tasks 1 and 2.

- [ ] `LocalAgentSession(client: LocalChatClient, tools: (URL) -> LocalTools, transcripts: LocalTranscriptStore)`, conforming to `AgentSession`.
- [ ] The loop: system prompt (the question convention), then the user prompt. Send, get a reply. For each tool call, check permission (decision 5), run it, append the result as a tool message. Repeat until a reply has no tool calls, or the turn limit is hit (decision 9).
- [ ] Events: `.started(sessionID:)` first, `.text` for each assistant text, `.toolUse(name:summary:)` for each tool call, `.finished(AgentResult)` last. `deniedTools` lists the denied names.
- [ ] Transcript saved after each turn (decision 8). Resume loads it.
- [ ] Cancelling the consumer stops the loop between turns.
- [ ] Tests with a scripted fake client and tools in a temp directory: a plain answer; a tool call then an answer; a denied tool; a resume appends to the saved transcript; the turn limit ends with an error; a `QUESTION:` line sets `AgentResult.question`; cancellation stops the loop.
- [ ] Commit: `Run local models as agent sessions with resume`.

## Task 4: Routing and UI

**Files:** `Sources/MetalFlowCore/Agent/AgentRouter.swift` (new), `Sources/MetalFlowKit/App/EngineClient.swift` and `Sources/mflow/main.swift` (wire the router where `ClaudeCLI(runner:)` is built now, lines given in the Task 4 brief), `Sources/MetalFlowKit/Studio/InspectorView.swift` (decision 12), tests in `Tests/MetalFlowCoreTests`, `Tests/MetalFlowKitTests`, and `Tests/mflowTests`.

- [ ] `AgentRouter: AgentSession` sends a request to the local session when its model has a `ollama:` or `lmstudio:` prefix, and otherwise to `ClaudeCLI`. The local model name passed on is the part after the prefix.
- [ ] Wire the router in both places that build `ClaudeCLI` today (the app's engine client and `mflow`).
- [ ] Inspector: "Local model…" entry and a text field, validated by the prefix rule (decision 12). Accessibility identifiers `inspector.localModel` and `inspector.localModel.field`.
- [ ] Tests: the router picks the right session for each prefix; the Inspector entry shows the field and rejects a name without a prefix.
- [ ] Commit: `Route ollama and lmstudio models to the local agent`.

## Task 5: Live check (local, no Claude usage)

- [ ] If Ollama is installed, pull a small tool-capable model and run a flow with one agent node on `ollama:<model>`. Record the result in `docs/notes/e2e-2026-11-06-local.md`. If Ollama is not installed, say so and skip. Do not install software without asking.

## Verification

- [ ] Full suite passes apart from the known issue.
- [ ] Live check (Task 5) or a clear note that it did not run.
