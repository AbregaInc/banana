#!/usr/bin/env python3
"""Compose real Banana UI captures into exact-size App Store marketing artwork."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[2]
FONT_DISPLAY = (ROOT / "tools/app-store/fonts/IBMPlexMono-700.ttf",)
FONT_BODY = (ROOT / "tools/app-store/fonts/IBMPlexMono-400.ttf",)
FONT_LABEL = FONT_DISPLAY


def font(candidates: Iterable[Path], size: int) -> ImageFont.FreeTypeFont:
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size=size)
    return ImageFont.load_default(size=size)


def rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))


def mix(
    a: tuple[int, int, int],
    b: tuple[int, int, int],
    amount: float,
) -> tuple[int, int, int]:
    return tuple(round(x + (y - x) * amount) for x, y in zip(a, b))


def crop_normalized(source: Image.Image, crop: list[float] | None) -> Image.Image:
    if not crop:
        return source
    x, y, width, height = crop
    left = round(x * source.width)
    top = round(y * source.height)
    return source.crop(
        (
            left,
            top,
            left + round(width * source.width),
            top + round(height * source.height),
        )
    )


def wrapped_lines(
    draw: ImageDraw.ImageDraw,
    text: str,
    face: ImageFont.FreeTypeFont,
    max_width: int,
) -> list[str]:
    if "\n" in text:
        return text.splitlines()
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if not current or draw.textbbox((0, 0), candidate, font=face)[2] <= max_width:
            current = candidate
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def draw_tracked(
    draw: ImageDraw.ImageDraw,
    position: tuple[int, int],
    text: str,
    face: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int] | tuple[int, int, int, int],
    tracking: int,
) -> None:
    x, y = position
    for character in text:
        draw.text((x, y), character, font=face, fill=fill)
        x += round(draw.textlength(character, font=face)) + tracking


def paste_clipped(canvas: Image.Image, asset: Image.Image, position: tuple[int, int]) -> None:
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    layer.paste(asset, position, asset)
    canvas.alpha_composite(layer)


def rounded_asset(source: Image.Image, size: tuple[int, int], radius: int) -> Image.Image:
    fitted = source.convert("RGB").resize(size, Image.Resampling.LANCZOS)
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size[0] - 1, size[1] - 1),
        radius=radius,
        fill=255,
    )
    fitted.putalpha(mask)
    return fitted


def add_shadow(
    canvas: Image.Image,
    box: tuple[int, int, int, int],
    radius: int,
    color: tuple[int, int, int],
    opacity: int = 72,
    blur: int = 30,
    offset: int = 20,
) -> None:
    # The website uses a crisp offset outline, rather than a blurred drop shadow.
    draw = ImageDraw.Draw(canvas)
    shifted = (box[0] + 10, box[1] + 12, box[2] + 10, box[3] + 12)
    draw.rounded_rectangle(shifted, radius=radius, fill=(*rgb("#221D38"), 255))


def place_panel(
    canvas: Image.Image,
    source: Image.Image,
    position: tuple[int, int],
    width: int,
    radius: int,
    border: tuple[int, int, int],
    shadow: tuple[int, int, int],
    border_width: int = 10,
) -> tuple[int, int, int, int]:
    height = round(width * source.height / source.width)
    outer = (
        position[0] - border_width,
        position[1] - border_width,
        position[0] + width + border_width,
        position[1] + height + border_width,
    )
    add_shadow(canvas, outer, radius + border_width, shadow)
    border_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(border_layer).rounded_rectangle(
        outer,
        radius=radius + border_width,
        fill=(*border, 255),
    )
    canvas.alpha_composite(border_layer)
    paste_clipped(canvas, rounded_asset(source, (width, height), radius), position)
    return outer


def draw_campaign_background(
    size: tuple[int, int],
    background: tuple[int, int, int],
    accent: tuple[int, int, int],
    foreground: tuple[int, int, int],
    scene_number: int,
    scale: float = 1.0,
) -> Image.Image:
    canvas = Image.new("RGBA", size, (*background, 255))
    draw = ImageDraw.Draw(canvas)
    margin = round(72 * scale)
    draw.rounded_rectangle(
        (margin, round(690 * scale), size[0] - margin, size[1] + 100),
        radius=round(18 * scale), fill=(*accent, 255))
    return canvas


def add_campaign_header(
    canvas: Image.Image,
    scene: dict,
    foreground: tuple[int, int, int],
    accent: tuple[int, int, int],
    scene_number: int,
    max_width: int = 1130,
    scale: float = 1.0,
) -> int:
    def px(value: float) -> int:
        return round(value * scale)

    draw = ImageDraw.Draw(canvas)
    left = px(92)
    label_face = font(FONT_LABEL, px(27))
    draw.text((left, px(95)), "Banana", font=font(FONT_DISPLAY, px(42)), fill=foreground)
    draw.text((left, px(172)), scene["eyebrow"], font=label_face, fill=rgb("#766F90"))
    draw.line((left, px(228), canvas.width-left, px(228)), fill=rgb("#E6DCCB"), width=px(2))

    lines = scene["headline"].splitlines()
    size = px(112)
    while True:
        display_face = font(FONT_DISPLAY, size)
        if max(draw.textlength(line, font=display_face) for line in lines) <= max_width or size <= px(60):
            break
        size -= 1
    line_height = round(size * 1.18)
    for index, line in enumerate(lines):
        draw.text((left, px(272) + index * line_height), line, font=display_face, fill=foreground)

    subhead_y = px(272) + len(lines) * line_height + px(28)
    body_face = font(FONT_BODY, px(33))
    body_lines = wrapped_lines(draw, scene["subhead"], body_face, max_width)
    if len(body_lines) > 3:
        raise ValueError(f"Caption does not fit: {scene['id']}")
    for index, line in enumerate(body_lines):
        draw.text((left, subhead_y + index * px(45)), line, font=body_face, fill=rgb("#766F90"))
    return subhead_y + len(body_lines) * px(45) + px(70)


def add_surface_label(
    canvas: Image.Image,
    text: str,
    position: tuple[int, int],
    background: tuple[int, int, int],
    foreground: tuple[int, int, int],
) -> None:
    draw = ImageDraw.Draw(canvas)
    face = font(FONT_LABEL, 24)
    width = round(draw.textlength(text, font=face)) + 42
    box = (position[0], position[1], position[0] + width, position[1] + 52)
    draw.rounded_rectangle(box, radius=26, fill=background)
    draw_tracked(draw, (position[0] + 21, position[1] + 11), text, face, foreground, 1)


def compose_standard_iphone(
    canvas: Image.Image,
    source: Image.Image,
    scene: dict,
    header_bottom: int,
    foreground: tuple[int, int, int],
    background: tuple[int, int, int],
) -> None:
    # Map attribution belongs to the real UI; keep the entire map capture in frame.
    full_capture = scene["id"].endswith("-listening")
    cropped = source if full_capture else crop_normalized(source, scene.get("crop"))
    width = 900 if full_capture else 1100
    x = (canvas.width - width) // 2 if full_capture else (62 if scene.get("align") == "left" else 158)
    top = max(760, header_bottom + 22)
    place_panel(
        canvas,
        cropped,
        (x, top),
        width,
        radius=24,
        border=mix(foreground, background, 0.12),
        shadow=mix(foreground, background, 0.35),
    )


def cross_platform_raw(raw_iphone: Path, platform: str, name: str) -> Path:
    """Prefer the current run's capture of the other platform; fall back to the last
    published landing-page copy. Without the preference, a full run composes the iPhone
    continuity scene with insets that lag one generation behind."""
    candidate = raw_iphone.parent.parent / platform / name
    if candidate.exists():
        return candidate
    return ROOT / f"LandingPage/assets/screenshots/{platform}/raw/{name}"


def compose_continuity_iphone(
    canvas: Image.Image,
    source: Image.Image,
    raw: Path,
    scene: dict,
    header_bottom: int,
    foreground: tuple[int, int, int],
    background: tuple[int, int, int],
    accent: tuple[int, int, int],
) -> None:
    top = max(760, header_bottom + 18)
    phone = crop_normalized(source, scene.get("crop"))
    place_panel(
        canvas,
        phone,
        (58, top),
        790,
        radius=24,
        border=foreground,
        shadow=mix(foreground, background, 0.4),
    )
    add_surface_label(canvas, "iPHONE", (92, top + 45), foreground, background)

    mac = Image.open(cross_platform_raw(raw, "mac", "05-library.png")).convert("RGB")
    # Keep the artwork column and stop below the last row — the library window's lower half
    # is empty space that reads as a dead panel at inset size.
    mac = crop_normalized(mac, [0.115, 0.05, 0.885, 0.5])
    mac_y = top + 930
    place_panel(
        canvas,
        mac,
        (470, mac_y),
        790,
        radius=18,
        border=foreground,
        shadow=mix(foreground, background, 0.38),
        border_width=9,
    )
    add_surface_label(canvas, "MAC", (505, mac_y + 34), accent, foreground)

    watch = Image.open(cross_platform_raw(raw, "watch", "02-now-playing.png")).convert("RGB")
    watch_y = top + 1560
    place_panel(
        canvas,
        watch,
        (760, watch_y),
        420,
        radius=92,
        border=foreground,
        shadow=mix(foreground, background, 0.38),
        border_width=12,
    )
    add_surface_label(canvas, "APPLE WATCH", (730, watch_y - 70), foreground, background)


def compose_workout_iphone(
    canvas: Image.Image,
    source: Image.Image,
    raw: Path,
    scene: dict,
    header_bottom: int,
    foreground: tuple[int, int, int],
    background: tuple[int, int, int],
    accent: tuple[int, int, int],
) -> None:
    top = max(760, header_bottom + 18)
    phone = crop_normalized(source, scene.get("crop"))
    place_panel(
        canvas,
        phone,
        (72, top),
        1040,
        radius=24,
        border=foreground,
        shadow=mix(foreground, background, 0.4),
    )

    watch = Image.open(cross_platform_raw(raw, "watch", "01-workout.png")).convert("RGB")
    watch_y = top + 1150
    place_panel(
        canvas,
        watch,
        (720, watch_y),
        470,
        radius=100,
        border=foreground,
        shadow=mix(foreground, background, 0.35),
        border_width=13,
    )
    add_surface_label(canvas, "LIVE ON WATCH", (700, watch_y - 72), accent, foreground)


def compose_iphone(raw: Path, destination: Path, scene: dict, manifest: dict) -> None:
    size = tuple(manifest["capture"]["iphone_size"])
    colors = manifest["brand"]["colors"]
    background = rgb(colors[scene["background"]])
    foreground = rgb(colors[scene["foreground"]])
    accent = rgb(colors[scene["accent"]])
    scene_number = next(
        index + 1
        for index, item in enumerate(manifest["iphone_scenes"])
        if item["id"] == scene["id"]
    )

    canvas = draw_campaign_background(size, background, accent, foreground, scene_number)
    header_bottom = add_campaign_header(
        canvas,
        scene,
        foreground,
        accent,
        scene_number,
    )
    source = Image.open(raw).convert("RGB")

    if scene["mode"] == "continuity":
        compose_continuity_iphone(
            canvas, source, raw, scene, header_bottom, foreground, background, accent
        )
    elif scene["mode"] == "workout":
        compose_workout_iphone(
            canvas, source, raw, scene, header_bottom, foreground, background, accent
        )
    else:
        compose_standard_iphone(
            canvas, source, scene, header_bottom, foreground, background
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(destination, "PNG", optimize=True)


def compose_ipad(raw: Path, destination: Path, scene: dict, manifest: dict) -> None:
    """Landscape iPad UI beside the website's editorial copy, with the whole screen visible."""
    size = tuple(manifest["capture"]["ipad_size"])
    colors = manifest["brand"]["colors"]
    background = rgb(colors[scene["background"]])
    foreground = rgb(colors[scene["foreground"]])
    accent = rgb(colors[scene["accent"]])
    canvas = Image.new("RGBA", size, (*background, 255))
    draw = ImageDraw.Draw(canvas)
    draw.text((110, 110), "Banana", font=font(FONT_DISPLAY, 56), fill=foreground)
    draw.text((110, 198), scene["eyebrow"], font=font(FONT_LABEL, 26), fill=rgb("#766F90"))
    draw.line((110, 265, size[0] - 110, 265), fill=rgb("#E6DCCB"), width=3)
    draw.rounded_rectangle((850, 420, size[0] - 80, size[1] - 130), radius=22, fill=accent)
    lines = scene["headline"].splitlines()
    point_size = 104
    while max(draw.textlength(line, font=font(FONT_DISPLAY, point_size)) for line in lines) > 680:
        point_size -= 1
    for index, line in enumerate(lines):
        draw.text((110, 530 + index * round(point_size * 1.22)), line,
                  font=font(FONT_DISPLAY, point_size), fill=foreground)
    body_face = font(FONT_BODY, 34)
    for index, line in enumerate(wrapped_lines(draw, scene["subhead"], body_face, 640)):
        draw.text((110, 875 + index * 51), line, font=body_face, fill=rgb("#766F90"))
    source = crop_normalized(Image.open(raw).convert("RGB"), scene.get("crop"))
    if source.width <= source.height:
        raise ValueError(f"{raw}: capture the real landscape layout before composing iPad artwork")
    place_panel(
        canvas,
        source,
        (900, 500),
        1730,
        radius=18,
        border=foreground,
        shadow=mix(foreground, background, 0.35),
        border_width=10,
    )

    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(destination, "PNG", optimize=True)


