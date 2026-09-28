# A-EYE

Look at a window, hold **Right ⌥**, talk. The text lands in the input you're looking at.
A-EYE is a macOS menu-bar app that uses the webcam to work out which window (and which text
box inside it) you're facing, then transcribes your speech and pastes it there. It's built
for running several AI coding agents side by side (Claude Code panes, Claude Desktop, Cursor,
…) and talking to whichever one you're looking at, without clicking between them first.

## What it does

- **Gaze routing.** Apple Vision head pose plus pupil landmarks feed a geometric
  ray-to-screen model, calibrated once. At key-down, A-EYE takes the topmost window at the
  gaze point and the text input nearest to it (found through the Accessibility tree,
  including Electron apps). It highlights it and latches it for the whole press.
- **Live transcription.** Parakeet v3 runs locally on the Neural Engine and is the default.
  Local Whisper, Wispr Flow, Deepgram Nova-3 and OpenAI live transcribe are the other options.
- **Voice commands.** "scratch that", "clear the input", "…send it".
- **Clean-up.** Filler words are removed locally, or you can turn on an optional OpenAI
  rewrite that edits the input in place as you talk.
- **No lost audio.** Every press is saved as a WAV before it's transcribed. If a cloud
  engine fails, the saved audio is transcribed locally instead, and you can retry it from
  menu › Recent.
- **AirPods-friendly.** If the default input is Bluetooth, A-EYE records from the built-in mic
  instead, so your headphones don't drop into call mode.

## Quick start

Requirements:

- macOS 14+, a webcam (the built-in FaceTime camera works) and a microphone.
- Command Line Tools with **Swift 6**. You need it to build the Parakeet (FluidAudio)
  dependency:
  `sudo softwareupdate --install "Command Line Tools for Xcode 26.6-26.6"`
- Optional: `brew install whisper-cpp` plus a ggml model in
  `~/Library/Application Support/A-EYE/models/`, if you want the local Whisper engine.

```bash
./scripts/build-app.sh      # → dist/A-EYE.app (ad-hoc signed)
open dist/A-EYE.app
```

1. **Grant permissions** when asked: Camera, Microphone, Accessibility (the talk key and
   pasting need it) and Speech Recognition (used only by the Apple fallback engine).
   Because rebuilds keep the same signing identity, you only grant these once.
2. **Calibrate:** menu › *Calibrate screens…*. It takes about 3 minutes across six phases:
   look naturally, eyes only, head only, then three sitting postures. Esc cancels. When it
   finishes, it reports the typical error in points. To check the result, use *Show gaze
   pointer*.
3. Look at an input, hold **Right ⌥**, speak, and release.

The Parakeet model downloads the first time you press the key.

## Usage cheat-sheet

| | |
|---|---|
| **Talk** | Hold Right ⌥ (≥0.25 s). A shorter tap, Esc, or any other key within 0.4 s of pressing (for example ⌥3 for `#`) cancels. |
| **Target** | Latched at key-down. For the first 0.4 s it can still re-latch while your head finishes turning. |
| **"scratch that"** | On its own, it removes the last text A-EYE pasted into that input. Mid-sentence, it drops the sentence before it. |
| **"clear the input"** | On its own or leading a sentence, it empties the input with ⌘A ⌫. It only works on a detected text input, never an editor. |
| **"…, send it"** | Trailing only. Presses Return once the text (and any clean-up) is in. |
| **Paste mode** | *Paste while speaking* (default) pastes each phrase after about 0.7 s of pause. Switch it off to paste everything on release. |
| **Clean-up** | *Off* keeps exactly what was heard. *Basic* (default) removes fillers and stutters locally. *OpenAI* rewrites the whole dictation so far and edits it in place. |
| **Engine** | menu › Engine: Parakeet (local, default), Whisper (local), Wispr Flow, Deepgram Nova-3, OpenAI live transcribe. |
| **Auto-send** | *Press Return after pasting* sends every dictation. |
| **Posture** | *Add a posture…* appends a short calibration pass for however you're sitting now. |

## Privacy

- **Camera:** frames are processed in memory by Apple Vision and never written to disk.
  The one exception is *Record gaze test set…*, an explicit opt-in that saves JPEG frames
  under `~/Library/Application Support/A-EYE/gaze-recordings/`.
- **Audio:** stays on the Mac with Parakeet or Whisper. Audio goes to a cloud service only
  if you pick Wispr Flow, Deepgram or OpenAI as the engine. With *OpenAI* clean-up, the
  transcript text (not the audio) is sent to OpenAI.
- **Stored locally:** every press is saved as a WAV in `…/A-EYE/recordings/`, and the text
  of every press is appended to `…/A-EYE/history.jsonl`. Neither is pruned automatically.
- **API keys** are kept in the login Keychain (service `dev.gazevoice.api-keys`). Each key
  is only sent to its own provider.

## Docs

- [docs/architecture.md](docs/architecture.md): the pipeline from camera and mic to pasted
  text, component by component.
- [docs/gaze.md](docs/gaze.md): the gaze model, calibration phases, metrics, known numbers
  and limits.
- [docs/speech.md](docs/speech.md): engines, phrase segmentation, voice commands, clean-up
  and clipboard handling.
- [docs/development.md](docs/development.md): building, logs, data locations, CLI test
  hooks, the evaluation tooling and gotchas.
