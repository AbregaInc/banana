#!/usr/bin/env python3
"""The screen atlas as a design canvas and as a folder.

    board.py images             # downscaled copies for the canvas: design-atlas/board-images/
    board.py canvas ROOT        # ROOT/project/canvas.json + one artboard per area (needs design-atlas/assets.json)
    board.py docs               # design-atlas/README.md and FLOWS.md

Each area is one artboard: the area's first screen on the left, what it opens in the next
column, and so on (breadth first over the area's own arrows), each arrow labelled with the tap.
An arrow to another area, or back, is written under the screen instead of drawn. Screens no
arrow reaches are states of the same pages, laid out in a grid below the flow.
"""
import html, json, sys
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
TOOL = Path(__file__).resolve().parent
ROOT = TOOL.parents[1]
ATLAS = ROOT / "design-atlas"
SHOTS = ATLAS / "screens"
IMAGES = ATLAS / "board-images"

# Shown size on the canvas (CSS px) and the uploaded image's width (2x).
SIZE = {"phone": (260, 565), "pad": (420, 560), "mac": (660, 420), "watch": (208, 248)}
AREA_DEVICE = {"ipad": "pad", "mac": "mac", "watch": "watch"}

INK, MUTED, LINE, PAPER, CARD = "#1d1d1f", "#5f6168", "#9a9ca3", "#f4f4f6", "#ffffff"
FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif"
GAP, M = 230, 64


def esc(text: str) -> str:
    return html.escape(text, quote=True)


def manifest() -> dict:
    return json.loads((TOOL / "screens.json").read_text())


def device_of(screen: dict) -> str:
    return AREA_DEVICE.get(screen["area"], "phone")


def shot_path(screen: dict) -> Path:
    area, name = screen["id"].split("/", 1)
    return SHOTS / device_of(screen) / area / f"{name}.png"


def present(m: dict) -> list:
    return [s for s in m["screens"] if shot_path(s).exists()]


# MARK: - images

def images() -> None:
    from PIL import Image
    for s in present(manifest()):
        w, _ = SIZE[device_of(s)]
        src = shot_path(s)
        dst = IMAGES / src.relative_to(SHOTS)
        dst.parent.mkdir(parents=True, exist_ok=True)
        im = Image.open(src).convert("RGB")
        im = im.resize((w * 2, round(im.height * w * 2 / im.width)), Image.LANCZOS)
        im.save(dst, optimize=True)
    print(IMAGES)


# MARK: - layout

def layout(area: dict, screens: list) -> tuple[dict, list]:
    """Column and row for each screen reached from the first; the rest are states."""
    ids = [s["id"] for s in screens]
    edges = {s["id"]: [t for t, _ in s.get("to", []) if t in ids] for s in screens}
    depth, order = {ids[0]: 0}, deque([ids[0]])
    while order:
        here = order.popleft()
        for t in edges[here]:
            if t not in depth:
                depth[t] = depth[here] + 1
                order.append(t)
    columns: dict[int, list] = {}
    for i in ids:  # manifest order within a column
        if i in depth:
            columns.setdefault(depth[i], []).append(i)
    place = {i: (c, r) for c, col in columns.items() for r, i in enumerate(col)}
    states = [i for i in ids if i not in depth]
    return place, states


def arrow(n: int, x: float, y: float, length: float, direction: str, head: bool) -> str:
    """One straight segment in the canvas's arrow shape (diagrams.md)."""
    h = 4 if head else 0
    length = round(length)
    if direction in ("right", "left"):
        box = f"left: {round(x)}px; top: {round(y) - 4}px; width: {length}px; height: 8px"
        size = f'width="{length}" height="8" viewBox="0 0 {length} 8"'
        d = f"M 0 4 L {length - h} 4" if direction == "right" else f"M {length} 4 L {h} 4"
    else:
        box = f"left: {round(x) - 4}px; top: {round(y)}px; width: 8px; height: {length}px"
        size = f'width="8" height="{length}" viewBox="0 0 8 {length}"'
        d = f"M 4 0 L 4 {length - h}" if direction == "down" else f"M 4 {length} L 4 {h}"
    defs = marker = ""
    if head:
        defs = (f'<defs><marker id="dc-arrow-head-filled-{n}" orient="auto" markerWidth="5" markerHeight="5" refX="2" refY="2" overflow="visible">'
                f'<path d="M0 0 L4 2 L0 4 Z" fill="{LINE}" stroke="none" style="stroke: none; fill: {LINE}; fill: context-stroke"/></marker></defs>')
        marker = f' marker-end="url(#dc-arrow-head-filled-{n})"'
    return (f'<svg {size} preserveAspectRatio="none" style="position: absolute; {box}; overflow: visible; fill: none; '
            f'stroke: {LINE}; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round">{defs}<path d="{d}"{marker}></path></svg>')


