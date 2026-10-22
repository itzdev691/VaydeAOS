# Startup design notes

The current launch sequence occupies the existing main window. `StartupView`
types `VAYDEAOS` in Avenir Next Demi Bold at 160 ms per character. `AOS` uses
navy text on blue blocks, followed by a red cursor. `StartupDataGrid` draws a
perspective floor with decorative moving pulses; these are not network samples.

`StartupContainer` starts sound after 100 ms, begins typing after another
400 ms, holds the title briefly, shifts the grid upward, erases the word at
100 ms per character, and swaps to the workspace beneath a short white flash.
The nominal intro is 3.75 seconds. `ChatView` then reveals instruments in eleven
220 ms steps (2.42 seconds). Boot labels describe presentation, not completed
system checks or model connectivity.

Escape skips the intro. Instruments still reveal in stages. Reduce Motion uses
an approximately 0.8-second still title, suppresses the flash and grid motion,
and shows workspace instruments immediately. Intro input is disabled and hidden
from accessibility until completion; typing outside editors opens chat only
after the workspace reveal finishes. New Chat and Connection Settings menu
commands are disabled during the intro.

The generated mono PCM16 chime lasts 3.45 seconds at 44.1 kHz. Recreate it with
`python3 scripts/generate-startup-chime.py`. The app menu persists the sound
preference. Playback stops when skipped, disabled, inactive, or dismissed.

The earlier `StartupTelemetryView` remains in the source tree but is not mounted
by the current startup. Its live CPU/memory/RX/TX instruments, shared 0.5 opacity,
drift, and scan effects are an inactive design variant. Share Tech Mono and its
OFL license remain bundled; the current title neither registers nor selects it.

The terminal and staged reveal direction draws on the
[eDEX-UI startup renderer](https://github.com/GitSquared/edex-ui/blob/master/src/_renderer.js)
and [grid styling](https://github.com/GitSquared/edex-ui/blob/master/src/assets/css/main.css).
Earlier reference review: 2026-10-20. This note records the local source inspected
on 2026-10-21; it does not claim fresh visual or auditory verification.
