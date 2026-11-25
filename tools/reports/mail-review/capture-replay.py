#!/usr/bin/env python3
"""Capture paired email-body screenshots from a local archive replay viewer."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.request import urlopen
from uuid import uuid4

from serve import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True, help="Case ID from the viewer’s /api/archive")
    parser.add_argument("--out", required=True, type=Path, help="New directory under private/")
    parser.add_argument("--port", type=int, default=8769)
    parser.add_argument("--left", choices=("reported", "before"), default="reported")
    parser.add_argument("--width", action="append", type=int, help="Viewport width in pixels. Repeat to compare widths.")
    parser.add_argument("--section", help="Exact visible heading shared by both versions. Without it, capture the full body.")
    parser.add_argument("--browser-bin", default="agent-browser")
    args = parser.parse_args()
    out = args.out.resolve()
    if not out.is_relative_to((ROOT / "private").resolve()):
        parser.error("Keep archive screenshots under private/.")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", args.case):
        parser.error("Invalid case ID.")
    widths = args.width or [320, 393, 586]
    if any(width <= 0 for width in widths) or len(set(widths)) != len(widths):
        parser.error("Use distinct positive viewport widths.")

    origin = f"http://127.0.0.1:{args.port}"
    with urlopen(f"{origin}/api/archive", timeout=5) as response:
        replay = json.load(response)
    case = next((case for case in replay["cases"] if case["id"] == args.case), None)
    if case is None or (args.left == "reported" and not replay["hasReported"]):
        parser.error("This viewer does not have the requested comparison.")
    out.mkdir(mode=0o700, parents=True)
    session = "mail-replay-" + uuid4().hex[:12]

    def browser(*command):
        return subprocess.run(
            [args.browser_bin, "--session", session, *command], check=True,
            capture_output=True, text=True, timeout=35,
        ).stdout.strip()

    try:
        for width in widths:
            browser("set", "viewport", str(width), "776")
            for side in (args.left, "after"):
                browser("open", f"{origin}/body/{args.case}/{side}")
                if args.section:
                    heading = browser("eval", f"""(() => {{
                        const normalize = text => text.trim().replace(/\\s+/g, ' ');
                        const wanted = normalize({json.dumps(args.section)});
                        const node = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6,p')]
                            .find(el => el.getClientRects().length && normalize(el.textContent) === wanted);
                        if (node) node.scrollIntoView();
                        return Boolean(node);
                    }})()""")
                    if heading != "true":
                        raise SystemExit(f"{side} is missing the requested visible heading.")
                path = out / f"{side}-{width}.png"
                options = () if args.section else ("--full",)
                browser("screenshot", *options, str(path))
                print(path)
    finally:
        subprocess.run([args.browser_bin, "--session", session, "close"], capture_output=True, timeout=10)


if __name__ == "__main__":
    main()
