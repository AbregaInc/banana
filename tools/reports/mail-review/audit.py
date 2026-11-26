#!/usr/bin/env python3
"""Check text-first previews of sanitized MailOriginalDocument exports."""
import argparse
import json
import re
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path
from urllib.parse import urlencode
from uuid import uuid4

from serve import ReviewServer, WIDTHS

AUDIT = r"""
(async () => {
  const preview = document.querySelector('.candidate iframe');
  const source = document.createElement('iframe');
  source.setAttribute('sandbox', 'allow-same-origin');
  source.style.position = 'absolute';
  source.style.left = '-10000px';
  source.style.width = preview.clientWidth + 'px';
  source.style.height = preview.clientHeight + 'px';

  // Walk the same visibility boundary as the projection. An ancestor may be hidden even
  // when a descendant reports its own nonzero rectangle or its own opacity of 1.
  function visible(node) {
    if (!node.getClientRects().length) return false;
    for (let el = node; el; el = el.parentElement) {
      const style = el.ownerDocument.defaultView.getComputedStyle(el);
      if (style.visibility !== 'visible' || style.opacity === '0'
          || el.getAttribute('aria-hidden') === 'true') return false;
    }
    return true;
  }

  const links = doc => [...doc.querySelectorAll('a[href]')].filter(visible);
  const destinations = nodes => new Set(nodes.map(link => link.getAttribute('href')));
  const difference = (a, b) => [...a].filter(key => !b.has(key)).length;
  const numbers = doc => new Set((doc.body.innerText.match(/\p{Nd}+/gu) || []));
  const dataTables = doc => [...doc.querySelectorAll('table')].filter(table =>
    visible(table) && table.getAttribute('role') !== 'presentation' &&
    (table.caption || table.tHead || [...table.rows].some(row =>
      [...row.cells].some(cell => cell.tagName === 'TH')))
  );
  try {
    const loaded = new Promise((resolve, reject) => {
      source.addEventListener('load', resolve, { once: true });
      setTimeout(() => reject(Error('Source preview load timed out')), 8000);
    });
    source.src = preview.src;
    document.body.append(source);
    await loaded;
    const before = source.contentDocument, after = preview.contentDocument;
    const expected = destinations(links(before));
    const visibleLinks = links(after);
    const observed = destinations(visibleLinks);
    const neutralTarget = /^#review-link-\d+$/;
    const sourceTables = dataTables(before);
    const renderedTables = dataTables(after);
    return {
      width: preview.clientWidth,
      horizontalOverflow: Math.max(0, after.documentElement.scrollWidth - preview.clientWidth),
      sourceDestinations: expected.size,
      renderedDestinations: observed.size,
      missingDestinations: difference(expected, observed),
      addedDestinations: difference(observed, expected),
      externalLinkTargets: [...observed].filter(href => !neutralTarget.test(href)).length,
      unlabeledLinks: visibleLinks.filter(link => !link.textContent.trim() &&
        ![...link.querySelectorAll('img[alt]')].some(image => image.alt.trim())).length,
      duplicateLinks: visibleLinks.length - observed.size,
      missingDataTables: Math.max(0, sourceTables.length - renderedTables.length),
      missingNumberTokens: difference(numbers(before), numbers(after)),
      images: after.images.length,
      externalImageSources: [...after.images].filter(image => !image.src.startsWith('data:')).length,
    };
  } finally {
    source.remove();
  }
})()
"""

HARD_CHECKS = (
    "horizontalOverflow", "missingDestinations", "addedDestinations", "externalLinkTargets",
    "unlabeledLinks", "externalImageSources", "missingDataTables",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshots", required=True, type=Path, help="Directory of *-formatted.html exports")
    parser.add_argument("--out", required=True, type=Path, help="New output directory")
    parser.add_argument("--browser-bin", default="agent-browser")
    parser.add_argument("--screenshots", action="store_true", help="Also save passing email previews")
    args = parser.parse_args()
    if not shutil.which(args.browser_bin):
        parser.error("agent-browser is required. Use --browser-bin to select its executable.")
    suffix = "-formatted.html"
    cases = sorted(path.name.removesuffix(suffix) for path in args.snapshots.glob(f"*{suffix}"))
    if not cases or any(not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name) for name in cases):
        parser.error("Expected snapshots named <case>-formatted.html with lowercase case names.")
    args.out.mkdir(parents=True, exist_ok=False)
    out = args.out.resolve()
    session = "mail-audit-" + uuid4().hex[:12]

    def browser(*command):
        return subprocess.run(
            [args.browser_bin, "--session", session, *command], check=True,
            capture_output=True, text=True, timeout=35,
        ).stdout

    results = []
    with tempfile.TemporaryDirectory(prefix="mail-review-audit-") as temporary:
        with ReviewServer(
            0, args.snapshots, Path(temporary) / "feedback.json",
            titles={name: name.replace("-", " ").capitalize() for name in cases}, quiet=True,
        ) as server:
            listener = threading.Thread(target=server.serve_forever, daemon=True)
            listener.start()
            try:
                browser("open", server.origin)
                browser("set", "viewport", "1040", "900")
                for case in server.cases:
                    for width in WIDTHS:
                        for images in (False, True):
                            result = {
                                "case": case["id"], "revision": case["revision"],
                                "requestedWidth": width, "showSampleImages": images,
                            }
                            try:
                                query = urlencode({"width": width, "images": int(images)})
                                browser("open", f'{server.origin}/?{query}#{case["id"]}')
                                browser("wait", "--fn", f"""(() => {{
                                  const frame = document.querySelector('.candidate iframe');
                                  return frame?.clientWidth === {width} &&
                                    frame.contentDocument.querySelector('.message') &&
                                    Array.from(frame.contentDocument.images).every(image => image.complete);
                                }})()""")
                                result.update(json.loads(browser("eval", AUDIT)))
                                result["failures"] = [key for key in HARD_CHECKS if result[key]]
                                if not images and result["images"]:
                                    result["failures"].append("imagesWithoutOptIn")
                                if args.screenshots or result["failures"] or result["missingNumberTokens"]:
                                    filename = f'{case["id"]}-{width}-{"images" if images else "text"}.png'
                                    browser("screenshot", ".candidate iframe", str(out / filename))
                                    result["screenshot"] = filename
                            except (subprocess.SubprocessError, ValueError) as error:
                                result["failures"] = ["auditUnableToComplete"]
                                result["error"] = type(error).__name__
                                if isinstance(error, subprocess.CalledProcessError):
                                    result["step"] = error.cmd[3]
                            results.append(result)
            finally:
                try:
                    browser("close")
                finally:
                    server.shutdown()
                    listener.join()
    failed = sum(bool(row["failures"]) for row in results)
    (out / "audit.json").write_text(json.dumps({"failed": failed, "checks": results}, indent=2) + "\n")
    print(f"{len(results)} checks, {failed} failed. {out / 'audit.json'}")
    return int(failed != 0)


if __name__ == "__main__":
    raise SystemExit(main())
