#!/usr/bin/env python3
"""Covers real account names in a Mac capture: the Beta signs in with the Mac's own Google
accounts (Keychain), so its Settings shows them. redact.py <png> x0,y0,x1,y1=text ..."""
import sys
from PIL import Image, ImageDraw, ImageFont
sys.dont_write_bytecode = True
path = sys.argv[1]
im = Image.open(path).convert("RGB"); d = ImageDraw.Draw(im)
scale = im.width / 1320
for spec in sys.argv[2:]:
    box, text = spec.split("=", 1)
    x0, y0, x1, y1 = (int(int(v) * scale) for v in box.split(","))
    bg = im.getpixel((max(x0 - 4, 0), (y0 + y1) // 2))
    d.rectangle((x0, y0, x1, y1), fill=bg)
    fg = (235, 235, 240) if sum(bg) < 380 else (20, 20, 25)
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", int((y1 - y0) * 0.62))
    d.text((x0, (y0 + y1) // 2), text, fill=fg, font=font, anchor="lm")
im.save(path)
