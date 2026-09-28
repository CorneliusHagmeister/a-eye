"""Compare gaze approaches on a recorded A-EYE test set.

Replays the frames saved by "Record gaze test set…", runs public learned gaze models
(yakhyo/gaze-estimation, Gaze360-trained — research use only) on the face crops, and fits the
same geometric screen model A-EYE uses with different eye inputs:

  head only · head + pupils (what A-EYE ships) · head + learned gaze · head + both
  learned gaze on its own (the model's angle replaces head angle in the ray)

Errors are leave-one-dot-out on real data, in screen points; also per held-out phase.

    tools/.venv/bin/python tools/eval_gaze.py [recording_dir]
"""
import glob
import json
import math
import os
import sys
import time

import cv2
import numpy as np
import onnxruntime as ort

HERE = os.path.dirname(os.path.abspath(__file__))
TAN_H, TAN_V = 0.58, 0.47  # same camera FOV assumption as GazeModel.swift
GAINS = np.round(np.arange(0.6, 2.41, 0.1), 2)


class LearnedGaze:
    """yakhyo/gaze-estimation ONNX: 448² RGB face crop → yaw/pitch (deg), 90 bins of 4°."""

    def __init__(self, path):
        self.name = os.path.basename(path).replace("_gaze.onnx", "")
        self.sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        self.inp = self.sess.get_inputs()[0].name
        self.idx = np.arange(90, dtype=np.float32)

    def __call__(self, crop_bgr):
        x = cv2.resize(cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2RGB), (448, 448)).astype(np.float32) / 255.0
        x = (x - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]
        x = np.transpose(x, (2, 0, 1))[None].astype(np.float32)
        yaw_l, pitch_l = self.sess.run(None, {self.inp: x})
        def dec(l):
            e = np.exp(l - l.max(axis=1, keepdims=True)); p = e / e.sum(axis=1, keepdims=True)
            return float((p * self.idx).sum() * 4 - 180)
        return dec(yaw_l), dec(pitch_l)


def face_crop(img, bbox, scale=1.15):
    """Vision bbox (normalised, origin bottom-left) → square BGR crop, a little padded."""
    H, W = img.shape[:2]
    bx, by, bw, bh = bbox
    cx, cy = (bx + bw / 2) * W, (1 - (by + bh / 2)) * H
    side = max(bw * W, bh * H) * scale
    x0, y0 = int(max(0, cx - side / 2)), int(max(0, cy - side / 2))
    return img[y0:int(min(H, cy + side / 2)), x0:int(min(W, cx + side / 2))]


def load(rec_dir, models):
    rows = [json.loads(l) for l in open(os.path.join(rec_dir, "frames.jsonl"))]
    t0 = time.time()
    for i, r in enumerate(rows):
        img = cv2.imread(os.path.join(rec_dir, r["file"]))
        crop = face_crop(img, r["bbox"])
        for m in models:
            r[m.name] = m(crop)
        if i % 100 == 0:
            print(f"  {i}/{len(rows)} frames ({time.time() - t0:.0f}s)", flush=True)
    return rows


def points(rows, models):
    """Median per chunk of ≤4 consecutive frames within a dot (like calibration)."""
    by_step = {}
    for r in rows:
        by_step.setdefault(r["step"], []).append(r)
    pts = []
    for step, fr in sorted(by_step.items()):
        for c in range(0, len(fr), 4):
            ch = fr[c:c + 4]
            if len(ch) < 2:
                continue
            med = lambda k: float(np.median([f[k] for f in ch]))
            p = {k: med(k) for k in ["yaw", "pitch", "faceX", "faceY", "faceSize", "pupilX", "pupilY", "dotX", "dotY"]}
            for m in models:
                p[m.name] = (float(np.median([f[m.name][0] for f in ch])), float(np.median([f[m.name][1] for f in ch])))
            p["step"], p["label"] = step, ch[0]["label"]
            pts.append(p)
    return pts


def plane(p, gx, gy, yaw, pitch):
    hz = 0.2 / max(p["faceSize"], 0.02)
    u = -((p["faceX"] - 0.5) * 2 * TAN_H * hz + gx * hz * math.tan(math.radians(yaw)))
    v = -(p["faceY"] - 0.5) * 2 * TAN_V * hz + gy * hz * math.tan(math.radians(pitch))
    return u, v, hz


