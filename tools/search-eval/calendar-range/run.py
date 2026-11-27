"""Compare the immutable calendar range index on sorted and disordered timelines."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[3]
path = "Banana/Model/TimeRangeIndex.swift"
output = Path(sys.argv[1])
if output.exists():
    raise SystemExit("Choose a fresh output path")
runs = []
with tempfile.TemporaryDirectory() as temp:
    temp = Path(temp)
    ref = temp / "Original.swift"
    ref.write_bytes(subprocess.check_output(["git", "show", "f987bd34:" + path], cwd=root))
    for name, source in [("reference", ref), ("candidate", root / path)]:
        subprocess.run([root / "tools/agents/xcode-lock.sh", "swiftc", "-O", "-whole-module-optimization",
                        source, Path(__file__).with_name("main.swift"), "-o", temp / name], check=True)
    for trial in range(6):
        for order in ["sorted", "shuffled"]:
            for name in (["reference", "candidate"] if trial % 2 == 0 else ["candidate", "reference"]):
                result = json.loads(subprocess.check_output([temp / name, order]))
                runs.append(dict(trial=trial, policy=name, **result))
with output.open("x") as handle:
    json.dump({"scope": "Host Swift generic index, synthetic value rows, fresh processes, no UI",
               "referenceRevision": "f987bd34", "runs": runs}, handle, indent=2)
    handle.write("\n")
