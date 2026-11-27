#!/usr/bin/env python3
"""Count observed battery readings and transport failures in one app journal, in device-local time."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


# Output fixed categories only. Device registrations, calendar names and other paths may contain IDs.
ENDPOINTS = {
    "/v1/mail/feed", "/v1/mail/read", "/v1/mail/operation", "/v1/mail/content",
    "/v1/account", "/v1/calendar/read",
}
FAILURE = re.compile(r"^(?:GET|POST|PUT|PATCH|DELETE) (\S+) failed: (.*)$")
BATTERY = re.compile(r"\bbattery=(\d{1,3})%/(\w+)")
STAMP = re.compile(r"\d\d-\d\d (\d\d:\d\d:\d\d\.\d{3})")


def summarize(lines, day):
    counts, timeouts, minutes, scenes = Counter(), Counter(), Counter(), Counter()
    readings = []
    active_transcription = 0
    max_transcription_cpu = None
    longest_single_transcription_ms = None
    matched = 0
    for line in lines:
        if not line.startswith(day + " "):
            continue
        fields = line.rstrip().split("  ", 2)
        if len(fields) != 3:
            continue
        stamp, tag, message = fields
        timestamp = STAMP.fullmatch(stamp)
        if timestamp is None:
            continue
        matched += 1
        if tag.startswith("⚡ POWER "):
            scene = re.search(r"\bscene=(foreground|background)\b", message)
            scenes[scene[1] if scene else "unknown"] += 1
            battery = BATTERY.search(message)
            if battery and 0 <= int(battery[1]) <= 100:
                readings.append({"time": timestamp[1], "percent": int(battery[1])})
            if re.search(r"\btranscribe=[1-9]\d*active\b", message):
                active_transcription += 1
                average = re.search(r"\bcpu=(\d+(?:\.\d+)?)% avg/", message)
                if average:
                    max_transcription_cpu = max(max_transcription_cpu or 0, float(average[1]))
            # Multiple completions in one rollup have a combined duration.
            completed = re.search(r"\bdone=\[([^\]]*)\]", message)
            for duration in re.findall(r"(?:^|,)transcription×1/(\d+)ms(?:,|$)", completed[1] if completed else ""):
                longest_single_transcription_ms = max(longest_single_transcription_ms or 0, int(duration))
        if tag != "☁️ account":
            continue
        failed = FAILURE.fullmatch(message)
        if failed:
            path, detail = failed.groups()
            endpoint = path if path in ENDPOINTS else "other"
            if path == "/v1/devices" or path.startswith("/v1/devices/"):
                endpoint = "device registration"
            counts[endpoint] += 1
            minutes[stamp[:11]] += 1
            if "timed out" in detail.lower():
                timeouts[endpoint] += 1
    readings.sort(key=lambda r: r["time"])
    return {
        "day": day, "journalEntries": matched, "powerSamplesByScene": dict(scenes),
        "batteryReadings": len(readings), "firstBattery": readings[0] if readings else None,
        "lastBattery": readings[-1] if readings else None,
        "observedDecreases": [{"from": a, "to": b} for a, b in zip(readings, readings[1:])
                              if b["percent"] < a["percent"]],
        "powerSamplesWithTranscriptionActive": active_transcription,
        "highestSampledProcessCPUAvgPctWithTranscriptionActive": max_transcription_cpu,
        "longestIndividuallyReportedTranscriptionElapsedMS": longest_single_transcription_ms,
        "failedRequests": sum(counts.values()), "timeoutMessages": sum(timeouts.values()),
        "byEndpoint": {k: {"failures": counts[k], "timeouts": timeouts[k]} for k in sorted(counts)},
        "minutesWithFailures": len(minutes), "minutesWithMultipleFailures": sum(v > 1 for v in minutes.values()),
        "maxFailuresInOneMinute": max(minutes.values(), default=0),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("journal", type=Path)
    parser.add_argument("--day", required=True, help="Device-local MM-DD from a single retained journal")
    args = parser.parse_args()
    if not re.fullmatch(r"(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])", args.day):
        parser.error("day must be MM-DD")
    with args.journal.open(errors="replace") as journal:
        print(json.dumps(summarize(journal, args.day), indent=2))
