#!/usr/bin/env python3
"""Validate generated App Store media and metadata before upload."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image


LIMITS = {
    "name.txt": 30,
    "subtitle.txt": 30,
    "promotional_text.txt": 170,
    "description.txt": 4000,
    "keywords.txt": 100,
}


def validate_images(directory: Path, expected: tuple[int, int], minimum: int, maximum: int) -> list[str]:
    errors: list[str] = []
    images = sorted(directory.glob("*.png"))
    if not minimum <= len(images) <= maximum:
        errors.append(f"{directory}: expected {minimum}–{maximum} PNGs, found {len(images)}")
    for path in images:
        with Image.open(path) as image:
            if image.size != expected:
                errors.append(f"{path}: expected {expected[0]}x{expected[1]}, found {image.width}x{image.height}")
            if image.mode != "RGB" or "transparency" in image.info:
                errors.append(f"{path}: expected RGB without alpha or transparency, found {image.mode}")
    return errors


def validate_metadata(directory: Path) -> list[str]:
    errors: list[str] = []
    for filename, limit in LIMITS.items():
        path = directory / filename
        if not path.exists():
            errors.append(f"{path}: missing")
            continue
        value = path.read_text().strip()
        count = len(value.encode("utf-8")) if filename == "keywords.txt" else len(value)
        if count > limit:
            errors.append(f"{path}: {count} exceeds limit {limit}")
        if "TODO" in value:
            errors.append(f"{path}: contains TODO")
    return errors


def validate_mac_raw_captures(directory: Path) -> list[str]:
    errors: list[str] = []
    for path in sorted(directory.glob("*.png")):
        with Image.open(path).convert("RGB") as image:
            sidebar = image.crop((0, round(image.height * 0.06), round(image.width * 0.22), image.height))
            pixels = list(sidebar.getdata())
            near_white = sum(1 for red, green, blue in pixels if red > 245 and green > 245 and blue > 245)
            if pixels and near_white / len(pixels) > 0.4:
                errors.append(f"{path}: likely blank white sidebar capture artifact")
    return errors


def checksums(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file() and path.name != "checksums.json"
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("manifest.json"))
    parser.add_argument("--platform", choices=("all", "iphone", "ipad", "watch", "mac"), default="all")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    errors = []
    platforms = ("iphone", "ipad", "watch", "mac") if args.platform == "all" else (args.platform,)
    if "iphone" in platforms:
        errors += validate_images(args.output / "screenshots/iphone-6.9", tuple(manifest["capture"]["iphone_size"]), 1, 10)
    if "ipad" in platforms:
        errors += validate_images(args.output / "screenshots/ipad-13", tuple(manifest["capture"]["ipad_size"]), 1, 10)
    if "watch" in platforms:
        errors += validate_images(args.output / "screenshots/watch", tuple(manifest["capture"]["watch_size"]), 1, 10)
    if "mac" in platforms:
        errors += validate_images(args.output / "screenshots/mac", tuple(manifest["capture"]["mac_size"]), 1, 10)
        errors += validate_mac_raw_captures(args.output / "raw/mac")
    creative = args.output / "creative/en-US"
    if creative.exists():
        for kind, size in (("header", (3840, 1646)), ("search", (1920, 1280))):
            path = creative / f"{kind}-{size[0]}x{size[1]}.png"
            if not path.exists():
                errors.append(f"{path}: missing")
                continue
            with Image.open(path) as image:
                if image.size != size or image.mode != "RGB" or "transparency" in image.info:
                    errors.append(f"{path}: expected {size} opaque RGB")
    errors += validate_metadata(args.output / "metadata/en-US")
    (args.output / "checksums.json").write_text(json.dumps(checksums(args.output), indent=2) + "\n")
    if errors:
        print("\n".join(f"ERROR: {error}" for error in errors))
        raise SystemExit(1)
    print(f"Validated {args.output}")


if __name__ == "__main__":
    main()
