#!/usr/bin/env python3
"""Report settled viewport geometry and redraw work from the Day swipe UI tests."""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path


COUNTERS = ("applies", "reloads", "cellConfigurations", "layouts",
            "bodyEvaluations", "preparedDayWindows", "pageTransitions")


def summarize(samples):
    if not samples:
        return {"observations": 0, "swipes": [], "completedRoundTrip": False}
    first = samples[0]
    initial_ruler = first["windowY"] - first["y"]
    swipes = []
    for before, after in zip(samples, samples[1:]):
        drag = after.get("lastDayDrag", {})
        released = drag.get("release")
        settled = drag.get("settled")
        duration = None
        if (released is not None and settled is not None and settled >= released
                and released != before.get("lastDayDrag", {}).get("release")):
            duration = (settled - released) * 1000
        swipes.append({
            "releaseToSettledMS": duration,
            "changedDay": before["page"] != after["page"],
            "offsetChangePoints": after["y"] - before["y"],
            "rulerShiftFromStartPoints": after["windowY"] - after["y"] - initial_ruler,
            "viewportWidthPoints": after["width"],
            "viewportHeightPoints": after["height"],
            "visibleCells": after["visibleCells"],
            "descriptors": after["descriptors"],
            "work": {key: after[key] - before[key] for key in COUNTERS},
        })

    def event_ids(state):
        return sorted(value for value in state["visibleIDs"] if "calendar.currentTime" not in value)

    return {
        "observations": len(samples),
        "swipes": swipes,
        "completedRoundTrip": (len(swipes) == 4 and all(row["changedDay"] for row in swipes)
                               and first["page"] == samples[-1]["page"]
                               and event_ids(first) == event_ids(samples[-1])),
    }


def read_run(bundle, test):
    identifier = f"ScaleStressUITests/{test}()"
    details = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "test-details",
                              "--path", str(bundle), "--test-id", identifier],
                             check=True, stdout=subprocess.PIPE)
    result = json.loads(details.stdout)["testResult"]
    with tempfile.TemporaryDirectory() as temp:
        folder = Path(temp)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                        "--test-id", identifier, "--output-path", temp,
                        "--filter", "Day swipe geometry and redraw counts*"],
                       stdout=subprocess.DEVNULL, check=True)
        samples = []
        for section in json.loads((folder / "manifest.json").read_text()):
            for attachment in section["attachments"]:
                samples.append(summarize(json.loads((folder / attachment["exportedFileName"]).read_text())))
        return {"testResult": result, "runs": samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xcresult", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    data = {"scope": "After each gesture settles. Ruler shift combines viewport origin and content offset. "
                     "Body, layout and binding counts measure work. Screen recordings cover the transition."}
    for orientation in ("Portrait", "Landscape"):
        data[orientation.lower()] = read_run(args.xcresult, "testDaySwipesKeepTheTimeIn" + orientation)
    with args.out.open("x", encoding="utf-8") as output:
        json.dump(data, output, indent=2)
        output.write("\n")
    return 0 if all(data[key]["testResult"] == "Passed" and data[key]["runs"]
                    and all(r["completedRoundTrip"] for r in data[key]["runs"])
                    for key in ("portrait", "landscape")) else 1


if __name__ == "__main__":
    raise SystemExit(main())
