#!/usr/bin/env python3
"""Measure when the grid and ruler change in an exported XCTest gesture recording."""
import argparse
from bisect import bisect_left
from io import BytesIO
import json
import plistlib
from pathlib import Path
import subprocess



def horizontal_drags(attachments, folder, recording_start, landscape):
    intervals = []
    for attachment in attachments:
        if not attachment["suggestedHumanReadableName"].startswith("Synthesized Event"):
            continue
        archive = plistlib.loads((folder / attachment["exportedFileName"]).read_bytes())["$objects"]

        def value(field):
            return archive[field.data] if isinstance(field, plistlib.UID) else field

        points = [(value(entry["offset"]), value(entry["coordinate.x"]), value(entry["coordinate.y"]))
                  for entry in archive if isinstance(entry, dict) and "coordinate.x" in entry]
        # XCTest archives three points for a single continuous press / drag / lift.
        if len(points) != 3:
            continue
        start, end = points[0], points[-1]
        # The archived touch stream uses the device's native portrait coordinates,
        # independently of the orientation in which XCTest encoded the movie.
        horizontal, vertical = (2, 1) if landscape else (1, 2)
        distance = abs(start[horizontal] - end[horizontal])
        if distance <= 40 or distance <= 2 * abs(start[vertical] - end[vertical]) or end[0] <= 0.24:
            continue
        end_time = attachment["timestamp"] - recording_start
        intervals.append((end_time - end[0], end_time, distance))
    return sorted(intervals)


def recording_frames(movie, rotation):
    from PIL import Image

    frame_info = subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
        "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", movie])
    times = [float(frame["best_effort_timestamp_time"]) for frame in json.loads(frame_info)["frames"]]
    # Keep every native timestamp. A constant-rate conversion would invent intermediate frames.
    jpeg = subprocess.check_output([
        "ffmpeg", "-nostdin", "-loglevel", "error", "-threads", "2", "-i", movie,
        "-vf", "scale=384:-2", "-fps_mode", "passthrough", "-enc_time_base", "filter", "-f", "image2pipe",
        "-vcodec", "mjpeg", "-q:v", "3", "-"])
    frames = [Image.open(BytesIO(b"\xff\xd8" + data)).convert("L") for data in jpeg.split(b"\xff\xd8")[1:]]
    if len(times) != len(frames) or not frames:
        raise ValueError("Video frames and presentation timestamps do not match")
    if rotation != "none":
        transform = Image.Transpose.ROTATE_270 if rotation == "clockwise" else Image.Transpose.ROTATE_90
        frames = [frame.transpose(transform) for frame in frames]
    return times, frames


def changes(frames, box):
    import numpy as np

    previous = None
    values = []
    for frame in frames:
        region = np.asarray(frame.crop(box), dtype=np.int16)
        values.append(0.0 if previous is None else float(np.abs(region - previous).mean()))
        previous = region
    return values


def examine(times, regions, start, end, distance, next_start=None):
    windows = {}
    for label, lower, upper in (("duringDrag", start + 0.12, end - 0.12),
                                ("aroundRelease", end - 0.12, end + 0.45)):
        a = bisect_left(times, lower)
        b = bisect_left(times, upper)
        windows[label] = {
            "recordedSamples": b - a,
            "changedSamples": {name: sum(delta >= 1 for delta in values[a:b]) for name, values in regions.items()},
            "maxMeanGrayChange": {name: round(max(values[a:b], default=0), 3) for name, values in regions.items()},
        }
    # The native scroll may continue after the short release window. Truncate before
    # the next input; identical images are routinely omitted from these recordings.
    stop = min(end + 1.5, next_start) if next_start is not None else end + 1.5
    start_index, stop_index = bisect_left(times, end), bisect_left(times, stop)
    last_changes = {}
    for name, values in regions.items():
        timestamps = [times[i] for i in range(start_index, stop_index) if values[i] >= 1]
        last_changes[name] = round(1000 * (max(timestamps) - end), 1) if timestamps else None
    return {"durationSeconds": round(end - start, 3), "horizontalDistancePoints": round(distance, 2),
            "windows": windows, "postReleaseObservationMS": round(1000 * (stop - end), 1),
            "lastRecordedChangeAfterReleaseMS": last_changes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachments", type=Path, help="xcresulttool export attachments for one test")
    parser.add_argument("--rotation", choices=("none", "clockwise", "counterclockwise"), default="none",
                        help="Additional quarter turn to make the calendar upright during the drag")
    parser.add_argument("--window", nargs=2, type=float, metavar=("W", "H"))
    parser.add_argument("--viewport", nargs=4, type=float, metavar=("X", "Y", "W", "H"))
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    records = json.loads((args.attachments / "manifest.json").read_text())
    if len(records) != 1:
        parser.error("Export one test at a time")
    attachments = records[0]["attachments"]

    def matching(prefix):
        return [entry for entry in attachments if entry["suggestedHumanReadableName"].startswith(prefix)]

    videos = matching("Screen Recording")
    if len(videos) != 1:
        parser.error("Expected one screen recording")
    reports = matching("Day swipe geometry and redraw counts")
    state = json.loads((args.attachments / reports[-1]["exportedFileName"]).read_text())[0] if reports else {}
    window = args.window or [state.get("windowWidth"), state.get("windowHeight")]
    viewport = args.viewport or [state.get(key) for key in ("windowX", "windowY", "width", "height")]
    if None in (*window, *viewport):
        parser.error("Earlier tests require --window and --viewport from the matching fixture")
    times, frames = recording_frames(args.attachments / videos[0]["exportedFileName"], args.rotation)
    if abs((frames[0].width / frames[0].height) / (window[0] / window[1]) - 1) > 0.04:
        parser.error("The video and window orientations disagree. Inspect a gesture frame and specify --rotation")
    x, y, width, height = viewport
    scale = frames[0].width / window[0]

    def box(left, right):
        return tuple(round(coord * scale) for coord in (x + left, y + height * 0.12, x + right, y + height * 0.87))

    regions = {"events": changes(frames, box(min(80, width * 0.20), width * 0.96)),
               "ruler": changes(frames, box(3, 35))}
    intervals = horizontal_drags(attachments, args.attachments, videos[0]["timestamp"], window[0] > window[1])
    if not intervals:
        parser.error("No matching horizontal drag in the exported attachments")
    result = {"scope": "Variable-rate XCTest screen recording. Counts are changes above one level of mean gray "
                       "difference between adjacent recorded samples. The estimated drag interval excludes 120 ms "
                       "at each end. This measures recorded movement, not display frame rate or input latency.",
              "windowPoints": window, "viewportPoints": viewport, "rotation": args.rotation,
              "frameCount": len(times), "durationSeconds": times[-1],
              "swipes": [examine(times, regions, *interval, next_start=intervals[i + 1][0] if i + 1 < len(intervals) else None)
                         for i, interval in enumerate(intervals)]}
    with args.out.open("x") as file:
        json.dump(result, file, indent=2)
        file.write("\n")


if __name__ == "__main__":
    main()
