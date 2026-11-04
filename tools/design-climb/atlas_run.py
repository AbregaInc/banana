#!/usr/bin/env python3 -I
"""Turn a screen-atlas capture into a design-climb run the judges can read.

  atlas_run.py design-climb/atlas/a0 a0      # → design-climb/runs/a0/<device>-<area>__<name>.png + states.json

Each picture is named by its atlas id; states.json carries the atlas title and the route that
opened it, so a judge knows what the screen is meant to show.
"""
import json, pathlib, shutil, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
src, name = pathlib.Path(sys.argv[1]), sys.argv[2]
out = ROOT / "design-climb/runs" / name
out.mkdir(parents=True, exist_ok=True)
manifest = json.loads((ROOT / "tools/atlas/screens.json").read_text())
titles = {s["id"]: s for s in manifest["screens"]}
states = {}
for device_dir in sorted(p for p in src.iterdir() if p.is_dir()):
    for pic in sorted(device_dir.rglob("*.png")):
        atlas_id = pic.relative_to(device_dir).with_suffix("").as_posix()
        area, rest = atlas_id.split("/", 1)
        state = f"{area}__{rest.replace('/', '-')}"
        shutil.copyfile(pic, out / f"{device_dir.name}-{state}.png")
        screen = titles.get(atlas_id, {})
        to = [t[0] if isinstance(t, list) else t for t in screen.get("to", [])]
        states[state] = (screen.get("title") or atlas_id) + (f" (leads to: {', '.join(map(str, to))})" if to else "")
(out / "states.json").write_text(json.dumps({"about": f"Screen atlas {src.name}", "states": states}, indent=2, ensure_ascii=False) + "\n")
print(out, len(states), "states")
