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
`~/Library/Application Support/VaydeAOS/Workspace` directory in read-only mode.
Workspace writes require an explicitly selected folder.

### Migration from the two connection choices

Both saved provider identifiers, `chatGPT` and `codex`, now decode to the single
`chatGPT` provider. The previously active provider's model wins when both legacy
model fields exist. Conversations and retained API settings are preserved. Legacy
direct-chat connections start read only; explicitly selected runtime write access
is retained. New settings carry a version marker so migration is not repeated.

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

Shell/file access starts with Codex's **read-only** sandbox. The optional workspace
write setting selects **workspace-write** for the chosen folder. These are Codex's
sandbox policies; selecting a folder does not restrict every file read to that
folder. MCP servers and connected services enforce their own resource scopes;
the shell sandbox does not confine an MCP server's remote or local side effects.
Inherited tool approvals and connected-service policies still apply.

Each runtime thread explicitly selects `approvalPolicy: untrusted` and the human
approval reviewer, instead of inheriting a globally unrestricted shell policy.
Native controls support command/file approval, decline, and structured tool
questions. Unsupported MCP forms, URL elicitations, additional permission requests,
and unknown client requests fail closed. Local plugin hooks retain Codex's own
trust requirements. Desktop-specific tools can remain unavailable outside their
original host. Portable components do not imply full plugin or UI compatibility.

**Stop** sends a best-effort turn interrupt, closes the protocol connection, and
terminates the owned runtime (with a forced-exit fallback). The original prompt
returns to the composer. Completed filesystem or service actions are not rolled
back, and already dispatched external operations may finish. No retry is automatic.

## History and evidence

`~/Library/Application Support/VaydeAOS/codex-session.json` stores the thread link,
workspace/settings scope, a digest of the committed transcript, an interrupted
marker, and up to 100 activity summaries. It uses the same 0700 directory / 0600
file permissions as existing app storage. Raw command output, command lines, file
diffs, and question answers are not serialized in this app audit file. Tool detail
is available in memory during the app session. Codex keeps its own independent
thread history under its configured home, subject to its own storage policies.

Only a `turn/completed` event with status `completed` commits an assistant reply.
Failures, malformed output, disconnection, timeout, and cancellation preserve the
prompt and the last committed conversation. An interrupted marker is written
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

An opt-in real-runtime check is available:

```sh
VAYDEAOS_CODEX_SMOKE="$PWD/build/VaydeAOS.app/Contents/Resources/Codex/bin/codex" \
  ./test.sh --filter bundledRuntimeSmokeWhenExplicitlyEnabled
```

Adding `VAYDEAOS_CODEX_LIVE=1` makes one model request against the configured Codex
account, reads a marker file in a temporary read-only workspace, and checks the
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
