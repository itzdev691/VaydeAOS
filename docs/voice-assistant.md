# Vayde Voice

Say **Hey Vayde**, wait for **Yes?**, then speak. A final recognition result or a
1.5-second pause submits the captured text through the selected chat. Capture ends
after eight seconds without a transcript or thirty seconds total. Speech after
the wake phrase must follow the acknowledgement; a single uninterrupted
“Hey Vayde, do this” sentence is not supported.

The microphone button opens voice controls. The Vayde Voice submenu in the macOS
menu bar also provides **Speak to Vayde**, **Stop Voice Turn**, **Retry Voice Access**,
and an always-listening switch. **Send Voice Request** submits the current transcript
immediately. The switch persists across launches and defaults to enabled.

The first normal launch requests microphone and speech-recognition permissions.
Denied permissions or unavailable on-device English recognition leave voice stopped
with a visible explanation. Enable access in System Settings → Privacy & Security,
then use Retry Voice Access. Voice never substitutes network transcription.

## Processing and resource use

- Standby: `NSSpeechRecognizer` matches only “Hey Vayde” and its phonetic spelling.
  It accepts commands while other apps are foreground. Vayde does not run a
  dictation stream, polling loop, or model request in standby.
- Activation: the command recognizer stops before the spoken acknowledgement.
  `AVAudioEngine` and `SFSpeechRecognizer` then transcribe the request using
  `requiresOnDeviceRecognition`, after verifying on-device support.
- Inference: capture stops before request text enters `ChatSession`. It uses the
  same connection, history, model, tool access, and account usage as typed chat.
  Voice does not approve service prompts; those remain in the chat controls.
- Playback: `AVSpeechSynthesizer` reads the answer with a system English voice.
  Code blocks are referred to in chat, Markdown formatting is removed, and
  responses exceeding 3,000 characters are shortened for playback. The full
  response remains in chat. Wake matching resumes after playback settles.

No microphone audio is written to disk or sent to an AI provider. Request text and
conversation context are sent to the selected provider. Completed turns and
interrupted voice attempts use the existing chat persistence. Typed drafts,
including edits made during voice inference, are preserved.

Always listening cannot consume zero system resources. The native command matcher
still requires microphone capture and speech processing, including work in macOS
services. This implementation avoids continuous full dictation and AI activity in
standby. No measured CPU, memory, energy, or wake accuracy guarantee is made.

## Lifetime

The app stays running in the menu bar after its window closes. A wake command
reopens the current chat. Voice starts with the app independently of window
presentation. Quit stops voice. Launch at Login can be enabled from the menu bar;
login launches keep the workspace hidden. The app cannot listen when it is quit
or when the Mac sleeps.

Sleep, screen lock, and inactive user sessions suspend audio; unlocking and waking
resume it. Connection settings and typed requests temporarily pause voice. Changing
chats discards any incomplete capture. Disabling listening stops microphone use
and speech immediately; an already-submitted model turn may finish silently in
chat. Stop Voice Turn also cancels the active voice model request. Actions already
performed by an agent retain the same cancellation semantics as typed chat.

## Validation

`./test.sh --filter VoiceAssistantTests` exercises standby gating, acknowledgement,
request attribution, typed draft preservation, failures, cancellation, stale
callbacks, permission races, context changes, lock/resume, and playback suppression
with an injected audio service. These tests do not exercise a physical microphone
or measure wake-word accuracy.

`./test.sh` runs the full core suite. `./build.sh` packages the native adapter and
permission descriptions. `scripts/ci-ui-smoke.swift` sets
`VAYDEAOS_DISABLE_VOICE=1` for launch-only validation so CI never requests microphone
access. This environment override does not change the saved listening preference.

Physical verification requires an audible wake phrase, acknowledgement, spoken
request, and spoken model reply, followed by background/window-close, lock/resume,
and Stop checks. CPU and memory measurements must include the app and macOS speech
services. Compilation and mocked lifecycle tests do not establish these results.