def page(title: str, width: int, height: int, body: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{esc(title)}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<style>
body{{margin:0}}
a{{color:#0a66d8}}a:hover{{color:#084fa8}}
</style>
</helmet>
<div style="position: relative; width: {width}px; height: {height}px; background: {PAPER}; color: {INK}; font-family: {FONT}">
{body}
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":{width},"height":{height}}}}}'>
class Component extends DCLogic {{
renderVals() {{
return {{}};
}}
}}
</script>
</body>
</html>
"""


def text_lines(text: str, chars: int) -> int:
    lines, length = 1, 0
    for word in text.split():
        if length and length + 1 + len(word) > chars:
            lines, length = lines + 1, len(word)
        else:
            length += (1 if length else 0) + len(word)
    return lines


def area_board(m: dict, area: dict, screens: list, assets: dict) -> tuple[str, int, int]:
    by_id = {s["id"]: s for s in present(m)}
    areas = {a["id"]: a["title"] for a in m["areas"]}
    device = AREA_DEVICE.get(area["id"], "phone")
    cw, ih = SIZE[device]
    place, states = layout(area, screens)

    def caption(s: dict, drawn: set) -> list[str]:
        out = []
        for t, label in s.get("to", []):
            if t in drawn or t not in by_id:
                continue
            target = by_id[t]
            where = target["title"] if target["area"] == s["area"] else f"{areas[target['area']]} › {target['title']}"
            out.append(f"{label} → {where}")
        if s.get("note"):
            out.append(s["note"])
        return out

    # Which arrows are drawn: into the next column only.
    drawn: dict[str, set] = {}
    for s in screens:
        if s["id"] not in place:
            continue
        c, _ = place[s["id"]]
        drawn[s["id"]] = {t for t, _ in s.get("to", []) if t in place and place[t][0] == c + 1}
    captions = {s["id"]: caption(s, drawn.get(s["id"], set())) for s in screens}
    cap_lines = {i: sum(text_lines(line, cw // 7) for line in lines) for i, lines in captions.items()}

    # Levels run down the board (the first screen at the top), siblings side by side.
    nlevels = max((c for c, _ in place.values()), default=0) + 1
    per_level = {lv: max(r for c, r in place.values() if c == lv) + 1 for lv in range(nlevels)}
    HG, VG = 80, 170
    summary_lines = text_lines(area["summary"], 110)
    flow_top = M + 56 + summary_lines * 28 + 56
    level_cap = {lv: max(cap_lines[i] for i in place if place[i][0] == lv) for lv in range(nlevels)}
    level_y, y = {}, flow_top
    for lv in range(nlevels):
        level_y[lv] = y
        y += 30 + ih + 12 + level_cap[lv] * 18 + 18 + VG

    parts, n = [], 0
    parts.append(f'<div style="position: absolute; left: {M}px; top: {M}px; font-size: 40px; line-height: 48px; font-weight: 700; letter-spacing: -0.5px">{esc(area["title"])}</div>')
    parts.append(f'<div style="position: absolute; left: {M}px; top: {M + 60}px; width: 980px; font-size: 18px; line-height: 28px; color: {MUTED}">{esc(area["summary"])}</div>')

    # A plain chain (one screen a level) reads better left to right.
    chain = nlevels > 2 and max(per_level.values()) == 1
    if chain:
        row_y = flow_top
        level_y = {lv: row_y for lv in range(nlevels)}
        y = row_y + 30 + ih + 12 + max(level_cap.values()) * 18 + 18 + VG

    def x_of(lv: int, k: int) -> int:
        return M + (lv * (cw + 150) if chain else k * (cw + HG))

    def bottom_of(lv: int) -> int:
        return level_y[lv] + 30 + ih + 12 + level_cap[lv] * 18 + 18

    # Arrows first (paint order), then the screens.
    for s in screens:
        if s["id"] not in place:
            continue
        lv, k = place[s["id"]]
        sx, sy = x_of(lv, k) + cw // 2, bottom_of(lv)
        targets = [(t, label) for t, label in s.get("to", []) if t in drawn[s["id"]]]
        if not targets:
            continue
        if chain:
            for t, label in targets:
                tx, ay = x_of(place[t][0], 0) - 1, level_y[lv] + 30 + ih // 2
                n += 1
                parts.append(arrow(n, x_of(lv, 0) + cw, ay, tx - x_of(lv, 0) - cw, "right", True))
                parts.append(f'<div style="position: absolute; left: {x_of(lv, 0) + cw + 11}px; top: {ay - 12 - 16 * text_lines(label, 16)}px; '
                             f'width: 128px; text-align: center; font-size: 13px; line-height: 16px; color: {MUTED}">{esc(label)}</div>')
            continue
        mid = sy + 28 + 12 * k
        n += 1
        parts.append(arrow(n, sx, sy, mid - sy, "down", False))
        txs = [x_of(*place[t]) + cw // 2 for t, _ in targets]
        left, right = min(txs + [sx]), max(txs + [sx])
        if right > left:
            n += 1
            parts.append(arrow(n, left, mid, right - left, "right", False))
        for (t, label), tx in zip(targets, txs):
            ty = level_y[place[t][0]] - 1
            n += 1
            parts.append(arrow(n, tx, mid, ty - mid, "down", True))
            lines = text_lines(label, 16)
            parts.append(f'<div style="position: absolute; left: {tx + 10}px; top: {ty - 8 - 16 * lines}px; width: 128px; '
                         f'font-size: 13px; line-height: 16px; color: {MUTED}">{esc(label)}</div>')

    def screen(s: dict, x: int, y: int) -> None:
        key = shot_path(s).relative_to(SHOTS).as_posix()
        parts.append(f'<div style="position: absolute; left: {x}px; top: {y}px; width: {cw}px; font-size: 15px; line-height: 20px; font-weight: 600">{esc(s["title"])}</div>')
        if key in assets:
            parts.append(f'<img src="{assets[key]}" alt="{esc(s["title"])}" style="position: absolute; left: {x}px; top: {y + 30}px; width: {cw}px; height: {ih}px; '
                         f'object-fit: contain; object-position: top; border-radius: {14 if device != "mac" else 8}px; box-shadow: 0 1px 2px rgba(0,0,0,0.08), 0 8px 24px rgba(0,0,0,0.10); background: {CARD}">')
        else:
            parts.append(f'<div style="position: absolute; left: {x}px; top: {y + 30}px; width: {cw}px; height: {ih}px; box-sizing: border-box; border: 1px dashed {LINE}; '
                         f'border-radius: 14px; display: flex; align-items: center; justify-content: center; color: {MUTED}; font-size: 13px">[NOT CAPTURED]</div>')
        lines = captions[s["id"]]
        if lines:
            body = "<br>".join(esc(line) for line in lines)
            parts.append(f'<div style="position: absolute; left: {x}px; top: {y + 30 + ih + 12}px; width: {cw}px; font-size: 13px; line-height: 18px; color: {MUTED}">{body}</div>')
        parts.append(f'<div style="position: absolute; left: {x}px; top: {y + 30 + ih + 12 + 18 * cap_lines[s["id"]] + 4}px; width: {cw}px; '
                     f'font-size: 11px; line-height: 14px; color: {LINE}; font-family: ui-monospace, Menlo, monospace">{esc(key)}</div>')

    for s in screens:
        if s["id"] in place:
            lv, k = place[s["id"]]
            screen(s, x_of(lv, k), level_y[lv])

    height = y - VG + 40
    widest = max(per_level.values())
    width = max(M * 2 + widest * cw + (widest - 1) * HG, 1180)
    if chain:
        width = max(width, M * 2 + nlevels * cw + (nlevels - 1) * 150)
    if states:
        per = max(4, min(len(states), (max(width, 1400) - 2 * M + 80) // (cw + 80)))
        state_cap = max(cap_lines[i] for i in states)
        state_h = 30 + ih + 12 + state_cap * 18 + 64
        top = height + 24
        parts.append(f'<div style="position: absolute; left: {M}px; top: {top}px; font-size: 24px; line-height: 32px; font-weight: 700">Other states</div>')
        parts.append(f'<div style="position: absolute; left: {M}px; top: {top + 36}px; width: 900px; font-size: 15px; line-height: 22px; color: {MUTED}">'
                     f'The same pages with other data, or a step reached another way.</div>')
        top += 36 + 22 + 40
        for k, i in enumerate(states):
            screen(next(s for s in screens if s["id"] == i), M + (k % per) * (cw + 80), top + (k // per) * state_h)
        height = top + ((len(states) + per - 1) // per) * state_h
        width = max(width, M * 2 + per * cw + (per - 1) * 80)
    return page(area["title"], width, height + M, "\n".join(parts)), width, height + M


def main_board(m: dict, counts: dict) -> tuple[str, int, int]:
    W, H = 1400, 1180
    p = []
    p.append(f'<div style="position: absolute; left: {M}px; top: {M}px; font-size: 56px; line-height: 64px; font-weight: 700; letter-spacing: -1px">Banana, screen by screen</div>')
    p.append(f'<div style="position: absolute; left: {M}px; top: {M + 84}px; width: 1000px; font-size: 20px; line-height: 30px; color: {MUTED}">'
             "Every page and state of the app as built, on iPhone, iPad, Mac and Apple Watch, with the taps that lead from one to the next. "
             "Made so a designer can see the whole of it before cleaning it up. Each area below is one board: read it left to right.</div>")
    # How the app is held together: the shell.
    y0 = 300
    p.append(f'<div style="position: absolute; left: {M}px; top: {y0}px; font-size: 24px; line-height: 32px; font-weight: 700">How it fits together (iPhone)</div>')
    tabs = [("Plan", "Day and week of the calendar"), ("Body", "Workouts · Food · Taken"), ("Notes", "Voice and written"),
            ("Library", "Podcasts and the player"), ("+", "Add anything, this tab's first")]
    bar_y, card_y, cw, ch = y0 + 72, y0 + 200, 216, 88
    p.append(f'<div style="position: absolute; left: {M}px; top: {bar_y}px; width: 1272px; height: 64px; box-sizing: border-box; display: flex; align-items: center; '
             f'justify-content: center; background: {INK}; color: #ffffff; border-radius: 32px; font-size: 17px; font-weight: 600">The tab bar, at the bottom of every page</div>')
    xs = [M + 12 + k * (cw + 48) for k in range(5)]
    for k, (x, (name, sub)) in enumerate(zip(xs, tabs)):
        p.append(arrow(100 + k, x + cw // 2, bar_y + 64, card_y - (bar_y + 64) - 1, "down", True))
    for x, (name, sub) in zip(xs, tabs):
        p.append(f'<div style="position: absolute; left: {x}px; top: {card_y}px; width: {cw}px; height: {ch}px; box-sizing: border-box; padding: 12px; display: flex; '
                 f'align-items: center; justify-content: center; text-align: center; background: {CARD}; border: 1px solid #d9dade; border-radius: 14px; font-size: 15px; line-height: 21px">'
                 f'<span><b>{esc(name)}</b><br>{esc(sub)}</span></div>')
    y1 = card_y + ch + 72
    p.append(f'<div style="position: absolute; left: {M}px; top: {y1}px; width: 1272px; height: 64px; box-sizing: border-box; display: flex; align-items: center; '
             f'justify-content: center; background: #e6e7eb; border-radius: 32px; font-size: 17px; font-weight: 600">The top bar of every tab: chart button · the page\'s switch · "…"</div>')
    tops = [("Review", "Chart button, top left"), ("Routines", "… › Routines"), ("Settings", "… › Settings"), ("Set up", "… › Finish setup")]
    ty = y1 + 64 + 120
    xs2 = [M + 12 + k * (cw + 48) for k in range(4)]
    for k, x in enumerate(xs2):
        p.append(arrow(110 + k, x + cw // 2, y1 + 64, ty - (y1 + 64) - 1, "down", True))
        name, sub = tops[k]
        p.append(f'<div style="position: absolute; left: {x}px; top: {ty}px; width: {cw}px; height: {ch}px; box-sizing: border-box; padding: 12px; display: flex; '
                 f'align-items: center; justify-content: center; text-align: center; background: {CARD}; border: 1px solid #d9dade; border-radius: 14px; font-size: 15px; line-height: 21px">'
                 f'<span><b>{esc(name)}</b><br>{esc(sub)}</span></div>')
    # Reading notes.
    ny = ty + ch + 72
    notes = [
        f"{sum(counts.values())} screens: iPhone {counts.get('phone', 0)}, iPad {counts.get('pad', 0)}, Mac {counts.get('mac', 0)}, Watch {counts.get('watch', 0)}.",
        "Sample data throughout (the made-up Sam and their week); no real account. Captured 14 Oct 2026 from commit d1d7abf.",
        "The Simulator has no camera, Apple Weather or Health: those screens show their stand-ins.",
        "The Mac set is in dark mode, as the Mac it was captured on is set; the rest are light.",
        "Under each screen: taps that lead to another area, then its file in the screens folder.",
    ]
    p.append(f'<div style="position: absolute; left: {M}px; top: {ny}px; font-size: 24px; line-height: 32px; font-weight: 700">Reading the boards</div>')
    p.append(f'<div style="position: absolute; left: {M}px; top: {ny + 44}px; width: 1100px; font-size: 17px; line-height: 28px; color: {MUTED}">'
             + "<br>".join(esc(x) for x in notes) + "</div>")
    return page("Banana, screen by screen", W, H, "\n".join(p)), W, H


def canvas(root: Path) -> None:
    m = manifest()
    assets = json.loads((ATLAS / "assets.json").read_text())
    shots = present(m)
    counts: dict[str, int] = {}
    for s in shots:
        counts[device_of(s)] = counts.get(device_of(s), 0) + 1
    project = root / "project"
    project.mkdir(parents=True, exist_ok=True)
    boards, order = {}, []
    body, w, h = main_board(m, counts)
    (project / "Main.dc.html").write_text(body)
    boards["Main.dc.html"] = {"x": 0, "y": 0, "w": w, "h": h, "title": "Banana, screen by screen"}
    order.append("Main.dc.html")
    y = h + 120
    for area in m["areas"]:
        screens = [s for s in shots if s["area"] == area["id"]]
        if not screens:
            continue
        body, w, h = area_board(m, area, screens, assets)
        name = f"{area['id']}.dc.html"
        (project / name).write_text(body)
        boards[name] = {"x": 0, "y": y, "w": w, "h": h, "title": area["title"]}
        order.append(name)
        y += h + 120
    index = {"v": 3, "createdOnFiles": {"v": 1, "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
             "title": "Banana Screen Atlas", "launch": {"view": "canvas"}, "pages": [], "boards": boards,
             "order": order, "notes": {}, "designSystems": []}
    (project / "canvas.json").write_text(json.dumps(index, indent=1))
    print("\n".join(order))


def docs() -> None:
    m = manifest()
    shots = {s["id"] for s in present(m)}
    by_id = {s["id"]: s for s in present(m)}
    areas = {a["id"]: a["title"] for a in m["areas"]}
    out = ["# Banana, screen by screen", "",
           "Every page and state of Banana as built, captured on sample data on 14 Oct 2026 (commit d1d7abf), "
           "with the taps that lead from one to the next. `screens/<device>/<area>/<name>.png` holds the full-size pictures; "
           "the design canvas lays them out as flows.", "",
           "Regenerate: `tools/atlas/capture.py phone|pad|watch|mac`, the walk test "
           "(`TEST_RUNNER_ATLAS_SHOTS=$PWD/design-atlas/screens/phone tools/ui-tests.sh phone ScreenAtlasUITest`), "
           "then `tools/atlas/board.py docs`.", ""]
    for area in m["areas"]:
        screens = [s for s in m["screens"] if s["area"] == area["id"] and s["id"] in shots]
        if not screens:
            continue
        out += [f"## {area['title']}", "", area["summary"], ""]
        flow = [(s, t, label) for s in screens for t, label in s.get("to", []) if t in by_id]
        if flow:
            out += ["```mermaid", "flowchart LR"]
            names = {}
            for s, t, _ in flow:
                for i in (s["id"], t):
                    if i not in names:
                        names[i] = f"n{len(names)}"
                        title = by_id[i]["title"] if by_id[i]["area"] == area["id"] else f"{areas[by_id[i]['area']]}: {by_id[i]['title']}"
                        out.append(f'  {names[i]}["{title.replace(chr(34), "")}"]')
            for s, t, label in flow:
                out.append(f'  {names[s["id"]]} -- "{label.replace(chr(34), "")}" --> {names[t]}')
            out += ["```", ""]
        for s in screens:
            path = shot_path(s).relative_to(ATLAS).as_posix()
            leads = "; ".join(f"{label} → {by_id[t]['title']}" for t, label in s.get("to", []) if t in by_id)
            out.append(f"- **{s['title']}** — `{path}`" + (f". {leads}" if leads else "") + (f" ({s['note']})" if s.get("note") else ""))
        out.append("")
    (ATLAS / "FLOWS.md").write_text("\n".join(out))
    print(ATLAS / "FLOWS.md")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "images":
        images()
    elif command == "canvas":
        canvas(Path(sys.argv[2]))
    elif command == "docs":
        docs()
    else:
        print(__doc__)
