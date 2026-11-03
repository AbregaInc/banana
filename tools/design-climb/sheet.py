#!/usr/bin/env python3
"""A contact sheet of one capture run, to check by eye that every state is the right screen:
sheet.py <run> [--device phone] [--width 360] [--cols 6]  →  <run>/sheet-<device>.png"""
import argparse, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
sys.dont_write_bytecode = True
RUNS = Path(__file__).resolve().parents[2] / "design-climb/runs"
ap = argparse.ArgumentParser(); ap.add_argument("run"); ap.add_argument("--device", default="phone")
ap.add_argument("--width", type=int, default=360); ap.add_argument("--cols", type=int, default=6)
a = ap.parse_args()
run = Path(a.run) if Path(a.run).is_dir() else RUNS / a.run
shots = sorted(run.glob(f"{a.device}-*.png"))
font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22)
thumbs = []
for p in shots:
    im = Image.open(p).convert("RGB"); h = int(im.height * a.width / im.width)
    thumbs.append((p.stem[len(a.device) + 1:], im.resize((a.width, h))))
rows = (len(thumbs) + a.cols - 1) // a.cols
th = max(t.height for _, t in thumbs) + 36
sheet = Image.new("RGB", (a.cols * (a.width + 12) + 12, rows * th + 12), "#888")
d = ImageDraw.Draw(sheet)
for i, (name, t) in enumerate(thumbs):
    x = 12 + (i % a.cols) * (a.width + 12); y = 12 + (i // a.cols) * th
    d.text((x, y), name, fill="black", font=font); sheet.paste(t, (x, y + 30))
out = run / f"sheet-{a.device}.png"; sheet.save(out); print(out)
