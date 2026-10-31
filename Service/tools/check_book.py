#!/usr/bin/env python3
"""The booking pages' budgets, checked before a deploy (docs/design/BOOKING.md §12, "How the speed
is reached").

    python3 Service/tools/check_book.py [folder]

Renders every sample page with tools/booking-preview.mjs into a temporary folder (or reads the
folder named, as that tool wrote it) and fails (exit 1) when a page:
  - weighs more than 12 KB gzipped in markup and data (the inline script and CSS left out), or its
    inline script more than 10 KB (8 until the 20 Oct review added the month grid and zone search), or its CSS more than 6 KB;
  - makes more than 4 requests as it loads: the document, the fonts it preloads, Turnstile;
  - has an image, or the logo isn't inline SVG;
  - loads anything from outside the site other than Turnstile, or a script runs without the nonce;
  - lacks a security header;
  - says ", never" (the copy rule: no "X, never Y" tails).
The fonts together must stay under 50 KB. Sizes are in thousands of bytes, as check_site.py counts.
"""
from __future__ import annotations

import gzip
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True

SERVICE = Path(__file__).resolve().parent.parent
FONTS = SERVICE / "public" / "book" / "fonts"
HTML_BUDGET, JS_BUDGET, CSS_BUDGET, FONT_BUDGET, REQUESTS = 12_000, 10_000, 6_000, 50_000, 4
TURNSTILE = "https://challenges.cloudflare.com"
HEADERS = {"content-security-policy", "referrer-policy", "x-content-type-options", "x-frame-options"}


def gz(text: str) -> int:
    return len(gzip.compress(text.encode("utf-8"), 9))


def check(folder: Path) -> list[str]:
    faults: list[str] = []
    names = json.loads((folder / "index.json").read_text())
    fonts = sum(f.stat().st_size for f in FONTS.glob("*.woff2"))
    print(f"fonts {fonts / 1000:.1f} KB (budget {FONT_BUDGET // 1000})")
    if fonts > FONT_BUDGET:
        faults.append(f"the fonts weigh {fonts / 1000:.1f} KB")
    widest = {"html": 0, "js": 0, "css": 0, "requests": 0}
    for name in names:
        html = (folder / f"{name}.html").read_text(encoding="utf-8")
        meta = json.loads((folder / f"{name}.headers.json").read_text())
        headers = {k.lower(): v for k, v in meta["headers"].items()}
        csp = headers.get("content-security-policy", "")
        nonce = re.search(r"'nonce-([^']+)'", csp)
        for h in HEADERS - set(headers):
            faults.append(f"{name}: no {h} header")
        if "frame-ancestors 'none'" not in csp or headers.get("referrer-policy") != "no-referrer":
            faults.append(f"{name}: the CSP or referrer policy is loose")
        for outside in re.findall(r"https?://[^\s;']+", csp):
            if outside != TURNSTILE:
                faults.append(f"{name}: the CSP lets in {outside}")

        scripts = re.findall(r"<script\b([^>]*)>([\s\S]*?)</script>", html)
        code = [body for attrs, body in scripts if "application/json" not in attrs]
        for attrs, body in scripts:
            if "application/json" not in attrs and (not nonce or f'nonce="{nonce.group(1)}"' not in attrs):
                faults.append(f"{name}: a script runs without the response's nonce")
            if "src=" in attrs:
                faults.append(f"{name}: a script is loaded from a file")
        styles = re.findall(r"<style>([\s\S]*?)</style>", html)
        markup = re.sub(r"<script nonce[^>]*>[\s\S]*?</script>|<style>[\s\S]*?</style>", "", html)
        sizes = {"html": gz(markup), "js": max([gz(c) for c in code] or [0]), "css": gz("".join(styles))}
        loads = [u for u in re.findall(r"<(?:link|script|img|iframe|source)\b[^>]*\b(?:src|href)=\"([^\"]+)\"", html) if not u.startswith("data:")]
        fetched = re.findall(r'<link\b[^>]*rel="(?:preload|stylesheet|modulepreload)"[^>]*>|<(?:script|img|iframe)\b[^>]*\bsrc=', html)
        requests = 1 + len(fetched) + (1 if re.search(r'"ts":"[^"]+"', html) else 0)   # the document, its fetches, Turnstile
        for key, value in (("requests", requests), *sizes.items()):
            widest[key] = max(widest[key], value)
        for key, budget in (("html", HTML_BUDGET), ("js", JS_BUDGET), ("css", CSS_BUDGET)):
            if sizes[key] > budget:
                faults.append(f"{name}: {key} {sizes[key] / 1000:.1f} KB (budget {budget // 1000})")
        if requests > REQUESTS:
            faults.append(f"{name}: {requests} requests at load")
        for u in loads:
            if not u.startswith("/"):
                faults.append(f"{name}: loads {u} from outside the site")
        if "<img" in html:
            faults.append(f"{name}: has an image")
        if not re.search(r'<a class="brand"[^>]*><svg viewBox', html):
            faults.append(f"{name}: the logo isn't inline SVG")
        text = re.sub(r"<[^>]+>", " ", markup)
        if re.search(r",\s*never\b", text, re.I):
            faults.append(f"{name}: says “, never”")
    print("widest page: " + ", ".join(f"{k} {v / 1000:.1f} KB" if k != "requests" else f"{v} requests" for k, v in widest.items()))
    return faults


if __name__ == "__main__":
    if len(sys.argv) > 1:
        folder = Path(sys.argv[1]).resolve()
    else:
        folder = Path(tempfile.mkdtemp(prefix="check-book-"))
        subprocess.run(["node", str(SERVICE / "tools" / "booking-preview.mjs"), "--out", str(folder)], check=True, stdout=subprocess.DEVNULL)
    faults = check(folder)
    for fault in faults:
        print("FAULT  " + fault)
    print("booking check: " + (f"{len(faults)} fault(s)" if faults else "passed"))
    sys.exit(1 if faults else 0)
