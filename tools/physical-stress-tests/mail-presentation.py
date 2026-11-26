#!/usr/bin/env python3
"""Align the physical Mail test's native touch timestamps with recorded readable paragraphs."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from presentation_clock import align, capture


def readable_frames(movie, rotation, start, end):
    filters = [rotation] if rotation else []
    filters += [f"select=between(t\\,{start}\\,{end})", "scale=780:-2", "showinfo"]
    result = []
    with tempfile.TemporaryDirectory(prefix="mail-readable-") as folder:
        frames = Path(folder)
        decode = subprocess.run(["ffmpeg", "-nostdin", "-v", "info", "-threads", "2", "-copyts", "-noautorotate", "-i", movie,
                                 "-vf", ",".join(filters), "-fps_mode", "passthrough", "-enc_time_base", "filter",
                                 "-q:v", "2", frames / "%05d.jpg"], capture_output=True, check=True)
        times = [float(value) for value in re.findall(rb"\bn:\s*\d+\s+pts:\s*\d+\s+pts_time:([.\d]+)", decode.stderr)]
        files = sorted(frames.glob("*.jpg"))
        if len(times) != len(files):
            raise ValueError("Could not align sampled frames with their timestamps")
        for timestamp, path in zip(times, files):
            words = capture(["tesseract", path, "stdout", "--psm", "6"], stderr=subprocess.DEVNULL,
                            env={**os.environ, "OMP_THREAD_LIMIT": "1"}).decode(errors="replace").lower()
            sections = sorted({int(number) for number in re.findall(r"\bsection\s+(\d+)\b", words)})
            readable = 1 in sections and any(number in sections for number in range(2, 7))
            result.append({"recordingSeconds": timestamp, "sectionNumbers": sections, "readable": readable})
            if readable:
                break
    return result


def measure(folder):
    entries = json.loads((folder / "manifest.json").read_text())[0]["attachments"]

    def attachment(prefix):
        return folder / next(a["exportedFileName"] for a in entries if a["suggestedHumanReadableName"].startswith(prefix))

    audit = json.loads(attachment("Mail touch and recording clock").read_text())[0]
    movie = attachment("Screen Recording")
    pulses, rotation, offset, offsets, all_offsets = align(movie, audit)
    lift = audit["up"] + offset
    observations = readable_frames(movie, rotation, max(0, lift - .4), lift + 2)
    if not observations or not observations[-1]["readable"]:
        raise ValueError("No recorded frame in the opening interval showed two correct paragraphs")
    first = observations[-1]["recordingSeconds"]

    def ms(seconds):
        return round(1000 * seconds, 2)

    if first < offset + max([audit["selected"], *(r["ended"] for r in audit.get("diskReads", []))]) - (max(offsets) - min(offsets)):
        raise ValueError("The readable frame predates native selection or completion of the requested disk read")

    return {"timestampBasis": "original stream PTS", "movieSHA256": hashlib.sha256(movie.read_bytes()).hexdigest(), "rotation": rotation or "none",
            "touchAndClock": audit, "firstRecordingTimeByCode": pulses,
            "calibrationOffsetSeconds": offset, "calibrationOffsetRangeMS": ms(max(offsets) - min(offsets)),
            "selectionAfterTouchUpMS": ms(audit["selected"] - audit["up"]),
            "firstObservedReadableAfterTouchUpMS": ms(first - lift),
            "firstObservedReadableAfterSelectionMS": ms(first - offset - audit["selected"]),
            "firstReadableAfterLiftRangeOverTransitionsMS": [ms(first - audit["up"] - max(offsets)),
                                                            ms(first - audit["up"] - min(offsets))],
            "firstReadableAfterLiftRangeOverAllAnchorsMS": [ms(first - audit["up"] - max(all_offsets.values())),
                                                           ms(first - audit["up"] - min(all_offsets.values()))],
            "previousRecordedFrameAfterTouchUpMS": ms(observations[-2]["recordingSeconds"] - lift) if len(observations) > 1 else None,
            "openingFrames": observations}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachments", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.write_text(json.dumps(measure(args.attachments), indent=2) + "\n")
