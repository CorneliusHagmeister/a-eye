# Gaze estimation

The goal is modest: pick **which window, or which half of a split pane**, you're looking at.
It isn't meant to be a pixel-accurate eye tracker. The model is geometric plus a small
linear fit, so a few minutes of calibration are enough and behaviour outside the
calibrated range stays physically sensible.

Code: `GazeTracker.swift` (signals), `ScreenGaze.swift` (`GazeModel`, `CalibrationData`,
`ScreenCalibrator`).

## Signals (per frame, 8 fps, 720p)

| Field | Source | Meaning |
|---|---|---|
| `yaw`, `pitch` | Vision face rectangles rev3 | Head direction in degrees. Yaw is positive when looking to your left; negative pitch is up. |
| `faceX`, `faceY` | face bounding-box centre | Where your head is in the image (0…1) |
| `faceSize` | bounding-box width | Shrinks as you lean back, so it's used as a distance proxy |
| `pupilX`, `pupilY` | Vision landmarks rev3, pupil vs. eye-outline centroid | The eyes' own contribution, in eye-widths, averaged over both eyes |
| `hasEyes` | landmarks found and eye open | If false, the pupil terms fall back to the calibration mean |

720p is used so that each eye is about 40 px wide. At the earlier CIF preset it was about
12 px.

## The model

1. **Distance:** `hz = 0.2 / faceSize` (≈1 at a typical desk distance).
2. **Ray to the screen plane:** the head position comes from the face offset, scaled by an
   assumed camera field of view (`tanH = 0.58`, `tanV = 0.47`), and the head direction is
   scaled by per-axis gains `gx`, `gy`:

   ```
   u = −[(faceX − 0.5)·2·tanH·hz + gx·hz·tan(yaw)]
   v =  −(faceY − 0.5)·2·tanV·hz + gy·hz·tan(pitch)
   ```

   Leaning back (larger `hz`) or shifting sideways (a different `faceX`) therefore moves
   the estimate the way it physically would, instead of breaking the fit.
3. **Eye terms** are measured relative to your *resting* pupil (the calibration mean) and
   scaled by distance, because the same eye rotation covers more screen from further away:
   `10·hz·(pupilX − meanX)`, `10·hz·(pupilY − meanY)`. The factor 10 brings them onto a
   scale similar to `u` and `v`. Subtracting the mean matters: the raw landmark isn't
   centred at 0, and scaling a non-zero offset by distance would shift everything when you
   lean back.
4. **Plane to monitors:** a least-squares map from `[1, u, v, u², v², uv] (+ eye terms)`
   to global screen x and y. It's quadratic when there are at least 12 points (at least 16
   with eyes) and linear otherwise. A tiny ridge penalty (λ = 1e-6) is applied, but not to
   the intercept.
5. **Gains:** a grid search over `gx, gy ∈ [0.3, 3.0]` in 0.1 steps (widened after a real
   calibration hit both edges of 0.6–2.4). Each candidate costs
   `SSE + 3000·N·((gx−c)² + (gy−c)²)` px², where the prior centre `c` is 1.0 with eye data
   and 1.3 without (without eye data the head must also explain the eyes' share).
6. **Eyes on or off:** eye terms are used only if at least 80 % of points have pupils and
   there are at least 10 points.

At runtime the prediction is smoothed with an EMA (α = 0.5) on top of the tracker's own
EMA, and clamped onto the nearest display. If `hz` is outside `[hzMin/1.2, 1.2·hzMax]`,
a key-down shows "sitting differently from calibration — Add a posture" (at most once
every 5 min).

## Calibration phases

The full onboarding runs about 3 minutes. The calibrator itself estimates the time from
the step count: roughly 4 s per phase intro, 1.8 s per dot and 7.5 s per head-only step.
Dots are placed on each monitor's visible frame. The phases and the data each produces:

| # | Phase | Dots per monitor | Data |
|---|---|---|---|
| 1 | **Natural**: look at each dot as you normally would | 7 (centre, left/right edges, 4 corners) | 1 median sample per dot |
| 2 | **Eyes only**: nose stays on an anchor at the monitor centre, eyes follow the dot | 4 (±20 % horizontally, ±25 % vertically around the centre) | 1 per dot |
| 3 | **Head only**: eyes stay on the centre dot while the head turns slowly around it for 7 s | 1 | 1 per chunk of 4 frames (about every 0.5 s) |
| 4 | **Sitting up straight** | 4 (centre, both edges, top) | 1 per dot |
| 5 | **Leaned back a little** | 4 | 1 per dot |
| 6 | **Leaned right back** | 4 | 1 per dot |

For each dot there's a 0.9 s settle, then 0.9 s of frames are collected (head-only: 0.5 s
settle, 7 s collection). The frames are reduced to a per-field median; pupil medians use
only frames where the eyes were found. A dot with fewer than 3 face frames is skipped.

