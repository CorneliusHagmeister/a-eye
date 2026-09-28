# Development

## Build

```bash
./scripts/build-app.sh
```

The script:

1. Runs `swift build -c release`. The SwiftPM package is `Package.swift` with one
   executable target, `AEye`, which depends on FluidAudio ≥ 0.17.4.
2. Assembles `dist/A-EYE.app`: the binary, `Resources/Info.plist`, and any
   `.build/release/*.bundle` resource bundles (FluidAudio's) copied into
   `Contents/Resources`.
3. **Ad-hoc signs with a fixed designated requirement:**

   ```bash
   codesign --force --sign - --identifier dev.gazevoice.app \
     -r='designated => identifier "dev.gazevoice.app"' dist/A-EYE.app
   ```

   TCC (Camera, Microphone, Accessibility) keys its grants on the designated requirement.
   A plain ad-hoc signature's requirement is the binary's cdhash, which changes on every
   build and silently invalidates the grants. Pinning it to the identifier keeps grants
   across rebuilds.

Notes:

- **Swift 6 is required.** FluidAudio (Parakeet) won't build with an older toolchain.
  Install the Command Line Tools:
  `sudo softwareupdate --install "Command Line Tools for Xcode 26.6-26.6"`.
- The bundle id and Keychain service are still `dev.gazevoice.*`, left over from the old
  name *GazeVoice*. They were kept in the rename (`1965d3c`) so grants and stored keys
  carry over. Don't change them casually.
- **Stale `.build` after moving or renaming the folder.** SwiftPM caches absolute paths, so
  if builds fail oddly after a rename, run `rm -rf .build` and rebuild.
- Nothing is hot-reloaded. After a rebuild, quit A-EYE (menu › Quit) and `open` it again.

## Running

```bash
open dist/A-EYE.app                                # normal
open -W -n dist/A-EYE.app --args --commands-test   # a test hook (see below)
```

- Always run the **`.app` bundle**, not `.build/release/AEye`. Camera and mic access need
  a bundle with usage strings (`NSCameraUsageDescription`, …) and a stable signature.
- Opening the app while it's already running pops its menu at the mouse. That's useful
  when the menu-bar icon is hidden behind the notch.
- `Log.info` both prints and appends to the log file. With `open`, stdout isn't visible,
  so **read the log**:

```bash
tail -f ~/Library/Logs/A-EYE.log
```

## Data locations

Everything lives under `~/Library/Application Support/A-EYE/`. On first launch, the old
`GazeVoice` folder is moved there if it exists.

| Path | Contents |
|---|---|
| `gaze-model-v3.json` | Fitted `GazeModel` (gains, coefficients, LOO error, distance range) |
| `gaze-calibration-v3.json` | Raw calibration points, used to refit after *Add a posture* |
| `targets.json` | Pinned targets (the legacy mode, used when there's no screen calibration) |
| `recordings/<yyyyMMdd-HHmmss-SSS>.wav` | Every press, 16 kHz 16-bit mono. Never pruned. |
| `history.jsonl` | One line per press: time, engine, target, text, wav, error |
| `models/*.bin` | ggml models for local Whisper |
| `gaze-recordings/<stamp>/` | *Record gaze test set* output: `frame-NNNNN.jpg` + `frames.jsonl` |

Older `gaze-model.json`, `-v2` and `gaze-calibration.json` files from earlier model
versions may still be around. The app ignores them.

Other state:

- **Log:** `~/Library/Logs/A-EYE.log`, appended forever.
- **API keys:** login Keychain, service `dev.gazevoice.api-keys`, account = engine id
  (`wispr`, `deepgram`, `openai`).
- **Settings:** UserDefaults of `dev.gazevoice.app`. Some settings have no menu item and
  are set with `defaults write dev.gazevoice.app <key> …`:

| Key | Default | |
|---|---|---|
| `engine` | `parakeet` | Menu › Engine |
| `pasteWhileSpeaking` | `true` | Menu |
| `autoSubmit` | `false` | Menu (*Press Return after pasting*) |
| `cleanup` | `basic` | Menu (`off` / `basic` / `openai`) |
| `cleanupModel` | `gpt-6-luna` | defaults only |
| `languages` | `[en, de]` | defaults only (`-array en`). With exactly one language, Parakeet, Deepgram and OpenAI stop auto-detecting. |
| `micWarmSeconds` | `20` | defaults only |
| `showGazePointer`, `showGazeInMenuBar` | `false`, `true` | Menu |

## CLI test hooks

All hooks are handled in `AppDelegate.applicationDidFinishLaunching`. Each one runs
instead of the normal app, logs to `~/Library/Logs/A-EYE.log` and exits. Run them through
the bundle so permissions apply:

```bash
open -W -n dist/A-EYE.app --args <hook> [args…]
```

| Hook | What it does | What it proves |
|---|---|---|
| `--engine-test <id> <file.wav>` | Plays a 16 kHz 16-bit mono WAV into engine `<id>` (`parakeet`, `whisper`, `wispr`, `deepgram`, `openai`, `apple`) in real time, in 100 ms chunks, and logs every partial, FINAL, failure and done with timestamps | End-to-end streaming behaviour and latency of one engine, including segmentation. Cloud engines need their key in the Keychain. |
| `--transcribe <file.wav>` | Transcribes the file twice with `Engines.localTranscriber()` | That the local engine works, with cold vs warm (resident model) latency |
| `--mic-test` | Opens the chosen mic for 2 s and logs default vs chosen device, sample count and peak level | Mic permission, the Bluetooth → built-in mic switch, and that the tap actually receives audio |
| `--inspect` | For each pinned target, logs the window, the AX element under its click point and every text input in the window | Why "focused the window but the paste went nowhere" (for example an Electron tree that isn't built yet). Only uses pinned targets from `targets.json`. |
| `--gaze-fit-test` | Simulated calibration and test (see [gaze.md](gaze.md#known-numbers)), with and without eye terms, for five data mixes | Whether a model change helps natural looking, unseen postures and eyes-only glances, *in simulation* |
| `--gaze-fit-test --postures` | Averages 20 fits of "one lean pass" vs "three postures", tested between, beyond and beside the calibrated postures | Posture-robustness trade-offs, *in simulation* |
| `--commands-test` | Runs sample sentences through `Cleanup.basic` and `VoiceCommands.interpret` | Command parsing and filler removal (including false positives such as "umbrella") |
| `--cleanup-test` | Sends 4 sample dictations (EN, DE, a self-correction, a question) through the rolling `Cleanup.rewrite` and logs latency and output | The OpenAI key, model name, latency, and that it cleans without answering |
| `--learned-test [recording]` | Runs the app's learned-gaze path (compile, Vision crop, Core ML) on every 25th recorded frame and logs yaw/pitch | The installed Core ML model loads and matches the Python reference (compare with `tools/eval_gaze.py`'s ONNX model) |
| `--refit` | Refits the gaze model from the saved raw calibration samples and saves it | Picks up changes to the fitting code without recalibrating |
| `--clipboard-test` | Offers text via a promised pasteboard item (no ⌘V) and logs if and when another process reads it within 8 s, then restores the clipboard | The promise mechanism. Paste manually (⌘V) in any app while it runs. |
| `--pupil-test` | Six dots on the built-in display. You keep your head still and follow them with your eyes. Logs pupil offset vs head yaw/pitch per dot, the separation in σ, and Vision landmark cost per frame | Whether pupil landmarks carry signal on this camera and face (real data) |
| `--segment-test <file.wav>` | Replays a WAV through `Segmenter` in 200 ms ticks and logs where phrases would be committed | Pause detection thresholds on real recordings (for example files from `recordings/`) |

## Python tools

`tools/eval_gaze.py` compares gaze variants on a recorded test set (see
[gaze.md](gaze.md#evaluating-alternatives-offline)). `tools/.venv/` and `tools/weights/` are
gitignored.

```bash
python3 -m venv tools/.venv
tools/.venv/bin/pip install numpy opencv-python onnxruntime
# Put yakhyo/gaze-estimation ONNX exports in tools/weights/ as <name>_gaze.onnx
# (resnet50_gaze.onnx, mobilenetv2_gaze.onnx, mobileone_s0_gaze.onnx).
# Gaze360-trained: research / non-commercial use only.
tools/.venv/bin/python tools/eval_gaze.py [recording_dir]
```

`spike/` holds the early probes (`yawprobe.swift`: Vision yaw cost and separation;
`camdiag.swift`: camera frame delivery). They aren't part of the app build.

## Gotchas

These are collected from the commit history. Each cost at least one debugging session.

- **Camera needs a real `.app`.** It needs `NSCameraUsageDescription` and a stable
  signature; don't expect camera access from a bare `swift run` binary (`spike/camdiag`
  and `spike/GazeProbe.app` came from debugging this). Microphone and speech need their
  usage strings too. That's why the test hooks go through `open … --args`.
- **TCC grants reset on rebuild** unless the designated requirement is pinned (see Build).
- **Global event monitors registered before Accessibility trust never fire.** The app polls
  `AXIsProcessTrusted` and re-registers the talk-key monitors once trust is granted.
- **Touch the HUD, and AppKit in general, only on the main actor.** Nonisolated `async`
  functions resume on a background executor after an `await`. `HUD.show` from there trapped
  in AppKit (`cdec799`). `completePressAsync` and `settleRewrites` are `@MainActor` for this
  reason.
- **Don't hold indices across `await`.** Segments can be reset by a click or keystroke while
  a paste is in flight. Re-look them up by id afterwards (`5da6c2c`).
- **AVAudioEngine reports a stale format after a device switch.** After pointing the input
  unit at another device, the node's output format can still be the old device's (for
  example AirPods at 24 kHz), and a tap in that format never fires. Tap at
  `inputFormat(forBus: 0)` and convert (`047b9fc`).
- **Opening a Bluetooth mic flips AirPods into HFP** (call mode), which interrupts music.
  Record from the built-in mic instead.
- **Electron apps need `AXManualAccessibility = true`.** Without it their AX tree is empty
  below the window. The tree is built lazily and slowly, so set it early for every running
  regular app and for each new launch.
- **Menu-bar-only apps have no main menu, so ⌘V/⌘C/⌘A don't work in text fields.** Those
  shortcuts are routed through the Edit menu. `installEditMenu()` adds one (`d6f0c34`).
- **Synthetic input and the held talk key.** Events posted from the combined session state
  inherit the physically held Right ⌥, which turns clicks into Option-clicks (a new cursor
  in VS Code). Use a private `CGEventSource` and set flags explicitly.
- **Clipboard restore timing.** Don't restore after a fixed delay; use promised data
  (see [speech.md](speech.md#clipboard-handling-inputpaste-in-windowcontrolswift)).
- **Never fall back to "some window of the app".** If the target window can't be resolved,
  copy the text to the clipboard instead of pasting into the wrong place (`36db3e1`).
- **Ignore key-up after a calibration tap.** It used to send empty audio to Whisper.
- **Camera presets reset the frame duration on `startRunning`.** Set the 8 fps cap after
  starting.
- **Whisper hallucinates on silence** ("Thank you.", "Untertitel der Amara.org-Community").
  Gate phrases on detected speech and drop the stock phrases.
- **Pause threshold:** 0.45 s split sentences mid-way; 0.7 s works.
- **Parakeet wants at least ~1 s of audio.** Pad short phrases with silence.
- **The first OpenAI request pays for TLS/HTTP2 setup.** Warm the connection on key-down.
- **whisper-server's first start compiles Metal shaders.** Allow up to 60 s before
  giving up.
- **The menu-bar icon can hide behind the notch** when the menu bar is crowded. Reopening
  the app pops the menu at the mouse.


### Learned gaze model

```bash
tools/.venv/bin/pip install torch coremltools pillow
curl -L -o tools/weights/mobileone_s0.pt https://github.com/yakhyo/gaze-estimation/releases/download/weights/mobileone_s0.pt
curl -L -o tools/weights/mobileone_s0_gaze.onnx https://github.com/yakhyo/gaze-estimation/releases/download/weights/mobileone_s0_gaze.onnx
tools/.venv/bin/python tools/convert_gaze_coreml.py   # installs GazeMobileOne.mlpackage, checks parity vs ONNX
```

The model architecture is vendored in `tools/third_party/gaze_estimation/` (MIT). Weights are
Gaze360-trained: research / non-commercial only.