def compose_mac(raw: Path, destination: Path, scene: dict, manifest: dict) -> None:
    size = tuple(manifest["capture"]["mac_size"])
    colors = manifest["brand"]["colors"]
    background = rgb(colors[scene["background"]])
    foreground = rgb(colors[scene["foreground"]])
    accent = rgb(colors[scene["accent"]])
    scene_number = next(
        index + 1
        for index, item in enumerate(manifest["mac_scenes"])
        if item["id"] == scene["id"]
    )

    canvas = Image.new("RGBA", size, (*background, 255))
    draw = ImageDraw.Draw(canvas)
    draw.text((120, 95), "Banana", font=font(FONT_DISPLAY, 56), fill=foreground)
    draw.text((120, 183), scene["eyebrow"], font=font(FONT_LABEL, 26), fill=rgb("#766F90"))
    draw.line((120, 250, size[0] - 120, 250), fill=rgb("#E6DCCB"), width=3)
    draw.rounded_rectangle((920, 310, 2780, 1700), radius=22, fill=accent)
    lines = scene["headline"].splitlines()
    point_size = 104
    while max(draw.textlength(line, font=font(FONT_DISPLAY, point_size)) for line in lines) > 750:
        point_size -= 1
    for index, line in enumerate(lines):
        draw.text((120, 410 + index * round(point_size * 1.22)), line,
                  font=font(FONT_DISPLAY, point_size), fill=foreground)
    body_face = font(FONT_BODY, 36)
    for index, line in enumerate(wrapped_lines(draw, scene["subhead"], body_face, 700)):
        draw.text((120, 740 + index * 53), line, font=body_face, fill=rgb("#766F90"))

    source = Image.open(raw).convert("RGB")
    place_panel(
        canvas,
        source,
        (980, 380),
        1770,
        radius=18,
        border=foreground,
        shadow=mix(foreground, background, 0.38),
        border_width=10,
    )

    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(destination, "PNG", optimize=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("manifest.json"),
    )
    parser.add_argument("--platform", choices=("iphone", "ipad", "mac"), required=True)
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scene", required=True)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    scenes = manifest[f"{args.platform}_scenes"]
    scene = next(item for item in scenes if item["id"] == args.scene)
    if args.platform == "iphone":
        compose_iphone(args.raw, args.output, scene, manifest)
    elif args.platform == "ipad":
        compose_ipad(args.raw, args.output, scene, manifest)
    else:
        compose_mac(args.raw, args.output, scene, manifest)


if __name__ == "__main__":
    main()
