"""Convert the MobileOne-S0 gaze model (yakhyo/gaze-estimation) to Core ML for A-EYE.

The package takes a 448×448 RGB face crop (Vision scales the face region for us) and returns
`gaze` = [yaw°, pitch°]: ImageNet normalisation and the 90-bin softmax decode are built in.
It then checks the conversion against the ONNX export on frames from a recorded test set.

    tools/.venv/bin/python tools/convert_gaze_coreml.py [recording_dir]

Output: ~/Library/Application Support/A-EYE/models/GazeMobileOne.mlpackage
Weights are Gaze360-trained: research / non-commercial use only.
"""
import glob
import json
import os
import sys

import coremltools as ct
import numpy as np
import torch
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "third_party", "gaze_estimation"))
from mobileone import mobileone_s0, reparameterize_model  # noqa: E402

OUT = os.path.expanduser("~/Library/Application Support/A-EYE/models/GazeMobileOne.mlpackage")


class GazeHead(torch.nn.Module):
    """RGB in [0,1] → normalise → MobileOne → softmax expectation over 4° bins → degrees."""

    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))
        self.register_buffer("idx", torch.arange(90, dtype=torch.float32))

    def forward(self, x):
        yaw_l, pitch_l = self.net((x - self.mean) / self.std)
        yaw = (torch.softmax(yaw_l, dim=1) * self.idx).sum(dim=1) * 4 - 180
        pitch = (torch.softmax(pitch_l, dim=1) * self.idx).sum(dim=1) * 4 - 180
        return torch.stack([yaw, pitch], dim=1)


def build():
    state = torch.load(os.path.join(HERE, "weights", "mobileone_s0.pt"), map_location="cpu")
    try:  # the release file may be the fused (inference-mode) or the training-time weights
        net = mobileone_s0(pretrained=False, num_classes=90, inference_mode=True)
        net.load_state_dict(state)
        print("loaded fused weights")
    except RuntimeError:
        net = mobileone_s0(pretrained=False, num_classes=90)
        net.load_state_dict(state)
        net = reparameterize_model(net.eval())
        print("loaded training weights, reparameterised")
    return GazeHead(net.eval()).eval()


def convert(model):
    example = torch.rand(1, 3, 448, 448)
    traced = torch.jit.trace(model, example)
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="face", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="gaze")],
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
    )
    ml.short_description = "Gaze yaw/pitch (degrees) from a face crop. MobileOne-S0, yakhyo/gaze-estimation " \
                           "(MIT code; Gaze360-trained weights: research / non-commercial use only)."
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    ml.save(OUT)
    print(f"saved {OUT}")
    return ml


def check(ml, rec):
    """Same crops through ONNX and Core ML: the conversion should not move the angles."""
    import onnxruntime as ort
    sys.path.insert(0, HERE)
    from eval_gaze import LearnedGaze, face_crop
    import cv2
    onnx = LearnedGaze(os.path.join(HERE, "weights", "mobileone_s0_gaze.onnx"))
    rows = [json.loads(l) for l in open(os.path.join(rec, "frames.jsonl"))][::25]
    diffs = []
    for r in rows:
        crop = face_crop(cv2.imread(os.path.join(rec, r["file"])), r["bbox"])
        a = np.array(onnx(crop))
        img = Image.fromarray(cv2.cvtColor(cv2.resize(crop, (448, 448)), cv2.COLOR_BGR2RGB))
        b = np.array(ml.predict({"face": img})["gaze"]).reshape(-1)
        diffs.append(np.abs(a - b))
    d = np.array(diffs)
    print(f"parity on {len(d)} frames: mean |Δ| yaw {d[:, 0].mean():.2f}° pitch {d[:, 1].mean():.2f}° · max {d.max():.2f}°")


if __name__ == "__main__":
    model = build()
    ml = convert(model)
    rec = sys.argv[1] if len(sys.argv) > 1 else sorted(glob.glob(os.path.expanduser(
        "~/Library/Application Support/A-EYE/gaze-recordings/*")))[-1]
    check(ml, rec)