*Add a posture…* runs a single natural pass (5 dots per monitor) in your current posture,
appends it to the stored points and refits.

### Why each phase exists

- **Natural looking alone is not enough.** When you look at something naturally, your head
  and eyes turn together in a roughly fixed ratio, so head angle and pupil offset are
  collinear. The fit can't tell how much each one contributes. In simulation, adding pupil
  terms to natural-only data made eyes-only glances *worse*
  ([e20afc6](#known-numbers)).
- **Eyes only** varies the pupils while the head stays still. That pins down the eye
  terms, which is what makes a glance without a head turn move the estimate.
- **Head only** varies the head while the target stays fixed. That pins down the head gains
  independently of the eyes.
- **Postures** vary distance and height (`hz`, `faceY`). From one posture the gain is
  barely identifiable (hence the prior), and real-world effects the geometry doesn't model
  (camera FOV error, face-box scale changing with pitch) only show up when you actually sit
  differently. Three postures replaced a single "lean back" pass in `de7bbad`. In
  simulation, the two were about equal (see below). The extra passes guard against effects
  the simulation doesn't contain.

## Metrics

- **`errorPx` (shown after calibration and in the menu):** leave-one-*dot*-out median error,
  in screen points, with the gains fixed at the chosen values and the least-squares map
  refit per held-out dot. All points for the same dot are held out together — the head-only
  phase yields ~14 points per dot, and leaving out single points let their siblings flatter
  the score (the earlier per-point metric read ±299 px where the honest one reads ±346 px).
- **Held-out posture report (full onboarding only):** for each of *sitting straight*,
  *leaned back a little*, *leaned right back* and *eyes only*, the model is fit on every
  other phase and the median error is measured on the held-out phase. It answers "how would
  it cope with a posture or behaviour I never calibrated?" The report is logged and shown
  after calibration.
- The log also reports what a head-only model (no pupils) would score on the same data
  (`calibration: head-only would be ±…px`).

## Known numbers

Each number comes from either **simulation** or **real data**, and is labelled as such.

**Simulation** (`--gaze-fit-test`). A synthetic person at the author's 3-monitor layout
(laptop plus two 2560×1440 screens above it). The head turns 1/1.4 of the gaze angle and
the eyes do the rest. Pupil sensitivity is 0.0035 eye-widths/° horizontally and
0.0013/° vertically, taken from the real `--pupil-test` run. Head-pose noise is 1°. The
simulated person follows the model's own geometry exactly, so these numbers are
optimistic.

| Commit | Result |
|---|---|
| `b40a9ec` (geometric model, head only) | Unseen lean-back + shift posture: **~186 px** calibrated with one posture, **~99 px** with two |
| `e20afc6` (pupils + eyes-only/head-only phases) | Eyes-only glances **~500 px → ~60–80 px**. Natural and posture error roughly unchanged. |
| `de7bbad` (three postures) | Three postures ≈ one lean pass (`--gaze-fit-test --postures`, averaged over 20 fits) |

**Real data:**

| Source | Result |
|---|---|
| `27de0ac` `--pupil-test`, head held still | Vision pupil landmarks separate left/right gaze by **19.9σ** and up/down by **12.8σ**. Landmarks cost **~28 ms/frame** at 720p. |
| `spike/probe.log` (early yaw spike) | Vision face rects ~15 ms/frame, ~19 % of one core, peak RSS 187 MB (4.6 fps achieved) |
| Author's first full onboarding (3 monitors), fitted in-app | 109 points, all with eyes. Per-point LOO **±299 px**; head only **±604 px**. Gains `0.6`/`2.3` — both at or near the edge of the then 0.6–2.4 grid. Held out: sitting straight 231 px · leaned back a little 294 px · **leaned right back 712 px** · eyes only 312 px. |
| Same data, `--refit` with leave-one-dot-out and gains searched over 0.3–3.0 | **±346 px with eyes vs ±641 px head only**. `gx` lands on the new lower edge (0.3): horizontal head yaw explains less than the geometry expects — open question, to be checked against a recorded test set with `tools/eval_gaze.py`. |

## Limitations

- **Mostly head tracking.** Vision's pupil landmark is coarse (a few pixels inside a
  ~40 px eye). Pupils help with glances, but the estimate is dominated by head pose.
  Expect window-level or half-pane accuracy, not word-level.
- **Assumed camera geometry.** `tanH`/`tanV` are rough FaceTime-camera values. The camera
  is assumed to sit at the origin of the screen plane, and the fitted quadratic absorbs the
  rest.
- **Glasses glare and blinks** drop pupils. The model then uses the calibration-mean pupil,
  which degrades it to head-only for that frame.
- **One face.** The largest face in frame is used.
- **Gains at the grid boundary**, as in the real calibration above, suggest that the
  model's head/eye split doesn't fit real data well yet.

## Evaluating alternatives offline

1. Menu › **Record gaze test set (3 min, saves frames)…** runs the normal full onboarding.
   While each dot is being collected, it saves every processed frame that contains a face as a JPEG together
   with a `frames.jsonl` row. Each row holds the step, label, dot position, all
   `GazeSample` fields and the Vision face bbox (normalised, bottom-left origin). The
   output goes to `~/Library/Application Support/A-EYE/gaze-recordings/<stamp>/`. The run
   also produces a normal calibration.
2. Run `tools/eval_gaze.py` (setup in [development.md](development.md#python-tools)). It:
   - runs every `tools/weights/*_gaze.onnx` model on 448² face crops. These are
     yakhyo/gaze-estimation models (ResNet-50, MobileNetV2, MobileOne-S0). They are
     **trained on Gaze360, which is for research/non-commercial use only**, so they're for
     comparison, not for shipping.
   - forms data points from medians over chunks of ≤4 consecutive frames within each dot.
     Unlike the app, natural dots can yield more than one point.
   - fits the same geometric model with different eye inputs: *head only*, *head + pupils*
     (what ships), *head + learned*, *head + pupils + learned*, and *learned only* (the
     model's angles replace the head angles in the ray).
   - reports the **leave-one-dot-out** median error and the **held-out-phase** median per
     calibration phase. Gains are chosen on all data (a small, documented leak).

```bash
tools/.venv/bin/python tools/eval_gaze.py                       # latest recording
tools/.venv/bin/python tools/eval_gaze.py ~/Library/Application\ Support/A-EYE/gaze-recordings/<stamp>
```


## Learned gaze model (optional)

A-EYE can add a learned appearance-based gaze estimate as two more inputs to the geometric
model: **MobileOne-S0** from [yakhyo/gaze-estimation](https://github.com/yakhyo/gaze-estimation)
(MIT code, **Gaze360-trained weights: research / non-commercial use only** — so it is not
bundled). `tools/convert_gaze_coreml.py` converts it to Core ML with normalisation and the
90-bin decode built in and installs it at
`~/Library/Application Support/A-EYE/models/GazeMobileOne.mlpackage`; the app compiles it on
first use, runs it on the face crop via Vision (~6 ms/frame, Neural Engine) and exposes
menu › *Learned gaze model*. Toggling refits from the saved calibration samples; samples from
before the model was installed have no learned values, so recalibrate once to use it.

The learned angles enter like the pupils: relative to their calibration mean, projected with
the distance (`hz · tan(angle)`), weights learned per user by the calibration fit.

**Real data** (recorded test set, 646 frames / 72 dots, `tools/eval_gaze.py`, leave-one-dot-out):

| Inputs | Error | Held out: eyes only · head only · leaned back a little · leaned right back · sitting straight |
|---|---|---|
| head only | 426 px | 448 · 365 · 284 · 587 · 421 |
| head + pupils | 234 px | 230 · 141 · 221 · 489 · 236 |
| MobileOne-S0 alone | 281 px | 274 · 168 · 290 · 586 · 278 |
| **head + pupils + MobileOne-S0** | **168 px** | 166 · 104 · 151 · 333 · 179 |
| head + pupils + ResNet-50 / MobileNetV2 | 197 / 196 px | — |

Same session for calibration and test, one person, one lighting setup. Conversion parity:
Core ML vs ONNX on identical crops ±0.3° (fp16); the app's Vision crop/scale path vs the
Python OpenCV crop differs by ~2–3° mean (max ~7.5°), so in-app results may differ somewhat
from the offline table — calibration and runtime share the in-app path, so they stay consistent.
