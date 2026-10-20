# VaydeAOS

A native macOS command center written in Swift and SwiftUI, with a VaydeNet navy, blue, and red
console, live system instruments, and an integrated model chat channel. Connection settings support
local Ollama and servers that implement the OpenAI-compatible Chat Completions
API.

## Build and run

Requires macOS 13 or later and Swift 6 or later from Xcode Command Line Tools
(`xcode-select --install`). No external Swift packages are required.

From the repository root:

```sh
./build.sh
open build/VaydeAOS.app
```

Use `./build.sh release` for an optimized build. The script packages the SwiftPM
executable into a macOS `.app` and signs it locally. Distribution signing and
notarization are separate from this local development build.

## Connect a model

Open the header settings control or **Configure Uplink** to set the API base URL, model name, and optional API key.
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

The current experimental palette uses the live VaydeNet site's
[design tokens](https://vaydenet.duckdns.org/css/tokens.css): navy `#070b18`,
blue `#60a5fa` / `#1d4ed8`, and red `#ff4c5b`. Green remains a status color.
The palette is centralized in `ConsoleTheme.swift`, including the globe and settings.

- **Workspace** starts at idle with live instruments and four additional widgets:
  a CPU/RX/TX signal inspector, focus timer with 5/15/25/50-minute presets,
  locally saved scratchpad, and a timestamped session activity log.
- **Interrupt**, **Command-K**, or typing outside a text editor opens a floating
  chat panel. Input monitoring is limited to this app's window.
- **Return to Idle** or **Escape** hides chat without discarding its draft or history.
  During a request, Escape stops the response first. A completed request or error
  reopens the channel if it was hidden.
- **Auto Idle** returns chat to the dashboard after 60 seconds without keyboard,
  click, or scroll input, only when there is no draft, request, error, or settings sheet.
- Scratchpad **Edit/Done** controls editing; **To Chat** appends notes to the draft
  without sending them. Notes and the Auto Idle preference use local UserDefaults.
  The focus timer and activity log last for the current app session.
- **Network** expands the globe; **Focus** opens chat and hides the side columns.
- CPU, active/wired/compressed memory, uptime, interface addresses, and primary
  interface traffic come from local macOS APIs. Samples refresh once per second.
- Traffic plots retain up to 60 observed samples and scale independently. They
  measure the selected local interface, not model API traffic or remote nodes.
- The animated globe is illustrative; its routes are not geolocated connections.
  **Pause Orbit** and the system Reduce Motion setting stop its animation.
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
