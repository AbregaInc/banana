"""Export only numeric relevance and cost measurements from two local replay fixtures."""

import argparse
import importlib
import json
import math
import random
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

import numpy as np

# Each duration is either directly timed or the sum of separately measured serial stages.
STAGES = {
    "chronological": ["chronologicalMS"],
    "previous": ["oldMS"],
    "swift": ["swiftMS"],
    "swiftFull": ["swiftFullMS"],
    "swiftSender": ["swiftFullMS", "senderMS"],
    "swiftRecent": ["swiftFullMS", "recentMS"],
    "swiftFullCE": ["swiftFullMS", "swiftFullCEMS"],
    "swiftFullFast": ["swiftFullMS", "swiftFullFastMS"],
    "swiftCoverage": ["swiftCoverageMS"],
    "dense": ["denseMS"],
    "hybrid": ["oldMS", "denseMS"],
    "swiftHybrid": ["swiftMS", "denseMS"],
    "lexicalCE": ["oldMS", "lexicalCEMS"],
    "hybridCE": ["oldMS", "denseMS", "hybridCEMS"],
    "swiftCE": ["swiftMS", "swiftCEMS"],
    "swiftHybridCE": ["swiftMS", "denseMS", "swiftHybridCEMS"],
    "swiftFast": ["swiftMS", "swiftFastMS"],
    "lexFast": ["oldMS", "lexFastMS"],
    "hybridFast": ["oldMS", "denseMS", "hybridFastMS"],
    "guardedCE": ["oldMS", "lexicalCEMS"],
    "guardedHybridCE": ["oldMS", "denseMS", "hybridCEMS"],
}


def read(root, name):
    return json.loads((root / name).read_text())


def disk(root):
    return sum(f.stat().st_size for f in root.rglob("*") if f.is_file())


def resource(path):
    lines = path.read_text().splitlines()
    return {
        "wallSeconds": float(next(line.split()[0] for line in lines if " real " in line)),
        "peakResidentBytes": int(
            next(line.split()[0] for line in lines if "maximum resident set size" in line)
        ),
    }


def dcg(grades):
    return sum((2**g - 1) / math.log2(i + 2) for i, g in enumerate(grades[:5]))


def corpus(path):
    rows = bodies = body_bytes = 0
    with path.open() as docs:
        for line in docs:
            text = json.loads(line)["body"]
            rows += 1
            bodies += bool(text)
            body_bytes += len(text.encode("utf-8"))
    return {"documents": rows, "nonemptyBodies": bodies, "bodyUTF8Bytes": body_bytes}


def paired(rows, split):
    # Resample whole searches so that five results for one question stay together.
    methods = rows["methods"]
    n = rows["count"]
    draws = np.random.default_rng(4517).integers(n, size=(10000, n))
    for data in methods.values():
        for baseline in ["previous", "chronological"]:

            def values(cases):
                a = np.asarray(cases)
                if split == "discussion":
                    return a
                if split == "purpose":
                    return a / 5
                return ((a > 0) & (a <= 5)).astype(float)

            diff = values(data["cases"]) - values(methods[baseline]["cases"])
            lo, hi = np.quantile(diff[draws].mean(axis=1), [0.025, 0.975])
            data.setdefault("paired", {})[baseline] = {
                "better": int((diff > 0).sum()),
                "worse": int((diff < 0).sum()),
                "meanDelta": round(float(diff.mean()), 4),
                "bootstrap95": [round(float(lo), 4), round(float(hi), 4)],
            }


