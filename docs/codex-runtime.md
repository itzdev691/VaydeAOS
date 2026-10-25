# Embedded Codex runtime

VaydeAOS bundles the official `@openai/codex` native package at **0.164.0**.
The SwiftUI application owns presentation and user decisions. The separate Rust
app-server process owns the agent loop, tool execution, and Codex authentication.
It communicates over anonymous stdin/stdout pipes; no listening port is opened.
The protocol is experimental and the runtime version is pinned deliberately.

## Use

Open **Connection Settings → ChatGPT**. There is one ChatGPT account and one model
picker for conversation and agent tools. **Continue with ChatGPT** opens the
runtime's managed ChatGPT browser flow. An existing ChatGPT login in the normal
Codex home (`~/.codex`, or an explicit `CODEX_HOME`) is reused. **Refresh** reads
account status, the model catalog, configured MCP servers, and installed app
runtime availability. It does not install plugins. Catalog entries alone do not
establish model entitlement; a completed turn verifies the selected request.

The account is shared with other Codex clients using that home. **Sign out**
disconnects that shared account. ChatGPT requests explicitly select the OpenAI
provider and require a managed ChatGPT account; they never silently fall back to
an API key, a local provider, or the retired helper. Existing MCP definitions,
skills, and compatible plugin configuration are reused by the runtime. Credentials
are never copied into VaydeAOS settings, Obsidian notes, or activity summaries.

A workspace folder is optional. An unselected folder uses a private
`~/Library/Application Support/VaydeAOS/Workspace` directory. The selected folder
sets task context; it does not restrict command access.

### Migration from the two connection choices

Both saved provider identifiers, `chatGPT` and `codex`, now decode to the single
`chatGPT` provider. The previously active provider's model wins when both legacy
model fields exist. Conversations and retained API settings are preserved. Legacy
write-access flags are retained for compatibility but no longer restrict command
execution. New settings carry a version marker so migration is not repeated.

The former Node helper is no longer instantiated by ChatSession or included in
app builds. Its existing encrypted credential files are preserved without reading,
exporting, or revoking them. Users who signed in only through that helper reconnect
through the one ChatGPT panel. A former helper connection requires confirming the
displayed shared account by saving settings before its conversation can be sent;
this prevents silently choosing a different account during migration. Legacy helper
source and protocol tests remain in
the repository as historical compatibility code, outside the app's execution path.

One active task is supported. Reasoning effort applies to subsequent turns.
Changes to workspace, model, reasoning mode, or write access start a new runtime
thread with the visible conversation provided as labeled historical context.
The current user message is the only new action request. A matching saved thread
is resumed without replaying its prior tool calls. A failed resume is surfaced;
there is no automatic fresh-thread fallback or action retry.

## Permissions and cancellation

Each new or resumed runtime thread explicitly selects `sandbox: danger-full-access`
and `approvalPolicy: never`. Commands run without Codex filesystem or network
sandbox restrictions and without runtime approval prompts, using the macOS
account's existing authority. This does not grant root privileges or bypass macOS
privacy permissions. MCP servers and connected services retain their own resource
scopes and account policies. The settings panel displays full command access;
the former workspace-write toggle is no longer shown.

Native controls retain support for command/file approval, decline, and structured tool
questions. Standard MCP forms support strings, booleans, numbers, integers, and
single-choice fields. Required fields, ranges, and choices are validated before
sending typed content. Forms wait for an explicit submission or decline; no choice
is preselected. HTTPS URL elicitations display the full destination and a separate
browser link, then require explicit continuation. Unsupported schemas, device
verification, additional permission requests, and unknown client requests fail closed. Local plugin hooks retain Codex's own
trust requirements. Desktop-specific tools can remain unavailable outside their
original host. Portable components do not imply full plugin or UI compatibility.

**Stop** sends a best-effort turn interrupt, closes the protocol connection, and
terminates the owned runtime (with a forced-exit fallback). The original prompt
returns to the composer. Completed filesystem or service actions are not rolled
back, and already dispatched external operations may finish. No retry is automatic.

## History and evidence

`~/Library/Application Support/VaydeAOS/codex-<chat UUID>.json` stores each chat's thread link,
workspace/settings scope, a digest of the committed transcript, an interrupted
marker, and up to 100 activity summaries. It uses the same 0700 directory / 0600
file permissions as existing app storage. Raw command output, command lines, file
diffs, and question answers are not serialized in this app audit file. Tool detail
is available in memory during the app session. MCP errors and text results,
dynamic tool failures, command exit codes, and tool arguments appear under activity
Details; these details and form answers stay out of the app audit file. A tool
failure remains visible even if the model recovers and completes the turn.
MCP and installed-app discovery run independently, retaining each successful
catalog when the other fails. Codex keeps its own independent
thread history under its configured home, subject to its own storage policies.

