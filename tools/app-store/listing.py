"""Which listing a store tool works on: the full app's, or a flavour's (flavours/<name>.json).

A flavour names its metadata folder, its generated package and the platforms it has scenes for,
as generate.py --flavour reads them. upload-assets.py and update-draft.py take the same
--flavour, so the text, the images and the placements they replace are always one listing's.
"""
from __future__ import annotations

import json
from pathlib import Path

TOOL = Path(__file__).resolve().parent
ROOT = TOOL.parents[1]
FLAVOURS = TOOL / "flavours"
ALL_PLATFORMS = ("iphone", "ipad", "watch", "mac")


def names() -> list[str]:
    return sorted(p.stem for p in FLAVOURS.glob("*.json"))


def load(flavour: str | None) -> dict:
    """name, metadata folder, package folder and the platforms with a screenshot set."""
    if not flavour:
        return {"name": "full", "metadata": TOOL / "metadata/en-US",
                "package": ROOT / "AppStore/Generated", "platforms": list(ALL_PLATFORMS)}
    path = FLAVOURS / f"{flavour}.json"
    if not path.exists():
        raise SystemExit(f"No flavour {flavour}: {path} is missing")
    spec = json.loads(path.read_text())
    return {"name": flavour,
            "metadata": TOOL / spec.get("metadata", "metadata/en-US"),
            "package": ROOT / spec.get("output", "AppStore/Generated"),
            "platforms": [p for p in ALL_PLATFORMS if spec.get(f"{p}_scenes")]}
