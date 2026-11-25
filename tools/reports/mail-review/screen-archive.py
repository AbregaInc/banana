#!/usr/bin/env python3
"""Rank cached HTML mail by structural risk without printing or exporting message content."""
import argparse
from collections import Counter, defaultdict
from contextlib import closing
from datetime import datetime, timezone
from hashlib import sha256
import heapq
import json
import os
from pathlib import Path
import re
import sqlite3
import time
import zlib

from lxml import etree


BODY_LIMIT = 2 * 1024 * 1024  # MailHTMLPreparer.maximumBytes
BLOB_LIMIT = 16 * 1024 * 1024  # MailBlobCodec.maximumBytes
HTML = etree.HTMLParser(encoding="UTF-8", no_network=True, recover=True)
HEADINGS = {"h1", "h2", "h3", "h4", "h5", "h6"}
HIDDEN = re.compile(r"(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden|opacity\s*:\s*0)\s*(?:!important\s*)?(?:;|$)", re.I)
BACKGROUND = re.compile(r"background-image\s*:\s*url\(", re.I)
SAFE_LINK = re.compile(r"^(?:https?://|mailto:)", re.I)
WEIGHT = {
    "headedPanels": 5, "backgroundArtworkAlternative": 5, "linkedProseWrapper": 3,
    "adjacentIconAndText": 4, "nativeHasNoLinks": 5, "nativeHasNoBlocks": 5,
    "nativeHasNoGrid": 2, "cachedFormattedFallback": 2, "largeTableLayout": 1,
}


def unzip(blob, ceiling):
    if not blob or len(blob) < 8 or blob[:4] != b"MBZ1":
        raise ValueError("Invalid cached blob envelope")
    size = int.from_bytes(blob[4:8], "big")
    if size > ceiling:
        raise OverflowError("Body exceeds screening ceiling")
    if not size and len(blob) == 8:
        return b""
    decoder = zlib.decompressobj(wbits=-15)
    data = decoder.decompress(blob[8:], size + 1)
    if len(data) != size or not decoder.eof or decoder.unused_data:
        raise ValueError("Invalid cached blob length")
    return data


def local_text(node):
    return any(c.isprintable() and not c.isspace() for text in node.itertext() for c in text)


def signals(raw, prepared):
    root = etree.fromstring(raw, HTML)
    if root is None:
        return set(), (0, 0, 0, 0)
    eligibility = {}

    def visible(node):
        if node in eligibility:
            return eligibility[node]
        parent = node.getparent()
        result = (
            node.tag != "blockquote" and node.get("aria-hidden") != "true"
            and node.get("hidden") is None and not HIDDEN.search(node.get("style", ""))
            and (parent is None or visible(parent))
        )
        eligibility[node] = result
        return result

    found = set()
    table_count = sum(1 for _ in root.iter("table"))
    headings = sum(1 for _ in root.iter(*HEADINGS))
    links = 0
    named_links = 0
    actions = defaultdict(list)
    for link in root.iter("a"):
        href = link.get("href", "").strip()
        if not SAFE_LINK.match(href) or not visible(link):
            continue
        links += 1
        label = local_text(link)
        if label:
            named_links += 1
        if "linkedProseWrapper" not in found and label and next(link.iter("table"), None) is not None:
            if len(" ".join("".join(link.itertext()).split())) >= 120:
                found.add("linkedProseWrapper")
        icon = not label and next(link.iter("img"), None) is not None
        if label or icon:
            row = next(link.iterancestors("tr"), None)
            if row is not None:
                actions[row].append((href, icon))
    if any(a == b and x != y for row in actions.values() for (a, x), (b, y) in zip(row, row[1:])):
        found.add("adjacentIconAndText")

    data_table = any(
        table.get("role") != "presentation" and visible(cell)
        for cell in root.iter("th", "caption")
        if (table := next(cell.iterancestors("table"), None)) is not None
    )
    if headings >= 2:
        for row in root.iter("tr"):
            if sum(
                any(child.tag in HEADINGS and visible(child) for child in cell)
                for cell in row if cell.tag in {"td", "th"}
            ) >= 2:
                found.add("headedPanels")
                break
    for cell in root.iter("td"):
        if not BACKGROUND.search(cell.get("style", "")) or not visible(cell):
            continue
        # Some malformed layouts put a link around a table. A repair parser can
        # move that link outside the cell, so screen the authored image pair itself.
        if any(img.get("alt", "").strip() for img in cell.iter("img")):
            found.add("backgroundArtworkAlternative")
            break
    if table_count >= 12:
        found.add("largeTableLayout")

    if prepared:
        blocks = prepared.get("text", {}).get("blocks", [])
        kinds = [block.get("kind", {}) for block in blocks]
        linked_runs = any(run.get("link") for block in blocks for run in block.get("runs", []))
        linked_picture = any(kind.get("picture", {}).get("_0", {}).get("link") for kind in kinds)
        if named_links and not linked_runs and not linked_picture:
            found.add("nativeHasNoLinks")
        if not blocks and root.find("body") is not None and local_text(root.find("body")):
            found.add("nativeHasNoBlocks")
        if data_table and not any("table" in kind for kind in kinds):
            found.add("nativeHasNoGrid")
        if prepared.get("prefersOriginal"):
            found.add("cachedFormattedFallback")
    shape = (table_count.bit_length(), headings.bit_length(), links.bit_length(), int(data_table))
    return found, shape


def identify(account, message):
    return sha256((account + "\0" + message).encode()).hexdigest()[:20]


