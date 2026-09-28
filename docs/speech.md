# Speech, commands, clean-up and delivery

## Engines

Choose one from menu › Engine. The choice is stored in `Settings.engine` (default
`parakeet`). If the chosen engine can't be built, the app tries Parakeet → Whisper → Apple.

| id | Engine | Where | How it streams |
|---|---|---|---|
| `parakeet` | **Parakeet TDT v3** via [FluidAudio](https://github.com/FluidInference/FluidAudio) | Local, Neural Engine | `ChunkedEngine`: phrase per pause, plus live partials every 0.5 s |
| `whisper` | whisper.cpp (`whisper-server`, falling back to `whisper-cli`) | Local | `ChunkedEngine`: phrase per pause, no partials |
| `wispr` | Wispr Flow REST, one call per phrase | Cloud | `ChunkedEngine` |
| `deepgram` | Deepgram Nova-3 | Cloud, WebSocket | Native interim and final results |
| `openai` | OpenAI Realtime, `gpt-live-transcribe` | Cloud, WebSocket | Native deltas; A-EYE's segmenter commits the phrases |
| `apple` | `SFSpeechRecognizer`, on-device | Local | Fallback only; not in the menu |

- **Parakeet** (`Parakeet.swift`) loads on the first key-down (`prepare`) and unloads after
  5 idle minutes. Phrases shorter than 1 s are padded with silence. If `Settings.languages`
  holds exactly one language, it's passed to the model; otherwise the language is
  auto-detected. Measured in `95cea43`: **~0.08 s per phrase, 0.2 s warm load, ~100 MB**;
  English and German verified. It needs a Swift 6 toolchain, because the code is gated
  behind `#if canImport(FluidAudio)`.
- **Whisper** (`Transcriber.swift`) needs `brew install whisper-cpp` plus a `*.bin` ggml
  model in `~/Library/Application Support/A-EYE/models/`; the first file alphabetically
  wins. On key-down it starts `whisper-server` on `127.0.0.1:18178`, so the model loads
  while you speak. On first run, Metal shader compilation can take up to 60 s. The server
  stops after 5 idle minutes to free about 700 MB. If the server isn't ready or the request
  fails, it falls back to one-shot `whisper-cli`. The prompt contains vocabulary hints plus
  the last 200 characters of the previous phrase, and `[BLANK_AUDIO]` is stripped.
- **Wispr Flow** sends the base64 WAV per phrase and tells Flow that the destination is an
  AI app, including the previous phrase as `before_text`. Per-phrase REST is used because
  their WebSocket API only returns text at the end.
- **Deepgram** uses `language=multi` (English/German code-switching) unless exactly one
  language is configured. It sends `endpointing=300` and up to 20 `keyterm` hints. On
  release it sends `Finalize` + `CloseStream` and ends when `Metadata` arrives (or after
  6 s).
- **OpenAI** uses `turn_detection: null`, because A-EYE's `Segmenter` decides when to send
  `input_audio_buffer.commit` (silent phrases are cleared instead). Audio is resampled to
  24 kHz. Completions can arrive out of order, so they're re-emitted in commit order.
- **Vocabulary hints** (`sessionContext`) are the pinned target names plus a fixed list of
  dev terms ("Claude", "VS Code", "TypeScript", "git", "PR", …).
- **Fallback:** if a press ends with an error and no phrases, the saved WAV is transcribed
  with `Engines.localTranscriber()` (Parakeet if built with FluidAudio, else Whisper or
  Apple). Failed presses in menu › Recent can be retried locally; that result goes to the
  clipboard.

Cloud API keys are stored in the Keychain with account = engine id. The OpenAI key (account
`openai`) is shared by the OpenAI engine and OpenAI clean-up.

## Phrase segmentation (`Segmenter.swift`)

"Streaming" for clip transcribers means **committing a phrase at every pause**. Committed
text never changes, which is what makes it safe to paste immediately.

- Frame RMS is computed over 30 ms frames. A frame counts as speech when
  `rms > max(3·noiseFloor, 0.004)`. The noise floor adapts to the quietest of the last 40
  frames.
- A phrase ends after **~0.7 s of quiet** (23 frames), once at least ~0.5 s of speech
  (17 frames) has been heard. 200 ms of tail audio is kept. Before `6c0ac63` the pause
  threshold was 0.45 s, which split sentences mid-way.
- Run-on speech is cut at the quietest frame in the last 3 s once the phrase passes 12 s.
- `hasSpeech` requires at least 10 speech frames. Together with a junk list ("Thank you.",
  "Thanks for watching!", "Untertitel der Amara.org-Community", …) this filters Whisper's
  stock hallucinations on silence.

## Paste modes

- **Paste while speaking** (default, `Settings.pasteWhileSpeaking`): each `.final` phrase
  is interpreted for commands and pasted as you pause. Voice commands act per phrase.
- **Paste on release:** phrases are collected, shown live in the overlay, then interpreted
  and pasted as a whole when the key is released.
- Consecutive pastes into the same box are joined with a space.

## Voice commands (`VoiceCommands.swift`)

Commands are read from the **raw** engine text, before clean-up. Matching is
case-insensitive and ignores punctuation.

| Say | Effect |
|---|---|
| "scratch that" / "undo that" / "delete that" / "strike that" **on its own** | Removes the last segment A-EYE pasted into this box (⌫ × its length) |
| "…first idea. **Scratch that.** Second idea." | Drops the sentence before it (only "scratch that" / "strike that" are recognised mid-text) |
| "**Scratch that.** New text" | Undoes the last paste, then pastes the new text |
| "clear the input" / "clear input" / "clear the field" / "clear the box" / "clear everything" / "clear it all" / "clear all", **on its own or leading** | ⌘A ⌫, but only if the target is a detected text input (never a code editor, where ⌘A would select the file) |
| "…, send it" / "send that" / "submit it" / "submit that" / "press enter" / "hit enter", **trailing** | Presses Return after the text (and any clean-up) is in |

Destructive commands only trigger in these positions, so "can you clear the input field in
the form?" stays plain text. Run `--commands-test` to see how sample sentences parse.

With **OpenAI clean-up**, a phrase that starts with "scratch that" (or is only "scratch
that") isn't executed as an undo once the press already has text. The phrase is pasted (basic-tidied)
and left for the rewrite to apply in context, because after a rewrite the whole press is
one segment and a blind undo would remove all of it. Any "clear" or "send it" in that same
phrase is currently ignored.

## Clean-up (`Cleanup.swift`)

`Settings.cleanup`: `off` | `basic` (default) | `openai`.

### Basic (local, instant)

Regexes remove fillers (um, uh, erm, hmm, mhm, äh, öh…, including an attached comma) and
immediate word repeats ("I I think" → "I think"). They also fix spacing before punctuation
and capitalise the first letter. Word boundaries keep "umbrella" and "humble" intact; see
the samples in `--commands-test`.

### OpenAI rolling rewrite

Model: `Settings.cleanupModel`, default **`gpt-6-luna`**. Requests use
`reasoning_effort: "none"`, because reasoning is pure latency here. For models named
`gpt-4*`, `temperature: 0` is used instead.

1. Each phrase is pasted immediately, **basic-tidied**, and appended to `press.pieces`.
2. The **whole press so far** is sent to `/v1/chat/completions` with instructions to join
   pause-split fragments, drop fillers and false starts, apply self-corrections ("Tuesday,
   actually make it Wednesday" → "Wednesday"), fix punctuation and mis-heard technical
   terms, keep the language (English/German) and wording, and never answer the question.
   This replaced per-sentence clean-up in `66385db`, because a sentence at a time saw
   fragments like "…to be able to." and punctuated them as sentences.
3. Only **one request is in flight per press**. Anything said meanwhile marks the press
   dirty and triggers another pass with the latest text.
4. The result is queued as a `.rewrite` job. Delivery computes the **common prefix** between
   what it pasted and the new text, backspaces only from the first difference and pastes
   the rest, so text you've already read stays put.
5. **Guards:** the output must have a length ratio in `(0.3, 1.25)` compared with the
   input. Self-corrections can legitimately shorten it, but answering or padding can't pass
   the ratio check. Any error or timeout (4 s + 1 s per 250 chars) keeps the quick-tidied
   text.
6. On release, `settleRewrites` waits until the rewrite covers everything said, while the
   overlay shows "Polishing…". Only then is Return pressed for "send it" or auto-send.
7. `Cleanup.warm()` on key-down pre-opens TLS/HTTP2 to OpenAI (at most once a minute).
   Without it, connection setup ate the first request's time budget.

In the author's recent log, rewrites of 60–300 characters took about 1.0–1.7 s each.


## Delivery and editing in place (`Dispatcher.swift`)

- Jobs run **strictly in order**, on the main actor, each into its press's target.
- Every pasted piece becomes a **segment** `(id, press, text)` for the current box
  (`Target.key`). Rewrites, replacements and "scratch that" backspace over exactly those
  characters.
- **Segments are forgotten** (and in-place editing stops) when:
  - you click anywhere (mouse-down more than 0.5 s after A-EYE's own synthetic click),
  - you type while the talk key isn't held,
  - focus moves to a different box, or
  - a submit is sent.
- **Before every blind edit**, `boxEndsWith` reads the focused element's `AXValue`
  (whitespace-normalised) and requires it to end with the text A-EYE believes it typed.
  If not, the edit is skipped and segments are cleared. If the app doesn't expose its
  value, A-EYE trusts its own record. Edit sizes are capped at 3000–4000 characters.
- After every `await`, segments are looked up again by id or press. Clicking or typing
  during an edit can reset them, and using indices captured before the await used to crash
  (`5da6c2c`).

## Clipboard handling (`Input.paste` in `WindowControl.swift`)

Pasting goes through the clipboard (⌘V), which is the only thing that works reliably
across native, Electron and terminal inputs. The previous clipboard is saved, including
all types of all items, and restored afterwards.

**The re-paste bug (`4736c69`).** Paste used to restore the old clipboard after a fixed
300 ms. An app busy streaming a reply (Claude) handled ⌘V later than that, read the
*restored* clipboard, and pasted old text. That old text was often an earlier dictation
that had been copied there as an "undeliverable" fallback.

**The fix: promised data.** The text is put on the pasteboard as an `NSPasteboardItem`
with a data provider (`PasteProvider`) instead of as a string. The receiving app pulls the
data when it actually processes the paste, the provider records `delivered`, and only
then is the old clipboard restored:

```swift
item.setDataProvider(provider, forTypes: [.string])
pb.clearContents(); pb.writeObjects([item])
key(9, flags: .maskCommand)                          // ⌘V
while !provider.delivered, elapsed < 1.5 { sleep 20ms }
if submit { key(36) }                                // Return, once the text is in
sleep 250ms; restore saved items
```

If the app hasn't read the clipboard after 1.5 s, this is logged
(`paste: the app didn't read the clipboard within 1.5s`) and the clipboard is restored
anyway. Synthetic keys and clicks use a private `CGEventSource` with explicit flags, so the
physically held Right ⌥ doesn't turn ⌘V into ⌥⌘V or a click into an Option-click (which
adds a cursor in VS Code). Run `--clipboard-test` to check the promise mechanism against a
real app.

**When delivery fails** (the target window is closed or on another Space), the press's text
is put on the clipboard as a plain string and the overlay says so. Text is never pasted
into whatever window happens to be in front.