def design(pts, gx, gy, variant, model=None, mean_pupil=(0, 0), mean_model=(0, 0)):
    X = []
    for p in pts:
        if variant == "learned only":
            my, mp = p[model]
            u, v, hz = plane(p, gx, gy, my, -mp)  # model: + pitch = up; ours: − pitch = up
        else:
            u, v, hz = plane(p, gx, gy, p["yaw"], p["pitch"])
        f = [1, u, v, u * u, v * v, u * v]
        if variant in ("head + pupils", "head + pupils + learned"):
            f += [hz * (p["pupilX"] - mean_pupil[0]) * 10, hz * (p["pupilY"] - mean_pupil[1]) * 10]
        if variant in ("head + learned", "head + pupils + learned"):
            my, mp = p[model]
            f += [hz * math.tan(math.radians(my - mean_model[0])), hz * math.tan(math.radians(mp - mean_model[1]))]
        X.append(f)
    return np.array(X)


def fit(X, y, lam=1e-6):
    A = X.T @ X + lam * np.diag([0] + [1] * (X.shape[1] - 1))
    return np.linalg.solve(A, X.T @ y)


def evaluate(pts, variant, model=None):
    tx, ty = np.array([p["dotX"] for p in pts]), np.array([p["dotY"] for p in pts])
    mp = (np.mean([p["pupilX"] for p in pts]), np.mean([p["pupilY"] for p in pts]))
    mm = (np.mean([p[model][0] for p in pts]), np.mean([p[model][1] for p in pts])) if model else (0, 0)
    gains = [(gx, gy) for gx in GAINS for gy in GAINS]
    if variant == "learned only":  # sign of the model's yaw vs ours is part of the search
        gains += [(-gx, gy) for gx, gy in gains]
    best = None
    for gx, gy in gains:  # gains chosen on all data (cheap; tiny leak), LS refit per fold below
        X = design(pts, gx, gy, variant, model, mp, mm)
        cx, cy = fit(X, tx), fit(X, ty)
        sse = ((X @ cx - tx) ** 2 + (X @ cy - ty) ** 2).sum()
        if best is None or sse < best[0]:
            best = (sse, gx, gy, X)
    _, gx, gy, X = best
    steps = np.array([p["step"] for p in pts])
    labels = np.array([p["label"] for p in pts])
    err = np.zeros(len(pts))
    for s in np.unique(steps):  # leave-one-dot-out
        tr, te = steps != s, steps == s
        cx, cy = fit(X[tr], tx[tr]), fit(X[tr], ty[tr])
        err[te] = np.hypot(X[te] @ cx - tx[te], X[te] @ cy - ty[te])
    held = {}
    for lab in np.unique(labels):  # leave-one-phase-out: robustness to unseen conditions
        tr, te = labels != lab, labels == lab
        if te.sum() < 3 or tr.sum() < X.shape[1] + 2:
            continue
        cx, cy = fit(X[tr], tx[tr]), fit(X[tr], ty[tr])
        held[lab] = float(np.median(np.hypot(X[te] @ cx - tx[te], X[te] @ cy - ty[te])))
    return float(np.median(err)), held, (gx, gy)


def main():
    rec = sys.argv[1] if len(sys.argv) > 1 else sorted(glob.glob(os.path.expanduser(
        "~/Library/Application Support/A-EYE/gaze-recordings/*")))[-1]
    models = [LearnedGaze(p) for p in sorted(glob.glob(os.path.join(HERE, "weights", "*.onnx")))]
    print(f"recording: {rec}\nmodels: {[m.name for m in models]}")
    rows = load(rec, models)
    pts = points(rows, models)
    print(f"{len(rows)} frames → {len(pts)} data points over {len({p['step'] for p in pts})} dots\n")
    variants = [("head only", None), ("head + pupils", None)]
    for m in models:
        variants += [("head + learned", m.name), ("head + pupils + learned", m.name), ("learned only", m.name)]
    phases = sorted({p["label"] for p in pts})
    print(f"{'variant':44} {'dot-out':>8}   held-out phase: " + " · ".join(phases))
    for variant, model in variants:
        med, held, g = evaluate(pts, variant, model)
        name = variant + (f" [{model}]" if model else "")
        print(f"{name:44} {med:7.0f}px   " + " · ".join(f"{held.get(ph, float('nan')):4.0f}" for ph in phases)
              + f"   (gains {g[0]:.1f}/{g[1]:.1f})")


if __name__ == "__main__":
    main()
