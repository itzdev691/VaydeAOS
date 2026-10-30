# VaydeAOS

A native macOS command center written in Swift and SwiftUI, with a VaydeNet navy, blue, and red
console, live system instruments, and an integrated model chat channel. Connection settings support
local Ollama and servers that implement the OpenAI-compatible Chat Completions
API. One **ChatGPT** connection supports conversation and agent tools through the
bundled Codex runtime, with browser sign-in and eligible ChatGPT plan usage.

## Build and run

Requires macOS 13 or later and Swift 6 or later from Xcode Command Line Tools
(`xcode-select --install`). No external Swift packages are required.
The build uses Python 3.9+ to download a checksum-pinned official Codex runtime
from npm. Internet access is required for the first build. The runtime is bundled;
users need no separate Codex or Node installation.

From the repository root:

```sh
./build.sh
open build/VaydeAOS.app
```

Use `./build.sh release` for an optimized build. The script packages the SwiftPM
executable into a macOS `.app` and signs it locally. Distribution signing and
notarization are separate from this local development build.

To package a review build without replacing the running app bundle:

```sh
VAYDEAOS_APP_DIR="$PWD/build/workspace-review/VaydeAOS.app" ./build.sh
```

This builds and signs the separate bundle without launching or restarting the app.

## Background app

VaydeAOS runs as a menu-bar app. Closing its window keeps voice, model requests,
project consoles, and serial connections running. **Open VaydeAOS** in the menu bar
reopens the workspace; **Hide Window** returns it to the background. Opening the
app again from Finder or Spotlight also restores the window. It has no running
Dock tile. **Quit VaydeAOS** exits and shuts down its services.

**Launch at Login** in the menu-bar menu uses macOS Login Items. Its switch reflects
the system setting; VaydeAOS does not register itself until you enable it. If macOS
requires approval, the menu links to Login Items settings. Login launches keep the
workspace hidden. `open -a VaydeAOS --args --background` also starts it without a
workspace window. Dashboard animations, system-audio visualization, and repository
polling stop while the window is hidden; active requests and console jobs continue.

## Vayde Voice

Voice starts enabled and requests macOS microphone and speech-recognition access on
the first launch. Say **“Hey Vayde”**, wait for **“Yes?”**, then speak a request.
Vayde sends it through the current chat's model and tools and reads its answer aloud.
The microphone button and the menu bar's **Vayde Voice** submenu show status and listening controls.

Standby uses the native macOS command recognizer; full on-device English dictation
runs only after activation. There is no cloud transcription fallback, and no audio
is saved. Request text and the current conversation go to the selected AI provider.
Always listening requires CPU, memory, and microphone access; it cannot use zero
system resources. Idle resource usage has not been benchmarked.

Closing the window keeps Vayde Voice running. Quitting stops it. Voice pauses while
the Mac is locked or asleep, during typed requests, and during its own speech.
Launch at Login is optional. Typed drafts are preserved;
failed voice attempts remain visible in chat. See [voice behavior and validation](docs/voice-assistant.md).

## Apple UI CI/CD

