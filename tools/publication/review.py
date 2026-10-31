#!/usr/bin/env python3
"""Inventory a publication candidate without changing Git or printing secret values.

Reports and a non-executable source snapshot go in a new private directory outside
the repository. No uploads, history rewrites, credential checks or builds occur.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True,
                        help="New report directory outside the repository")
    parser.add_argument("--include-untracked", action="store_true")
    parser.add_argument("--inventory-only", action="store_true",
                        help="Skip secret scans; result explicitly remains incomplete")
    args = parser.parse_args()
    out = args.output.expanduser().resolve()
    if out == ROOT or ROOT in out.parents:
        parser.error("reports must be outside the repository")
    if out.exists():
        parser.error("output must be new, to avoid mixing scan revisions")
    out.mkdir(parents=True, mode=0o700)
    os.chmod(out, 0o700)
    snapshot = out / "candidate"
    snapshot.mkdir()
    flags = ["ls-files", "--cached", "-z"]
    if args.include_untracked:
        flags += ["--others", "--exclude-standard"]
    paths = sorted(set(p for p in git(*flags).decode().split("\0") if p))
    patterns = {
        "local-user-path": re.compile(r"/Users/[^/\s\"']+/"),
        "device-identifier": re.compile(
            r"\b(?:[A-F0-9]{8}(?:-[A-F0-9]{4}){3}-[A-F0-9]{12}"
            r"|00008[0-9A-F]{3}-[0-9A-F]{16})\b"),
        "email": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    }
    inventory = defaultdict(list)
    manifest = []
    skipped = []
    for rel in paths:
        p = ROOT / rel
        # Reject symlinked parents as well as symlinked files; do not copy data
        # from outside the source tree through a developer's local link.
        components = [p, *list(p.parents)[:len(Path(rel).parts) - 1]]
        if any(part.is_symlink() for part in components) or not p.is_file():
            skipped.append(rel)
            continue
        data = p.read_bytes()
        dest = snapshot / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        manifest.append({"path": rel, "bytes": len(data),
                         "sha256": hashlib.sha256(data).hexdigest()})
        if b"\0" in data:
            inventory["binary-needs-review"].append({"path": rel})
            continue
        text = data.decode("utf-8", errors="replace")
        for category, pattern in patterns.items():
            lines = [n for n, line in enumerate(text.splitlines(), 1)
                     if pattern.search(line)]
            if lines:
                inventory[category].append({"path": rel, "lines": lines})
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / "privacy-inventory.json").write_text(
        json.dumps(dict(inventory), indent=2) + "\n")
    result = {
        "head": git("rev-parse", "HEAD").decode().strip(),
        "dirty": bool(git("status", "--porcelain")),
        "files": len(manifest), "skippedMissingOrSymlinked": skipped,
        "includesUntracked": args.include_untracked,
        "privacyCandidateFiles": {k: len(v) for k, v in inventory.items()},
        "secretScans": {}, "publicationApproved": False,
    }
    if not args.inventory_only:
        scanner = shutil.which("gitleaks")
        if not scanner:
            result["blocker"] = "gitleaks is not installed; no secret scan ran"
        else:
            result["gitleaksVersion"] = subprocess.check_output(
                [scanner, "version"], text=True).strip()
            # Ignore repository-provided suppressions during publication review.
            config = out / "scanner.toml"
            config.write_text("[extend]\nuseDefault = true\n")
            ignore = out / "empty-ignore"
            ignore.write_text("")
            for name, scope in [
                ("history", ["git", str(ROOT), "--log-opts=--all --full-history"]),
                ("candidate", ["dir", str(snapshot)]),
            ]:
                report = out / (name + "-redacted.json")
                command = [scanner, *scope, "--config", str(config),
                           "--gitleaks-ignore-path", str(ignore), "--redact=100",
                           "--ignore-gitleaks-allow", "--max-archive-depth=2",
                           "--timeout=180", "--no-banner", "--report-format=json",
                           "--report-path", str(report)]
                with (out / (name + "-scan.log")).open("w") as log:
                    try:
                        completed = subprocess.run(
                            command, cwd=out, stdout=log, stderr=log,
                            timeout=195, env={**os.environ, "GOMAXPROCS": "2"})
                        code = completed.returncode
                    except subprocess.TimeoutExpired:
                        code = 124
                findings = json.loads(report.read_text()) if report.exists() else None
                result["secretScans"][name] = {
                    "exitCode": code,
                    "findings": len(findings) if findings is not None else None,
                    "rules": dict(Counter(x["RuleID"] for x in findings or [])),
                    "report": report.name,
                }
    result["status"] = "manual-review-required"
    (out / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    # A successful inventory or scanner run is not permission to publish.
    return 0 if args.inventory_only or len(result["secretScans"]) == 2 and all(
        x["exitCode"] in (0, 1) and x["findings"] is not None
        for x in result["secretScans"].values()) else 2


if __name__ == "__main__":
    sys.exit(main())