def stage_examples(source, references, output):
    private = Path(__file__).resolve().parents[3] / "private"
    if not output.resolve().is_relative_to(private) or output.resolve() == private:
        raise ValueError("Stage real source under this checkout's private/ directory.")
    if any(not re.fullmatch(r"[0-9a-f]{20}", ref) for ref in references):
        raise ValueError("Use references from a screening report.")
    wanted = set(references)
    examples = {}
    with closing(sqlite3.connect(source, uri=True, timeout=3)) as database:
        database.execute("PRAGMA query_only=ON")
        keys = database.execute("SELECT account,gmail_id FROM content WHERE level=2 AND html IS NOT NULL")
        for account, message in keys:
            ref = identify(account, message)
            if ref not in wanted:
                continue
            row = database.execute(
                "SELECT html,plain FROM content WHERE account=? AND gmail_id=?", (account, message)
            ).fetchone()
            if row is None:
                continue
            html, plain = row
            examples[ref] = {"input.html": unzip(html, BODY_LIMIT)}
            if plain:
                examples[ref]["input.txt"] = unzip(plain, BLOB_LIMIT)
            if examples.keys() == wanted:
                break
    if examples.keys() != wanted:
        raise ValueError(f"{len(wanted - examples.keys())} references are unavailable in this cache.")
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for ref, files in examples.items():
        folder = output / ref
        folder.mkdir(mode=0o700)
        for filename, contents in files.items():
            descriptor = os.open(folder / filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as entry:
                entry.write(contents)
    print(f"Staged {len(examples)} examples locally in {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path, help="New report path under private/")
    parser.add_argument("--limit", type=int, help="Stop after this many HTML messages")
    parser.add_argument("--pick", action="append", metavar="REFERENCE",
                        help="Stage a selected raw message under private/ instead of screening")
    args = parser.parse_args()
    source = args.database.resolve().as_uri() + "?mode=ro"
    if args.pick:
        if args.limit is not None:
            parser.error("--limit applies to screening.")
        try:
            stage_examples(source, args.pick, args.out)
        except (OSError, ValueError, OverflowError, sqlite3.Error, zlib.error) as error:
            parser.exit(1, f"{error}\n")
        return
    if args.limit is not None and args.limit < 1:
        parser.error("--limit must be positive")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    counts, issues, versions, shapes = Counter(), Counter(), Counter(), Counter()
    candidates = defaultdict(list)
    controls = []
    with open(args.out, "x", encoding="utf-8", opener=lambda path, flags: os.open(path, flags, 0o600)) as report:
        with closing(sqlite3.connect(source, uri=True, timeout=3)) as database:
            database.execute("PRAGMA query_only=ON")
            after = ("", "")
            while args.limit is None or counts["seen"] < args.limit:
                quota = min(128, args.limit - counts["seen"]) if args.limit is not None else 128
                rows = database.execute("""
                    SELECT c.account, c.gmail_id, c.html, p.body, p.prep_version
                    FROM content c LEFT JOIN prepared p
                      ON p.account=c.account AND p.gmail_id=c.gmail_id AND p.source_rev=c.content_rev
                    WHERE (c.account,c.gmail_id)>(?,?) AND c.level=2 AND c.html IS NOT NULL
                    ORDER BY c.account,c.gmail_id LIMIT ?
                """, (*after, quota)).fetchall()
                if not rows:
                    break
                after = rows[-1][:2]
                for account, message, html, body, version in rows:
                    counts["seen"] += 1
                    try:
                        raw = unzip(html, BODY_LIMIT)
                    except OverflowError:
                        counts["overBodyLimit"] += 1
                        continue
                    except (ValueError, zlib.error):
                        counts["invalidHtmlBlob"] += 1
                        continue
                    prepared = None
                    if body:
                        try:
                            decoded = json.loads(unzip(body, BLOB_LIMIT))
                            if not isinstance(decoded, dict):
                                raise ValueError("Invalid prepared body")
                            prepared = decoded
                            versions[version] += 1
                        except (ValueError, OverflowError, zlib.error):
                            counts["invalidPreparedBlob"] += 1
                    if prepared is None:
                        counts["noComparablePreparedBody"] += 1
                    try:
                        found, shape = signals(raw, prepared)
                    except etree.LxmlError:
                        counts["parseFailure"] += 1
                        continue
                    counts["screened"] += 1
                    item = identify(account, message)
                    if found:
                        counts["flagged"] += 1
                        if found - {"largeTableLayout", "cachedFormattedFallback"}:
                            counts["targeted"] += 1
                        issues.update(found)
                        group = (tuple(sorted(found)), shape)
                        shapes[group] += 1
                        sample, limit = candidates[group], 3
                    else:
                        sample, limit = controls, 30
                    if len(sample) < limit:
                        heapq.heappush(sample, item)
                    else:
                        heapq.heappushpop(sample, item)
                    if counts["screened"] % 10000 == 0:
                        print(f"{counts['screened']:,} messages screened", flush=True)

        groups = [
            {"signals": flags, "shape": shape, "messages": amount, "references": sorted(candidates[(flags, shape)])}
            for (flags, shape), amount in sorted(shapes.items(), key=lambda row: (
                -sum(WEIGHT[flag] for flag in row[0][0]), -row[1], row[0]
            ))
        ]
        json.dump({
            "at": datetime.now(timezone.utc).isoformat(), "elapsedSeconds": round(time.monotonic() - start, 2),
            "coverage": counts, "signals": issues, "cachedPreparationVersions": versions,
            "candidateGroups": groups, "unflaggedControlReferences": sorted(controls),
        }, report, indent=2)
        report.write("\n")
    print(f"{counts['screened']:,} HTML messages screened, {counts['flagged']:,} flagged. {args.out}")


if __name__ == "__main__":
    main()