[Apple UI CI/CD](.github/workflows/apple-ui.yml) runs on pull requests targeting
`main`, pushes to `main` or `codex/**`, version tags (`v*`), and manual dispatch.
It uses [GitHub's macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
on Apple Silicon and Intel to run the Swift tests, build the release SwiftUI app,
and validate bundle resources and its ad-hoc signature. Both jobs use macOS 26
with Xcode 26.5 explicitly selected through `DEVELOPER_DIR`. An initial check
requires Apple Swift 6.3.2 so runner defaults cannot silently change the compiler.
Native window startup is
smoke tested on Apple Silicon. The hosted Intel runner aborted inside Metal with
`Target device architecture is nil` during the [initial runtime check](https://github.com/itzdev691/VaydeAOS/actions/runs/39870566994/job/120143812714),
so Intel UI runtime remains unverified and its job reports this coverage limit.
The smoke test requires a logged-in desktop and checks that the app keeps a main
window for ten seconds across macOS Spaces; interaction tests and visual layout checks remain manual.

Successful runs provide architecture-specific `.app` ZIPs and SHA-256 checksums
under **Actions → Apple UI CI/CD → Artifacts**, retained for 14 days. Validation
logs are retained for seven days, including on failure. These are development
packages signed ad-hoc, without Developer ID signing or Apple notarization.
The workflow does not publish App Store builds or GitHub Releases and requires
no Apple signing secrets.

Check names are `Apple UI (arm64)` and `Apple Build (x86_64)`. They can be selected
as required status checks after the workflow has been pushed and run on GitHub.

## Connect a model

Open **Connection Settings → ChatGPT**. One account and model selection serve
conversation and agent tools. **Continue with ChatGPT** connects the account;
**Manage usage** opens ChatGPT usage settings. An existing ChatGPT account in
Codex on this Mac is reused. Signing out disconnects that shared account.

The workspace folder is optional. Without one, the runtime uses a private
chat workspace. Selecting a folder supplies task context. Commands run with full
filesystem and network access under your macOS account, without runtime approval
prompts. macOS permissions and connected-service scopes still apply. Chat shows
tool activity and any service input controls. Stop
interrupts the runtime; completed actions are not undone.

Older **ChatGPT plan** and **Codex runtime** settings migrate to this one connection,
preserving the selected model and visible conversation. Former direct-chat settings
require confirming the displayed account before
sending. Old helper credential files remain untouched;
they are not imported into Codex or used as an automatic fallback.

Builds bundle checksum-pinned Codex 0.164.0 for the host architecture. Only completed
assistant turns are saved. Model access and usage limits remain account-dependent;
API-key billing stays separate. Runtime integration is experimental, and some
plugins require capabilities of their original host. See
[runtime integration](docs/codex-runtime.md) for authentication, permission
boundaries, history, migration, and validation.

Open the header settings control or **Configure Uplink** to set the API base URL, model name, and optional API key.

The **Reasoning Mode** slider above **Configure Uplink** saves this chat's effort for subsequent requests. It offers Auto plus only the selected model's reported levels, including provider-defined levels. Auto omits the effort parameter. Unsupported saved choices remain visible with an error and block sending until corrected; choosing another model does not silently reset the saved effort.

The composer also has model and reasoning menus, a catalog refresh control, and a connection-settings shortcut. These remain available in narrow windows and with the chat sidebar hidden. The chat header, sidebar, and account-default menu resolve **Account default** to the runtime catalog's actual model name. Until the catalog loads, the default is labeled unresolved.

For Ollama and compatible APIs, **Discover models** in Connection Settings reads the selected endpoint's `GET /models` with its API key. It never sends a prompt or follows redirects. Endpoint edits and unsaved keys use a separate discovery state; saved credentials remain scoped to their endpoint. Refresh in the composer reloads the active connection's catalog. Manual model identifiers remain available if discovery is unsupported or fails. A successfully loaded catalog flags models absent from that list; listing a model does not prove inference entitlement or text-chat support.

Standard API model lists may omit reasoning capabilities. In that case, controls offer Auto and explain that support is unreported; existing explicit levels remain labeled unverified. Compatible servers can advertise `supported_reasoning_efforts` (an array of strings) and `default_reasoning_effort` as optional model-list extensions. No capabilities are inferred from model names. ChatGPT uses the runtime's `supportedReasoningEfforts` and `defaultReasoningEffort` metadata and validates a fresh catalog before starting a thread or inference turn.
The default is local Ollama at `http://127.0.0.1:11434/v1` with `qwen3.5:9b`.
Ollama must be running with the selected model installed. Change the model name
to use a different installed model.

The base URL ends before `/chat/completions`; the app appends that path. Remote
servers use HTTPS. HTTP is supported for loopback servers. The request contains
the selected model and the current conversation as `user` and `assistant`
messages. Replies arrive after the model finishes generating.

- **Transmit** or **Command-Return** submits a message. Return inserts a new line.
- **Stop** cancels the app's request and restores the prompt for editing.
  A server may continue generation after the client disconnects.
- **New Chat** or **Command-N** creates a separate saved conversation in the selected workspace.
- The sidebar stays available on the console and in chat. Selecting a workspace opens
  its console; only the active workspace's conversations appear below it, newest activity
  first. Search is limited to those conversations.
  Click a chat to restore its transcript and draft; right-click to rename or delete it.
  The sidebar button beside **Channel Open** toggles the list; the navigation bar can restore it.
- The **Workspace** selectors in the console navigation and below the message field switch workspaces and provide
  **New Workspace** and **Rename Workspace**. Each workspace remembers its selected chat
  and optional task folder. Each workspace has a console landing page showing its
  effective task folder, repository state, serial devices, build output, notes, and events.
  Without a selected folder, task files use `Workspaces/<workspace UUID>` in the app's
  Application Support directory. Connection Settings edits the selected workspace's folder;
  each chat remembers its provider, API endpoint, models, and reasoning effort.
  Credentials remain shared by account or API endpoint. New chats and workspaces
  inherit the active chat's connection settings, then keep their own changes.
- Chat and workspace switching is disabled during generation; stop the response first.
  Chats keep separate model context, unsent drafts, interrupted attempts, and runtime
  thread links. The selected workspace and chat return after relaunch.
- Existing single-chat history imports into **Personal**. Original legacy files remain
  untouched. The new atomic `chat-library.json` stores chats, drafts, and membership;
  `codex-<chat UUID>.json` stores each chat's runtime audit and resume link.
  Version 2 of the library also owns per-chat connection settings. Legacy chats
  inherit the previous shared settings together before any chat is edited;
  the original `settings.json` remains untouched as a migration source.
- Console notes, timer deadlines, activity, and sidebar visibility are saved
  separately for each workspace in the same atomic library. Existing global notes and
  preferences import into the previously selected workspace once; other consoles start empty.
  Accounts, endpoint credentials, and host telemetry remain shared. Workspace isolation
  separates app state and default task folders; full-access tools retain their existing
  filesystem permissions, and explicitly selected folders may overlap.
- Errors preserve the prompt and completed conversation for retrying.

## Console and instruments

At launch, **VAYDEAOS** types over a perspective data grid, then erases before a
brief flash reveals the workspace. The intro takes about 3.75 seconds, followed
by a 2.42-second staged instrument reveal. **AOS** uses inverted navy text on a
blue background, with a red block cursor. The terminal styling draws on
[eDEX-UI](https://github.com/GitSquared/edex-ui). **ESC TO SKIP** or **Escape** skips
the intro immediately; the workspace instruments then reveal in stages.
macOS Reduce Motion uses a short, still sequence and shows all instruments immediately.
An original 3.45-second chime plays once. **VaydeAOS → Startup Sound** saves
the sound preference for future launches.
The sequence is a local interface transition and does not run model requests.

The console uses the logo's blue `#007bfd`, white `#fdfdfd`, and red `#ff3e32`
in a 60/30/10 hierarchy: blue-family surfaces and structure dominate, white supports
readable content, and red marks small accents. Brighter blue tints are limited to
selected, hovered, and focused controls. Colors are centralized in `ConsoleTheme.swift`.
**Ask Vayde** uses Avenir Next Demi Bold.

- **Project State** reads the selected directory's Git branch, commit, commit age, and
  changed-file count every five seconds. **Project** selects a directory for both the
  console and the agent. A matching sibling checkout is selected automatically when
  the app is packaged under a repository's `build/` folder. Chat storage stays in
  Application Support. Project and build-command choices persist per workspace.
- **StudentDB** keeps the same panel sizes and positions, with **Source Map**, **C++
  Workbench**, **Source Trace / CLI Session / Build Output**, and **Learning Notes**.
  The profile follows the StudentDB workspace or a selected StudentDB checkout. An
  unbound StudentDB workspace uses `~/StudentDB(deploy)` when its CMake project exists.
  Explicit project selections take precedence. Source selection and output tab persist
  per workspace; chat history, model settings, notes, and project bindings remain isolated.
  **C++ Learning Context** opens the linked Obsidian note in the VaydeNetV vault.
- StudentDB defaults to a Debug CMake build with warnings in `build/vaydeaos`, avoiding
  older build caches. **Run CLI** launches that build in the selected project directory;
  **CLI Session** is a terminal with inline prompts, a cursor, selectable scrollback,
  and direct keyboard input. Click the terminal to focus it; Return submits input.
  Input echoes normally, and the CLI controls any password hiding through its own
  terminal settings. Cursor movement, Backspace, paste, ANSI formatting, terminal
  resizing, and control keys are handled by the terminal. **Stop** ends the process.
  The running CLI and terminal state belong to their workspace and survive navigation
  until exit; terminal contents are not saved to the chat library.
  Confirming enrollment can write `students.txt` in the displayed project directory;
  **Record Output** reveals that file. Its existence/size, build exit status, and CLI
  exit status are separate observations, not assertions of validation or login correctness.
- **Device Bench** discovers macOS USB serial ports every five seconds. **Serial**
  opens a port exclusively at the selected baud rate; **Close** releases it. Detected
  ports are not labeled as running firmware. No firmware is flashed automatically.
- **Transport Readiness** displays measured host network throughput, serial connection
  state, and decoded device-report counts. Radio/peer state remains **Unverified**
  until a device supplies evidence; host network activity does not prove radio health.
- **Packet Inspector** accepts VaydeNet `Logical message delivered:` logs containing
  `source`, `sequence`, and `payload`, or JSON records containing `transport`, `sender`
  (or `senderID`), and `sequence` (or `sequenceNumber`). JSON can also report `direction`
  (`rx`/`tx`) and `result`; missing values stay unknown. Heartbeat submissions are not
  counted as peer delivery. **Pause** pauses packet capture while raw serial continues.
  **Clear** clears the selected output buffer. Buffers are bounded in memory.
- **Build & Verification** runs a local build or test command from **Setup** in the
  selected project directory and streams stdout/stderr into **Build Output**. The
  initial command comes from detected project files; VaydeNet defaults to its host
  verification suite. Build success comes from the process exit code. Serial ownership
  is released before a build. Serial and build output are aligned to the top left,
  wrap to the available width, and use larger type with additional line spacing.
  **Following/Follow** controls whether new output scrolls to the latest line.
  Running jobs and serial sessions survive workspace
  navigation; they end when the app exits. Connection and build events are local.
- **Ask Vayde**, **Open Chat**, or **Command-K** opens chat
  below the console, keeping telemetry and project controls visible in the same window.
  Typing in other controls does not open chat or redirect input into its draft.
  Right-click **Ask Vayde** for **Model activity**.
  The model panel retains request timing, provider-reported usage, tools, and reasoning.
- **Close Chat**, **Console**, or **Escape** hides chat without discarding its draft or
  history. During a request, Escape stops the response first. A completed request
  reopens the channel if hidden. After 15 seconds without input, the ambient
  dashboard fades in with live CPU/memory, uptime, interfaces, RX/TX history,
  model state, and public OpenAI API health. **View → Ambient Display** (Command-Shift-I)
  opens it immediately. The geographic globe rotates automatically; drag to turn
  and tilt it, pinch or use +/- to zoom, pause rotation, or reset the view.
  Panel 05 fills the right column above API status with a circular system-audio
  spectrum. **Enable audio** requests macOS Screen & System Audio Recording access.
  Capture runs only while the idle dashboard is visible and the app is active.
  Audio is analyzed locally and never saved; no microphone input is used.
  Silence produces a flat ring. Globe connections remain ambient artwork;
  throughput and host readouts remain measured data. Reduce Motion pauses globe
  animation; live audio levels continue to update.
  Pressing a key or clicking **Idle** / the resume footer returns to the previous
  console, chat, or model panel with draft and state preserved. The first wake key
  is consumed; pointer movement and graph controls keep the ambient screen open.
  Active requests, runtime prompts, and open sheets keep the workspace visible.
- Scratchpad **Edit/Done** controls editing. Notes persist independently per workspace.
  Existing timer deadlines and older activity entries remain in the saved library.
- Host interface traffic comes from local macOS APIs, sampled once per second.
  Serial/build buffers and telemetry events are session-local; notes and project choices
  persist. No illustrative device, packet, build, or transport readings are generated.

Run `./scripts/check-project-console.sh` to verify real subprocess stdout/stderr,
exit codes, burst draining, and pseudo-terminal serial capture without opening hardware.

## Local data

The conversation and connection settings are saved under
`~/Library/Application Support/VaydeAOS/`. API keys are stored separately in
macOS Keychain, scoped to the API base URL. Changing the endpoint does not copy
the previous endpoint's key. The app sends conversation text only when **Send**
is used; selecting a remote API sends the current conversation to that server.

If Keychain access fails, **Use Key for This Session** applies the entered key
without reading or writing Keychain. The key stays in memory until the app quits;
only the endpoint and model are saved to disk. Existing Keychain entries remain
unchanged and are used again after restarting. This option also appears when
editing an endpoint that already uses a session key. **Save** still attempts to
store the key in Keychain.

The compatible API connection provides text chat. The ChatGPT connection also
supports file and command tools, configured Obsidian/MCP retrieval, and compatible
runtime integrations. Available tools depend on local configuration and service
permissions; discovery alone does not verify successful execution.

Completed assistant messages retain their provider and model. Provider-reported
models are distinguished from runtime selections and unreported requested models;
older messages retain their original history without invented attribution. A notice
before sending explains when settings changes will create a fresh runtime thread.
The affected answer also records that visible history transferred into a new thread.

The app has a separate 1 MiB UTF-8 submission cap. A transfer exceeding it is rejected
before creating/resuming a runtime thread or replacing its saved link. This byte
limit is independent of the selected model's token context window. Context-usage
display and automatic history summarization remain follow-up work.

## Verification and source layout

```sh
./test.sh
git diff --check origin/main...HEAD
git diff --check
```

- `Sources/VaydeAOS/`: SwiftUI console, system telemetry, network visualizations,
  bundled imagery, conversation view, and connection settings.
- `Sources/VaydeAOSCore/`: API client, chat state, Keychain, and local storage.
- `Tests/VaydeAOSCoreTests/`: request, failure, cancellation, and storage tests.
- `Resources/Info.plist`: app bundle metadata.
- `examples/hello-world/`: original standalone SwiftUI example.

The tests use Swift Testing and require macOS 14 or later. `test.sh` also locates
its bundled framework when using Command Line Tools without a full Xcode
installation.

`.gitattributes` exempts only the verbatim upstream
`Helpers/ChatGPT/vendor/siwc-local/UPSTREAM_THIRD_PARTY_NOTICES.md` from whitespace
checks. Its legal text is preserved unchanged; all project-owned changes remain
checked locally and in Apple CI.

The API adapter follows the documented
[Chat Completions request format](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
and [Ollama's compatibility API](https://docs.ollama.com/api/openai-compatibility).