Only a `turn/completed` event with status `completed` commits an assistant reply.
Failures, malformed output, disconnection, timeout, and cancellation preserve the
prompt and the last committed conversation. Interrupted attempts and any received
assistant text remain visible, explicitly marked incomplete, and are saved with
0600 permissions alongside that chat's completed turns and draft in `chat-library.json`. They survive relaunch and remain in
their original position when subsequent turns complete. They are not submitted as
completed model history, and recovery never starts a model request or repeats a
tool action automatically. **New Chat** creates a separate conversation and preserves
prior completed and interrupted history. The legacy `conversation.json`,
`interrupted-turns.json`, and `codex-session.json` are imported into the first chat
without rewriting the original files. The workspace selector below the composer
selects a separate chat group and task folder; each group remembers its selected chat.
Accounts and model settings remain shared. Stop generation before switching chats.

The stdout reader applies pipe backpressure when the UI is busy instead of dropping
queued chunks and disconnecting. It drains stdout before handling process exit,
so a final completion event cannot be overtaken by the termination callback.
Protocol failures and process exit codes are reported distinctly.

An interrupted marker is written
before the turn starts so an app crash cannot silently report success. **New Chat**
clears the app's thread link and activity, without deleting Codex's independent
runtime records or undoing tool actions.

## Packaging and validation

`build.sh` runs `scripts/prepare-codex-runtime.py`. It downloads the exact native
npm archive for Apple Silicon or Intel, checks the committed SHA-512 integrity
value, validates archive paths and rejects links, and packages the native layout
(including the Code Mode host, rg, and upstream runtime resources). Nested Mach-O
executables/libraries are signed before the outer app. Upstream LICENSE and NOTICE
are included in `Resources/Codex`. No Codex desktop installation is needed to run
the resulting app. Python 3.9+ and internet access are required for the first build.

`CodexRuntimeTests` exercises a real child-process fixture with fragmented UTF-8
frames, multiple assistant phases, tool approvals, structured input, stale and
unknown requests, failures, crashes, malformed JSON, cancellation before turn
acknowledgment, restart/resume without replay, corrupt storage, and workspace
changes. Existing chat/provider tests remain separate.
Regression fixtures also cover a slow stdout consumer during a large burst,
completion immediately followed by process exit, and interrupted text/history
surviving relaunch and an explicit follow-up without replaying previous actions.

An opt-in real-runtime check is available:

```sh
VAYDEAOS_CODEX_SMOKE="$PWD/build/VaydeAOS.app/Contents/Resources/Codex/bin/codex" \
  ./test.sh --filter bundledRuntimeSmokeWhenExplicitlyEnabled
```

A separate read-only MCP check uses the app's Swift transport and configured
Obsidian server without a model request:

```sh
VAYDEAOS_CODEX_SMOKE="$PWD/build/VaydeAOS.app/Contents/Resources/Codex/bin/codex" \
VAYDEAOS_CODEX_MCP=1 ./test.sh --filter bundledMCPReadOnlySmokeWhenExplicitlyEnabled
```

This calls only `list_allowed_directories`; it does not establish permission to
control Dock or other native apps. Host app permissions still apply, and shell
commands that create temporary files still require write permission.

Adding `VAYDEAOS_CODEX_LIVE=1` makes one model request against the configured Codex
account, reads a marker file in a temporary workspace, and checks the
reply and tool evidence. This uses account allowance; ordinary tests do not.
A successful live check establishes that specific file/tool/model path, not every
installed plugin or native UI workflow.

Before merging the connection choices on October 24, 2026, 76 Swift tests in seven suites passed,
including the opt-in live check. The bundled runtime discovered seven models and
19 integration entries; one command tool read the temporary marker file and the
completed assistant reply matched it exactly. The packaged app built successfully,
passed `codesign --verify --deep --strict`, and its native Codex settings panel
displayed the account, model selection, workspace picker, read-only default, and
integration discovery. Approval/input behavior was exercised by the child-process
fixtures; not every service integration or native approval flow was exercised live.

After merging the connections, 78 Swift tests in seven suites passed, including
legacy provider/model migration, account confirmation before forwarding an old
conversation, preservation of legacy credential files, private read-only workspace
selection, API-key isolation, and a live tool-backed marker-file read. The app built
and passed strict signature verification; the retired Node helper was absent from
the package. Native inspection of the merged panel was blocked by the locked Mac.

The October 24 disconnection fix passed 82 Swift tests in seven suites, including
the burst/exit and interrupted-history regressions. A separate live bundled-runtime
check discovered seven models and 19 integrations, executed a temporary-file read,
and verified the completed reply. The rebuilt app passed strict signature verification.
Native inspection confirmed that a recovered completed reply and an earlier
incomplete attempt were both visible in the conversation.

## Design context

Implementation follows these Obsidian proposals read on October 24, 2026:

- `VaydeAOS/Architecture/03 VaydeAOS Agent Runtime.md`: separate interface,
  planning, policy, execution, verification, and task history; one active task.
- `VaydeAOS/Trust/06 VaydeAOS Permissions and Control.md`: explicit authorization,
  untrusted retrieved content, cancellation without rollback, and action evidence.
- `VaydeAOS/Trust/07 VaydeAOS Context and Memory.md`: bounded relevant context,
  separate credential storage, and user-visible provider selection.

Those notes are planning context, not proof of implemented capabilities.

References: [Codex app-server](https://learn.chatgpt.com/docs/app-server),
[open-source components](https://learn.chatgpt.com/docs/open-source).
