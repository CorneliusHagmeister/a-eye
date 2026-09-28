# A-EYE

Voice input that goes where you're looking. Hold **Right ⌥**, talk, let go — the text lands
in the input box you were looking at (a Claude Code pane, Claude Desktop, Discord, …),
chosen by webcam head tracking. Built for running several agent sessions side by side.

macOS menu-bar app, everything on-device by default.

## How it works

- **Gaze** — Apple Vision face detection (yaw/pitch + face position and size) at 8 fps.
  A geometric model casts a ray from your head to the screen plane; a ~40s look-at-the-dots
  calibration maps that onto your monitors. "Add a posture" makes it robust to leaning back.
  Head tracking, not eye tracking: accurate to a window or half a split pane.
- **Routing** — at key-down, the topmost window at the gaze point and the text input nearest
  it (via the Accessibility tree, incl. Electron apps) are highlighted and latched.
- **Speech** — pluggable engines (menu › Engine):
  - **Parakeet v3** (default, local, Neural Engine via FluidAudio) — ~0.08s per phrase, live text
  - **Whisper large-v3-turbo** (local, whisper.cpp)
  - **Deepgram Nova-3**, **OpenAI gpt-live-transcribe**, **Wispr Flow** (API keys in the Keychain)
- **Delivery** — pasted on release (live transcript in the overlay while you talk), or at
  each pause. Voice commands: "scratch that", "clear the input", "…send it".
- **No lost audio** — every press is saved as a WAV before transcription; failures fall back
  to local transcription and are retryable from menu › Recent.
- Records from the built-in mic when your default input is Bluetooth, so AirPods stay in
  music mode.

## Build

Needs Command Line Tools with Swift 6 (`sudo softwareupdate --install "Command Line Tools for Xcode 26.6-26.6"`).

```bash
./scripts/build-app.sh
open dist/A-EYE.app
```

Grant Camera, Microphone and Accessibility when asked. The Parakeet model (~470MB) downloads
on first use. For Whisper: `brew install whisper-cpp` and put a ggml model in
`~/Library/Application Support/A-EYE/models/`.

## Debug hooks

`A-EYE.app/Contents/MacOS/AEye` accepts `--engine-test <engine> file.wav`,
`--transcribe file.wav`, `--mic-test`, `--inspect`, `--gaze-fit-test`, `--commands-test`,
`--segment-test file.wav` (run via `open -W -n dist/A-EYE.app --args …`).
Log: `~/Library/Logs/A-EYE.log`.