def evaluate(root):
    tasks = read(root, "queries.json")
    results = importlib.import_module("mail-pretrained").scored_results(root)
    judgments = read(root, "judgments.json") if (root / "judgments.json").exists() else {}
    report = {
        "fieldedBuild": read(root, "field-stats.json"),
        "denseBuild": read(root, "dense-build.json"),
        "allMessages": corpus(root / "messages.jsonl"),
        "conversationExcerpts": corpus(root / "documents.jsonl"),
        "swiftBuild": dict(resource(root / "swift-build-time"), bytes=disk(root / "swift-index")),
        "swiftFullBuild": dict(resource(root / "full-build-time"), bytes=disk(root / "full-index")),
        "swiftFullLookupProcess": resource(root / "full-read-time"),
        "swiftLookupProcess": resource(root / "swift-read-time"),
        "splits": {},
    }
    if judgments:
        report["judgeControls"] = judgments["controls"]
        report["purposePools"] = {
            k: {"size": len(pool), "relevant": sum(pool.values())} for k, pool in judgments["labels"].items()
        }
        report["judgedQueryThreadPairs"] = sum(len(pool) for pool in judgments["labels"].values())
    for split in sorted({t["split"] for t in tasks}):
        chosen = [t for t in tasks if t["split"] == split]
        rows = report["splits"][split] = {
            "count": len(chosen),
            "caseIds": [t["id"] for t in chosen],
            "methods": {},
        }
        for method, stages in STAGES.items():
            cases = []
            times = []
            for t in chosen:
                row = results[t["id"]]
                keys = row[method]
                times.append(sum(row[s] for s in stages))
                if split == "discussion":
                    grades = t["grades"]
                    cases.append(
                        round(
                            dcg([grades.get(str(k), 0) for k in keys[:5]])
                            / dcg(sorted(grades.values(), reverse=True)),
                            5,
                        )
                    )
                elif split == "purpose":
                    grades = judgments["labels"].get(t["id"], {})
                    cases.append(sum(grades[str(k)] for k in keys[:5]))
                else:
                    cases.append(keys.index(t["pk"]) + 1 if t["pk"] in keys else 0)
            data = {
                "cases": cases,
                "medianMS": round(statistics.median(times), 3),
                "p95MS": round(sorted(times)[math.ceil(0.95 * len(times)) - 1], 3),
            }
            if split == "discussion":
                data["ndcg5"] = round(statistics.mean(cases), 4)
            elif split == "purpose":
                data["precision5"] = round(statistics.mean(cases) / 5, 4)
                data["any5"] = sum(v > 0 for v in cases)
            else:
                for k in [1, 5, 50]:
                    data[f"top{k}"] = sum(0 < v <= k for v in cases)
                data["mrr10"] = round(statistics.mean(1 / v if 0 < v <= 10 else 0 for v in cases), 4)
            rows["methods"][method] = data
        paired(rows, split)
    return report


def fresh_process(root, binary):
    tasks = read(root, "queries.json")
    chosen = random.Random(73131).sample(tasks, 15)
    open_ms, wall_ms, first_ms = [], [], []
    with tempfile.TemporaryDirectory(dir=root) as scratch:
        request = Path(scratch) / "queries.json"
        response = Path(scratch) / "results.json"
        for task in chosen:
            for queries, times in [([], open_ms), ([{"id": "query", "query": task["query"]}], wall_ms)]:
                request.write_text(json.dumps(queries))
                start = time.perf_counter()
                subprocess.run([binary, "full", root / "full-index", request, response], check=True)
                times.append((time.perf_counter() - start) * 1000)
                if queries:
                    first_ms.append(json.loads(response.read_text())[0]["ms"][0])
    return {
        k: {
            "median": round(statistics.median(v), 3),
            "p95": round(float(np.quantile(v, 0.95, method="inverted_cdf")), 3),
        }
        for k, v in [
            ("openEmptyAndExitMS", open_ms),
            ("openThreeLookupsAndExitMS", wall_ms),
            ("firstLookupMS", first_ms),
        ]
    }


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", type=Path, required=True, help="Contains beta, public and models")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--binary", type=Path, help="Also measure new Swift processes against warm OS file caches")
    a = p.parse_args()
    result = {name: evaluate(a.root / name) for name in ["beta", "public"]}
    result["modelBytes"] = {name: disk(a.root / "models" / name) for name in ["potion", "fast", "reranker"]}
    if a.binary:
        for name in ["beta", "public"]:
            result[name]["freshSwiftProcess"] = fresh_process(a.root / name, a.binary)
    a.out.write_text(json.dumps(result, indent=1) + "\n")
