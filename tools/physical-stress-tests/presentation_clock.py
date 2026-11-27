"""Calibrate a physical XCTest movie to native touch uptime using the fixture's colored squares."""
import json
import subprocess
from statistics import median


def capture(command, **kwargs):
    return subprocess.check_output(command, **kwargs)


def current_sequence(observed):
    # XCTest may start with the previous process's last screen, still displaying code seven.
    # A genuine calibration increases from zero to seven. Multiple credible sequences in
    # the same movie would leave its launch ambiguous.
    runs = []
    current = {}
    for code, timestamp in observed:
        if current and code < next(reversed(current)):
            runs.append(current)
            current = {}
        current.setdefault(code, timestamp)
    runs.append(current)
    credible = [run for run in runs if sum(code - 1 in run for code in run) >= 3]
    if len(credible) > 1:
        raise ValueError("Multiple ordered calibration sequences in one recording")
    return credible[0] if credible else {}


def decode_clock(movie, audit, times, orientation):
    screen_w, screen_h = map(round, audit["window"])
    left, top, width, height = map(round, audit["rect"])
    filters = [orientation] if orientation else []
    filters += [f"scale={screen_w}:{screen_h}", "format=rgb24", f"crop={width}:{height}:{left}:{top}"]
    raw = capture(["ffmpeg", "-nostdin", "-v", "error", "-threads", "2", "-noautorotate", "-i", movie,
                   "-vf", ",".join(filters), "-fps_mode", "passthrough", "-enc_time_base", "filter", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    stride = width * height * 3
    if len(raw) != len(times) * stride:
        raise ValueError("Decoded frame count differs from the recording timestamps")
    observed = []
    for index, timestamp in enumerate(times):
        colors = []
        for square in range(5):
            pixel = index * stride + 3 * ((height // 2) * width + round((square + .5) * width / 5))
            colors.append(tuple(raw[pixel:pixel + 3]))
        red, green, blue = colors[0]
        end_red, end_green, end_blue = colors[-1]
        if min(red, blue) - green < 65 or min(end_green, end_blue) - end_red < 65:
            continue
        cells = [sum(color) / 3 for color in colors[1:4]]
        if any(65 < value < 190 for value in cells):
            continue
        code = sum(1 << bit for bit, value in enumerate(cells) if value >= 190)
        if not observed or code != observed[-1][0]:
            observed.append((code, timestamp))
    return current_sequence(observed)


def align(movie, audit):
    info = json.loads(capture(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
                               "-show_entries", "stream=width,height:frame=best_effort_timestamp_time", "-of", "json", movie]))
    times = [float(frame["best_effort_timestamp_time"]) for frame in info["frames"]]
    stream = info["streams"][0]
    same_axis = (stream["width"] > stream["height"]) == (audit["window"][0] > audit["window"][1])
    rotations = ["", "hflip,vflip"] if same_axis else ["transpose=clock", "transpose=cclock"]
    choices = [(decode_clock(movie, audit, times, rotation), rotation) for rotation in rotations]
    pulses, rotation = max(choices, key=lambda item: len(item[0]))
    if len(pulses) < 4 or list(pulses) != sorted(pulses):
        raise ValueError(f"Fewer than four ordered calibration states recorded: {pulses}")
    all_offsets = {int(code): pulses[int(code)] - target for code, target, _ in audit["pulses"] if int(code) in pulses}
    # The first code may arrive while XCTest is still recording the launch transition.
    # A color change between two recorded codes identifies a transition on an existing layer.
    offsets = [value for code, value in all_offsets.items() if code - 1 in pulses]
    if len(offsets) < 3:
        raise ValueError("Fewer than three transitions between observed calibration codes")
    offset = median(offsets)
    return pulses, rotation, offset, offsets, all_offsets

