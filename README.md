# VaydeAOS

A native macOS command center written in Swift and SwiftUI, with a VaydeNet navy, blue, and red
console, live system instruments, and an integrated model chat channel. Connection settings support
local Ollama and servers that implement the OpenAI-compatible Chat Completions
API. A separate **ChatGPT plan** provider supports browser sign-in and eligible
plan usage through OpenAI's local Sign in with ChatGPT SDK.

## Build and run

Requires macOS 13 or later and Swift 6 or later from Xcode Command Line Tools
(`xcode-select --install`). No external Swift packages are required.
The build downloads a checksum-pinned Node 22 runtime from nodejs.org and installs
locked helper dependencies from npm. Internet access is required for this step.
Node and the credential utility are bundled; users need no separate Node installation.

From the repository root:

```sh
./build.sh
open build/VaydeAOS.app
```

Use `./build.sh release` for an optimized build. The script packages the SwiftPM
executable into a macOS `.app` and signs it locally. Distribution signing and
notarization are separate from this local development build.

## Apple UI CI/CD

[Apple UI CI/CD](.github/workflows/apple-ui.yml) runs on pull requests targeting
`main`, pushes to `main` or `codex/**`, version tags (`v*`), and manual dispatch.
It uses [GitHub's macOS runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
on Apple Silicon and Intel to run the Swift tests, build the release SwiftUI app,
and validate bundle resources and its ad-hoc signature. Both jobs use macOS 26
with Xcode 26.6 explicitly selected through `DEVELOPER_DIR`. An initial check
requires Apple Swift 6.3.x so runner defaults cannot silently change the compiler.
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

For ChatGPT, open **Connection Settings → ChatGPT plan → Continue with ChatGPT**.
Complete browser sign-in and authorize plan usage, choose an available model,
then save. **Manage usage** opens ChatGPT usage settings. Saved connections,
account switching, reconnect, and sign-out are available in the same panel.
Identity-only consent leaves plan requests disabled. Existing ChatGPT conversations
are not imported. The API configuration is retained when switching providers.

ChatGPT responses stream into the chat, and only completed responses are saved.
Requests use the public Responses API with storage disabled and full conversation
history. Plan eligibility and usage limits apply; API-key billing remains separate.
The vendored DevKit has a noncommercial license. See [implementation and validation](docs/chatgpt-sign-in.md).

Open the header settings control or **Configure Uplink** to set the API base URL, model name, and optional API key.

The **Reasoning Mode** slider above **Configure Uplink** saves the effort for subsequent requests: Auto, None, Minimal, Low, Medium, High, Extra high, or Max. Auto preserves the model default. Supported levels depend on the selected model and provider. The setting applies to both compatible APIs and ChatGPT plan requests.
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
- **New Chat** clears the saved conversation and starts with an empty context.
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

The current experimental palette uses the live VaydeNet site's
[design tokens](https://vaydenet.duckdns.org/css/tokens.css): navy `#070b18`,
blue `#60a5fa` / `#1d4ed8`, and red `#ff4c5b`. Green remains a status color.
The palette is centralized in `ConsoleTheme.swift`, including the circular activity graph and settings.

- **Workspace** starts at idle with live instruments and four additional widgets:
  an ambient signal field, focus timer with 5/15/25/50-minute presets,
  locally saved scratchpad, and a timestamped session activity log.
- **Signal Field** replaces the duplicate CPU/RX/TX inspector with a flowing wire
  surface. **Phase Core** replaces the repeated session summary with orbital
  artwork. Both are labeled **Ambient**, contain no telemetry or simulated
  measurements, and use native procedural graphics. Animation stops when the
  app is inactive, when the field is hidden by chat, or with Reduce Motion enabled.
- **Interrupt**, **Command-K**, or typing outside a text editor opens chat in the
  main center column, with the side instruments accessible. Input monitoring is
  limited to this app's window. Dashboard timers and widget state survive switching.
- **Return to Idle** or **Escape** hides chat without discarding its draft or history.
  During a request, Escape stops the response first. A completed request or error
  reopens the channel if it was hidden.
- **Auto Idle** returns chat to the dashboard after 60 seconds without keyboard,
  click, or scroll input, only when there is no draft, request, error, or settings sheet.
- Scratchpad **Edit/Done** controls editing; **To Chat** appends notes to the draft
  without sending them. Notes and the Auto Idle preference use local UserDefaults.
  The focus timer and activity log last for the current app session.
- **Network** expands the circular activity graph; **Focus** opens chat and hides the side columns.
- CPU, active/wired/compressed memory, uptime, interface addresses, and primary
  interface traffic come from local macOS APIs. Samples refresh once per second.
- Traffic plots retain up to 60 observed samples and scale independently. They
  measure the selected local interface, not model API traffic or remote nodes.
- **OpenAI API Status** polls OpenAI's public
  [status feed](https://status.openai.com/api/v2/summary.json) every 60 seconds
  while the dashboard is visible and the app is active. The circular graph keeps
  the last 60 observations of Chat Completions (inner band) and Responses (outer
  band). Outward spikes indicate reported degradation or outages; colors identify
  operational, degraded, outage, and maintenance states. Missing components,
  unknown states, and failed polls leave gaps. Failed or older-than-150-second
  observations show an unavailable or stale feed indicator. History is session-only;
  hidden/background time is not filled with invented samples. No API key, prompts,
  or configured endpoint/model are sent to the status feed. OpenAI aggregates
  availability across models and tiers; this graph does not report a selected
  model's latency, token speed, or benchmark score. The right-offset circle retains
  its subtle bounce and border clipping; Reduce Motion disables bounce.
- Narrow windows collapse the right instrument column; side panels scroll.
- VaydeNet photography and the wolf mark are bundled with the app. The interaction
  hierarchy draws on the VaydeAOS Obsidian planning notes; it does not imply a
  running vault integration or autonomous agent tools.

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

This version provides text chat. File access, Obsidian retrieval, and agent tools
remain outside the implemented interface.

## Verification and source layout

```sh
./test.sh
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

The API adapter follows the documented
[Chat Completions request format](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
and [Ollama's compatibility API](https://docs.ollama.com/api/openai-compatibility).
