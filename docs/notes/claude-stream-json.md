# claude `-p --output-format stream-json --verbose` findings

Recorded with Claude Code 2.1.314, `--model haiku`, one JSON object per line. Fixtures:
`Tests/MetalFlowCoreTests/Fixtures/{success,denied,resume}.jsonl` (no credentials; fixtures trimmed and paths replaced: init reduced to type/subtype/cwd/session_id/model, hook and rate-limit lines dropped, a placeholder `hook_started` and `thinking_tokens` line kept in success.jsonl (synthetic, to test that unknown subtypes are ignored), thinking signatures set to REDACTED, paths rewritten to /tmp/spike).

## Line types seen (`type` / `subtype`)

| type | subtype | notes |
|---|---|---|
| `system` | `hook_started`, `hook_response` | SessionStart hook noise, 3-6 lines before init. Has `session_id`. Must be ignored. |
| `system` | `init` | `session_id`, `cwd`, `model`, `permissionMode`, `tools[]`, ... |
| `system` | `thinking_tokens` | seen on resume; ignore |
| `system` | `permission_denied` | `tool_name`, `tool_use_id`, `message`, `session_id`; emitted right when a tool call is denied (one per denial, before the `user` tool_result). |
| `assistant` | none | `message.content[]` items of type `text` (`text`), `tool_use` (`id`, `name`, `input` as a JSON object), or `thinking` (`thinking`, `signature`). One content item per line. |
| `user` | none | `message.content[]` with `tool_result` (`tool_use_id`, `content` string, `is_error`) |
| `rate_limit_event` | none | ignore |
| `result` | `success` | final line, exactly one |

All lines carry `session_id` at the top level.

## Where the Task 7 fields live

- `session_id`: top level of every line, including `system/init` and `result`.
- Final text: `result.result` (string, e.g. `"OK"`, `"DONE"`).
- `is_error`: `result.is_error` (bool). Also `result.subtype` (`success`) and `terminal_reason` (`completed`).
- Cost: `result.total_cost_usd` (number).
- Turns: `result.num_turns` (int). It is per invocation: the resume call reported 1, not cumulative.
- Denials: `result.permission_denials`, an array (empty `[]` when none). Element shape:
  `{"tool_name": "Write", "tool_use_id": "toolu_...", "tool_input": {...}}`.
- `--resume <id>`: keeps the SAME session id (resume.jsonl init and result both carry the original id).

## Denial reporting

A denial is reported twice: live as a `system/permission_denied` line, and in the final `result.permission_denials[]`. The parser should treat
`result.permission_denials` as authoritative for `AgentResult.deniedTools` (single, complete, includes `tool_input`); the live lines are optional early signals and may be ignored.

## Denied case

- With the user's default `permissionMode` (`auto`, from `~/.claude/settings.json`) and `--allowedTools Read`, Write was NOT denied:
  the file was created and `permission_denials` was `[]`. So `--allowedTools` alone does not deny in auto mode.
- Retried with `--permission-mode default`: both a Bash `printf > x.txt` attempt and a Write were denied; the tool_result was an
  `is_error: true` string, the run still ended `subtype: success`, `is_error: false`, and `permission_denials` had two
  entries (`Bash`, `Write`). `denied.jsonl` is this second recording.
- Implication: ClaudeCLI should pass an explicit `--permission-mode` (probably `default`) so denial behavior does not depend on the user's settings.

## Mismatches with Task 7's assumptions

1. Denials can include tools other than the one expected (Bash fallback); `deniedTools` must be all `tool_name`s. Fine with the assumed mapping.
2. `system` lines are not only `init`: the parser must key on `subtype == "init"` and ignore other `system` subtypes (hook_*, thinking_tokens). Task 7 says "`system/init`" so this is consistent, but note the noise.
3. `assistant` content may be `thinking`; ignore it (only `text` and `tool_use` map). `tool_use.input` is a JSON object, so the summary needs re-serialization (`JSONSerialization`, sorted keys) before taking 80 chars.
4. Not in the plan: `--permission-mode default` is needed for denials to occur under an `auto` user config (see above).
5. Everything else (`session_id`, `result`, `is_error`, `total_cost_usd`, `num_turns`, `permission_denials[].tool_name`) matches.
