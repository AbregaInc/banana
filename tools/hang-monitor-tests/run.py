#!/usr/bin/env python3
"""Exercise the production hang monitor on a real Mac main run loop without opening a window."""
import argparse
import json
from pathlib import Path
import subprocess

source = Path(__file__).resolve().parent
root = source.parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", type=Path, required=True)
out = parser.parse_args().out.resolve()
out.mkdir(parents=True, exist_ok=False)
binary = out / "check"
implementation = root / "Banana/Model/ProblemReports/MainRunLoopHangMonitor.swift"
subprocess.run([root / "tools/agents/xcode-lock.sh", "-l", "build", "swiftc", "-O", implementation,
                source / "main.swift", "-o", binary], check=True)
failed = []
with (out / "samples.jsonl").open("w") as output:
    for case in ["idle", "early-input", "late-layout", "nested-idle", "nested-refresh", "nested-stall",
                 "stop-restart", "cancel-pending", "stop-after-recovery", "two-stalls"]:
        run = subprocess.run([binary, case], stdout=output, timeout=12)
        output.flush()
        if run.returncode:
            failed.append(case)
(out / "verdict.json").write_text(json.dumps({"failed": failed, "scenarios": 10}, indent=2) + "\n")
raise SystemExit(bool(failed))
