#!/usr/bin/env python3
"""Locate the first recorded movement of the event grid after each calibrated Day drag."""
import argparse
from bisect import bisect_left
from datetime import date
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.fft import irfft, next_fast_len, rfft

from presentation_clock import align, capture


def translation(reference, frame):
    """Horizontal displacement of the same visible text, using overlapping vertical edges."""
    left = np.diff(reference.astype(float), axis=1)[::2]
    right = np.diff(frame.astype(float), axis=1)[::2]
    width = left.shape[1]
    length = next_fast_len(2 * width)
    correlation = irfft((rfft(right, n=length, axis=1) * rfft(left, n=length, axis=1).conj()).sum(axis=0), length)
    offsets = np.arange(-round(0.6 * width), round(0.6 * width) + 1)
    begin = np.maximum(0, -offsets)
    end = np.minimum(width, width - offsets)
    energy_a = np.r_[0, np.cumsum((left * left).sum(axis=0))]
    energy_b = np.r_[0, np.cumsum((right * right).sum(axis=0))]
    denominator = np.sqrt(np.maximum(0, (energy_a[end] - energy_a[begin]) *
                                      (energy_b[end + offsets] - energy_b[begin + offsets])))
    scores = correlation[offsets % length] / np.maximum(denominator, 1e-8)
    best = int(np.argmax(scores))
    lag = int(offsets[best])
    alternate = max(scores[np.abs(offsets - lag) > 3])
    return lag, float(scores[best]), float(scores[best] - alternate)


def motion(movie, times, rotation, before, audit, offset, offsets):
    screen_w, screen_h = map(round, audit["window"])
    # At the centered resting position, x is one Day column wide. Exclude the fixed hour ruler.
    x = round(before["windowX"] + before["width"] - before["x"] + 8)
    y = round(before["windowY"] + before["height"] * 0.12)
    width = round(before["windowX"] + before["width"] - 8) - x
    height = round(before["height"] * 0.76)
    down = audit["down"] + offset
    contact = audit["contact"]
    first_move = next(p[0] for p in contact if abs(p[1] - contact[0][1]) >= 1)
    crosses_slop = next(p[0] for p in contact if abs(p[1] - contact[0][1]) >= 8)
    direction = np.sign(contact[-1][1] - contact[0][1])
    first = max(0, bisect_left(times, down - 0.04) - 1)
    last = min(len(times) - 1, bisect_left(times, down + 0.45))
    frame_times = times[first:last + 1]
    sample_width = 320
    sample_height = max(2, round(sample_width * height / width))
    filters = [rotation] if rotation else []
    filters += [f"select=between(n\\,{first}\\,{last})", f"scale={screen_w}:{screen_h}",
                f"crop={width}:{height}:{x}:{y}", f"scale={sample_width}:{sample_height}", "format=gray"]
    raw = capture(["ffmpeg", "-nostdin", "-v", "error", "-threads", "2", "-noautorotate", "-i", movie,
                   "-vf", ",".join(filters), "-fps_mode", "passthrough", "-enc_time_base", "filter",
                   "-f", "rawvideo", "-pix_fmt", "gray", "-"])
    images = np.frombuffer(raw, dtype=np.uint8).reshape(-1, sample_height, sample_width)
    if len(images) != len(frame_times) or frame_times[0] >= down:
        raise ValueError("The recording did not bracket the drag start")
    result = []
    for ts, image in zip(frame_times, images):
        lag, score, margin = translation(images[0], image)
        points = lag * width / sample_width
        result.append({"movieSeconds": ts, "points": round(points, 2), "correlation": round(score, 3),
                       "margin": round(margin, 3), "reliable": score >= 0.62 and margin >= 0.08})
    sample = next((r for r in result if r["movieSeconds"] >= down and r["reliable"]
                   and direction * r["points"] >= 2), None)
    row = {"contact": contact, "down": audit["down"], "up": audit["up"], "firstMoved": first_move,
           "firstEightPoints": crosses_slop, "upDirection": int(direction), "crop": [x, y, width, height],
           "sampledFrames": result}
    if sample:
        visible = sample["movieSeconds"]
        previous = [r["movieSeconds"] for r in result if r["movieSeconds"] < visible and r["reliable"]
                    and abs(r["points"]) < 2]
        def delta(ts, native):
            return round(1000 * (ts - native - offset), 2)
        row.update(firstVisibleShift=sample, firstShiftAfterTouchDownMS=delta(visible, audit["down"]),
                   firstShiftAfterFirstMovedMS=delta(visible, first_move),
                   firstShiftAfterEightPointsMS=delta(visible, crosses_slop),
                   previousStationaryFrameAfterFirstMovedMS=delta(previous[-1], first_move) if previous else None,
                   firstShiftAfterFirstMovedOverCalibrationMS=[round(1000 * (visible - first_move - v), 2)
                                                              for v in [max(offsets), min(offsets)]])
    return row


