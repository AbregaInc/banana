#!/usr/bin/env python3
"""Export the retained calendar comparison's numeric evidence, without machine IDs.

No benchmark is run and no reference, baseline, or original result is changed.
"""
import hashlib
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "docs/performance/scale-results/calendar-native-day-20261010/preparation-comparison.json"
TARGET = ROOT / "docs/publication/calendar-preparation.json"


def main():
    rows = json.loads(SOURCE.read_text())
    runs = []
    for row in rows:
        identity, artwork = row["identity"], row["artwork"]
        samples = artwork["samplesMS"]
        if not samples or artwork["droppedSamples"] or artwork["pendingJobs"]:
            raise ValueError("Incomplete retained run; do not discard it or publish a passing summary")
        runs.append({
            "case": row["case"], "policy": identity["dayViewport"],
            "binarySHA256": identity["binarySHA256"],
            "collectorSHA256": identity["collectorSHA256"],
            "runtime": identity["device"]["runtime"],
            "deviceType": identity["device"]["deviceTypeIdentifier"],
            "xcode": identity["xcode"], "summary": row["summary"],
            "samplesMS": samples, "totalPreparationMS": sum(samples),
            "consumerPixelBytes": artwork["consumerPixelBytes"],
            "renders": artwork["renders"],
            "droppedSamples": artwork["droppedSamples"],
            "pendingJobs": artwork["pendingJobs"],
            "queueRejections": artwork["queueRejections"],
        })
    if len(runs) != 4 or [r["policy"] for r in runs] != ["reference", "native", "native", "reference"]:
        raise ValueError("Retained comparison/order changed; requires review")
    reference = statistics.mean(r["totalPreparationMS"] for r in runs if r["policy"] == "reference")
    native = statistics.mean(r["totalPreparationMS"] for r in runs if r["policy"] == "native")
    result = {
        "source": str(SOURCE.relative_to(ROOT)),
        "sourceSHA256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "experimentDate": "2026-10-10",
        "workload": {"fixture": "legacy", "days": 30, "newEventsPerDay": 100, "retainedEvents": 3000},
        "scope": "Aggregate main-actor preparation/rasterization/cache-insertion samples, not FPS, a single frame, wall-clock readiness or input latency",
        "normalization": "Numeric samples and comparison identities retained; private device UUIDs, names, local paths and last-use timestamps omitted. Originals unchanged.",
        "referenceMeanMS": reference, "nativeMeanMS": native,
        "reductionPercent": (1 - native / reference) * 100,
        "runs": runs,
    }
    TARGET.write_text(json.dumps(result, indent=2) + "\n")
    print(f"{reference:.5f} -> {native:.5f} ms ({result['reductionPercent']:.3f}%); {TARGET.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
