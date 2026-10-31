#!/usr/bin/env python3
"""Contact sheets of a captured device, for checking a run by eye: sheet.py <device> [--per N]."""
import argparse, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
ap = argparse.ArgumentParser(); ap.add_argument("device"); ap.add_argument("--per", type=int, default=24)
ap.add_argument("--width", type=int, default=300); ap.add_argument("--cols", type=int, default=8)
a = ap.parse_args()
base = ROOT / "design-atlas/screens" / a.device
shots = sorted(p for p in base.rglob("*.png"))
font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 22)
out = ROOT / "design-atlas/sheets"; out.mkdir(parents=True, exist_ok=True)
for n in range(0, len(shots), a.per):
    chunk = shots[n:n + a.per]
    thumbs = []
    for p in chunk:
        im = Image.open(p).convert("RGB"); h = int(im.height * a.width / im.width)
        thumbs.append((p.relative_to(base).with_suffix("").as_posix(), im.resize((a.width, h))))
    cell_h = max(t.height for _, t in thumbs) + 34
    rows = (len(thumbs) + a.cols - 1) // a.cols
    sheet = Image.new("RGB", (a.cols * (a.width + 10), rows * cell_h), "white")
    d = ImageDraw.Draw(sheet)
    for i, (name, t) in enumerate(thumbs):
        x, y = (i % a.cols) * (a.width + 10), (i // a.cols) * cell_h
        d.text((x + 2, y + 4), name, fill="black", font=font)
        sheet.paste(t, (x, y + 32))
    path = out / f"{a.device}-{n // a.per + 1}.png"; sheet.save(path); print(path)
