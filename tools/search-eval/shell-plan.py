"""Replay the current Swift shell selector with a synthetic occurrence store on macOS."""
import argparse
import hashlib
import json
import platform
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--reference-matcher", action="store_true",
                    help="Use Foundation folding and tokenization on every field for an equal-coverage control.")
args = parser.parse_args()
if args.out.exists():
    parser.error("Choose a new output path to preserve previous measurements.")


def declaration(path, start, end):
    source = (root / path).read_text()
    return source[source.index(start):source.index(end, source.index(start))]


# Compile the production declarations verbatim. Only the store, data and clock are fixtures.
rules = declaration("Banana/Model/ShellRules.swift", "enum ShellSearchRules {", "/// Where the podcast player")
if args.reference_matcher:
    start = rules.index("    static func containsPrefix(")
    end = rules.index("    static func words(", start)
    rules = rules[:start] + """    static func containsPrefix(_ word: String, in text: String) -> Bool {
        words(text).contains { $0.hasPrefix(word) }
    }

""" + rules[end:]
selector = declaration("Banana/Views/Shell/ShellSearch.swift", "    static func matchingPlanOccurrences", "    private static func plan(")
with tempfile.TemporaryDirectory() as temp:
    directory = Path(temp)
    swift = directory / "Selector.swift"
    swift.write_text("import Foundation\n" + rules + "\nenum Replay {\n" + selector + "}\n")
    binary = directory / "benchmark"
    subprocess.run([root / "tools/agents/xcode-lock.sh", "swiftc", "-O", swift,
                    Path(__file__).with_name("main.swift"), "-o", binary], check=True)
    results = json.loads(subprocess.check_output([binary]))
report = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
          "referenceMatcher": args.reference_matcher,
          "selectorSHA256": hashlib.sha256((rules + selector).encode()).hexdigest(),
          "fixtureSHA256": hashlib.sha256(Path(__file__).with_name("main.swift").read_bytes()).hexdigest(),
          "platform": [platform.machine(), platform.mac_ver()[0]],
          "scope": "Host Swift selector only. Synthetic in-memory occurrences; no debounce, rendering, provider or disk.",
          "runs": results}
with args.out.open("x") as output:
    json.dump(report, output, indent=2)
    output.write("\n")
