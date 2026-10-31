#!/usr/bin/env python3
"""Optional App Store header/search artwork using the website brand and real app UI."""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw
from compose import font, FONT_DISPLAY, FONT_BODY, place_panel, crop_normalized, rgb


def compose(output: Path) -> None:
    destination = output/"creative/en-US"
    destination.mkdir(parents=True, exist_ok=True)
    cream, ink = rgb("#FBF6EA"), rgb("#221D38")
    for kind, size in [("header", (3840, 1646)), ("search", (1920, 1280))]:
        canvas = Image.new("RGBA", size, (*cream, 255))
        draw = ImageDraw.Draw(canvas)
        factor = size[0]/1920
        x = round(100*factor)
        top = round((170 if kind == "header" else 210)*factor)
        draw.text((x, top), "Banana", fill=ink, font=font(FONT_DISPLAY, round(35*factor)))
        face = font(FONT_DISPLAY, round(78*factor))
        for row, text in enumerate(["Many calendars.", "One you."]):
            draw.text((x, top+round((100+row*100)*factor)), text, fill=ink, font=face)
        if kind == "header":
            raw = Image.open(output/"raw/mac/01-plan.png").convert("RGB")
            width, position = 1940, (1740, 250)
            draw.rounded_rectangle((1680, 185, 3750, 1530), radius=24, fill=rgb("#FFD84A"))
        else:
            raw = crop_normalized(Image.open(output/"raw/iphone/01-plan.png").convert("RGB"), [0, .055, 1, .8])
            width, position = 660, (1160, 130)
            draw.rounded_rectangle((1110, 80, 1870, 1330), radius=20, fill=rgb("#FFD84A"))
        place_panel(canvas, raw, position, width, radius=20, border=ink, shadow=ink, border_width=7)
        canvas.convert("RGB").save(destination/f"{kind}-{size[0]}x{size[1]}.png", optimize=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2]/"AppStore/Generated")
    compose(parser.parse_args().output)