def measure(folder):
    attachments = json.loads((folder / "manifest.json").read_text())[0]["attachments"]
    video = next(a for a in attachments if a["suggestedHumanReadableName"].startswith("Screen Recording"))
    movie = folder / video["exportedFileName"]
    records = sorted((a for a in attachments if a["suggestedHumanReadableName"].startswith("Calendar input and recording clock")),
                     key=lambda a: a["timestamp"])
    if not records:
        raise ValueError("No calendar touch and geometry records")
    gestures = [json.loads((folder / a["exportedFileName"]).read_text()) for a in records]
    audit = gestures[0][2]
    pulses, rotation, offset, offsets, _ = align(movie, audit)
    info = json.loads(capture(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
                               "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", movie]))
    times = [float(f["best_effort_timestamp_time"]) for f in info["frames"]]
    results = []
    for before, after, input_state in gestures:
        if input_state["pulses"] != audit["pulses"]:
            raise ValueError("A gesture belongs to a different calibration")
        row = motion(movie, times, rotation, before, input_state, offset, offsets)
        date_delta = (date.fromisoformat(after["page"]) - date.fromisoformat(before["page"])).days
        if date_delta != -row["upDirection"]:
            raise ValueError("The settled date disagrees with the direction of the delivered finger movement")
        down, up = row["down"], row["up"]
        first_input = row["firstMoved"]
        moved_contact = next(point for point in row["contact"] if point[0] == first_input)
        if len(moved_contact) > 3:
            row["firstMovementDeliveryAfterTouchTimestampMS"] = round(1000 * (moved_contact[3] - first_input), 2)
        began = next((item["time"] for item in after.get("dayGestureHistory", [])
                      if item["phase"] == "began" and down <= item["time"] <= up), None)
        changed = next((point[0] for point in after.get("dayMotion", [])
                        if down <= point[0] <= up and date_delta * (point[2] - before["x"]) >= 2), None)
        if began is not None:
            row["nativeDragBeganAfterFirstMovedMS"] = round(1000 * (began - first_input), 2)
        if changed is not None:
            row["firstViewportChangeAfterFirstMovedMS"] = round(1000 * (changed - first_input), 2)
            if "firstVisibleShift" in row:
                row["firstSampledShiftAfterViewportCallbackMS"] = round(
                    1000 * (row["firstVisibleShift"]["movieSeconds"] - changed - offset), 2)
        row.update(dateDelta=date_delta, beforeDate=before["page"], afterDate=after["page"], rulerY=[before["y"], after["y"]])
        results.append(row)
    return {"movieSHA256": hashlib.file_digest(movie.open("rb"), "sha256").hexdigest(),
            "recordingRotation": rotation or "none", "clockStates": audit["pulses"], "firstRecordingTimeByCode": pulses,
            "offsetSeconds": offset, "calibrationSpreadMS": round(1000 * (max(offsets) - min(offsets)), 2),
            "gestures": results}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachments", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.write_text(json.dumps(measure(args.attachments), indent=2) + "\n")
