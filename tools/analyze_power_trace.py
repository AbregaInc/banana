#!/usr/bin/env python3
"""Summarize xctrace Power Profiler XML exports without third-party dependencies."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path
import xml.etree.ElementTree as ET


NUMERIC_INTEGER_TAGS = {
    "start-time",
    "duration",
    "uint64",
    "uint32",
    "size-in-bytes",
    "display-brightness",
}
NUMERIC_FLOAT_TAGS = {
    "percent-per-hour",
    "fixed-decimal",
    "subsystem-power-impact",
}


def exported_rows(path: Path):
    root = ET.parse(path).getroot()
    references: dict[str, object] = {}

    def value(element: ET.Element):
        reference = element.attrib.get("ref")
        if reference is not None:
            return references[reference]
        if len(element):
            parsed: object = tuple(value(child) for child in element)
        else:
            text = (element.text or "").strip()
            if element.tag in NUMERIC_INTEGER_TAGS:
                try:
                    parsed = int(text)
                except ValueError:
                    parsed = text
            elif element.tag in NUMERIC_FLOAT_TAGS:
                try:
                    parsed = float(text)
                except ValueError:
                    parsed = text
            elif element.tag == "sentinel":
                parsed = None
            else:
                parsed = text
        identifier = element.attrib.get("id")
        if identifier is not None:
            references[identifier] = parsed
        return parsed

    for row in root.findall(".//row"):
        yield [value(element) for element in row]


def clipped_seconds(start: int, duration: int, lower: int, upper: int) -> float:
    return max(0, min(start + duration, upper) - max(start, lower)) / 1_000_000_000


def system_summary(rows, lower: int, upper: int):
    seconds = modeled_points = display_seconds = 0.0
    display_power_seconds = brightness_seconds = 0.0
    for start, duration, percent_per_hour, display_power, _apl, brightness in rows:
        overlap = clipped_seconds(start, duration, lower, upper)
        if overlap <= 0:
            continue
        rate = float(percent_per_hour or 0)
        seconds += overlap
        modeled_points += rate * overlap / 3_600
        display_power_seconds += float(display_power or 0) * overlap
        brightness_seconds += float(brightness or 0) * overlap
        if float(display_power or 0) > 0 or float(brightness or 0) > 0:
            display_seconds += overlap
    return {
        "coveredSeconds": seconds,
        "modeledBatteryPercentagePoints": modeled_points,
        "weightedBatteryPercentagePointsPerHour": (
            modeled_points / (seconds / 3_600) if seconds else 0
        ),
        "displayActiveSeconds": display_seconds,
        "weightedDisplayPower": display_power_seconds / seconds if seconds else 0,
        "weightedDisplayBrightness": brightness_seconds / seconds if seconds else 0,
    }


def display_bouts(rows, lower: int, upper: int):
    bouts: list[list[int]] = []
    for start, duration, _rate, display_power, _apl, brightness in rows:
        clipped_start = max(start, lower)
        clipped_end = min(start + duration, upper)
        if clipped_end <= clipped_start:
            continue
        if not (float(display_power or 0) > 0 or float(brightness or 0) > 0):
            continue
        if bouts and clipped_start - bouts[-1][1] < 2_000_000_000:
            bouts[-1][1] = max(bouts[-1][1], clipped_end)
        else:
            bouts.append([clipped_start, clipped_end])
    return [
        {
            "traceStartSeconds": start / 1_000_000_000,
            "durationSeconds": (end - start) / 1_000_000_000,
        }
        for start, end in bouts
    ]


def process_summary(rows, process_name: str, phases):
    result = {}
    for phase in phases:
        kinds = defaultdict(lambda: {
            "coveredSeconds": 0.0,
            "cpuInstructions": 0,
            "wifiReceivedBytes": 0,
            "wifiTransmittedBytes": 0,
            "cellularReceivedBytes": 0,
            "cellularTransmittedBytes": 0,
            "weightedCPUImpact": 0.0,
            "weightedGPUImpact": 0.0,
            "weightedDisplayImpact": 0.0,
            "weightedNetworkingImpact": 0.0,
            "nonzeroInstructionRows": 0,
        })
        for row in rows:
            (start, duration, _process, name, cpu, display, instructions, gpu,
             network, wifi_rx, wifi_tx, cell_rx, cell_tx, kind) = row
            if name != process_name:
                continue
            overlap = clipped_seconds(start, duration, phase["startNanoseconds"], phase["endNanoseconds"])
            if overlap <= 0:
                continue
            fraction = overlap / (duration / 1_000_000_000)
            summary = kinds[int(kind)]
            summary["coveredSeconds"] += overlap
            summary["cpuInstructions"] += int((instructions or 0) * fraction)
            summary["wifiReceivedBytes"] += int((wifi_rx or 0) * fraction)
            summary["wifiTransmittedBytes"] += int((wifi_tx or 0) * fraction)
            summary["cellularReceivedBytes"] += int((cell_rx or 0) * fraction)
            summary["cellularTransmittedBytes"] += int((cell_tx or 0) * fraction)
            summary["weightedCPUImpact"] += float(cpu or 0) * overlap
            summary["weightedGPUImpact"] += float(gpu or 0) * overlap
            summary["weightedDisplayImpact"] += float(display or 0) * overlap
            summary["weightedNetworkingImpact"] += float(network or 0) * overlap
            if (instructions or 0) > 0:
                summary["nonzeroInstructionRows"] += 1
        normalized = {}
        for kind, summary in kinds.items():
            seconds = summary["coveredSeconds"]
            for key in (
                "weightedCPUImpact",
                "weightedGPUImpact",
                "weightedDisplayImpact",
                "weightedNetworkingImpact",
            ):
                summary[key] = summary[key] / seconds if seconds else 0
            normalized[str(kind)] = summary
        result[phase["label"]] = normalized
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tables", type=Path, required=True)
    parser.add_argument("--run", type=Path)
    parser.add_argument("--process", default="Banana")
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()

    lifecycle_rows = list(exported_rows(arguments.tables / "ProcessLifecycleChange.xml"))
    state_counts: Counter[str] = Counter()
    phases = []
    for start, duration, _process, state in lifecycle_rows:
        state_counts[state] += 1
        phases.append({
            "label": f"{state.lower()}.{state_counts[state]}",
            "state": state,
            "startNanoseconds": start,
            "endNanoseconds": start + duration,
            "durationSeconds": duration / 1_000_000_000,
        })

    system_rows = list(exported_rows(arguments.tables / "SystemPowerLevel.xml"))
    process_rows = list(exported_rows(arguments.tables / "ProcessSubsystemPowerImpact.xml"))
    trace_end = max(start + duration for start, duration, *_ in system_rows)
    system = {"wholeTrace": system_summary(system_rows, 0, trace_end)}
    for phase in phases:
        system[phase["label"]] = system_summary(
            system_rows,
            phase["startNanoseconds"],
            phase["endNanoseconds"],
        )
    suspended = next((phase for phase in phases if phase["state"] == "Suspended"), None)
    if suspended:
        system["suspendedDisplayBouts"] = display_bouts(
            system_rows,
            suspended["startNanoseconds"],
            suspended["endNanoseconds"],
        )

    analysis = {
        "schemaVersion": 1,
        "process": arguments.process,
        "traceDurationSeconds": trace_end / 1_000_000_000,
        "lifecycle": phases,
        "systemPower": system,
        "processSubsystemPower": process_summary(process_rows, arguments.process, phases),
        "caveats": [
            "SystemPowerLevel is whole-device modeled power, not app-attributed battery drain.",
            "ProcessSubsystemPowerImpact is Apple's attribution model; lifecycle state and app task counters are stronger evidence of whether the process executed while locked.",
        ],
    }
    if arguments.run:
        manifest_path = arguments.run / "manifest.json"
        result_path = arguments.run / "result.json"
        if manifest_path.exists():
            analysis["appManifest"] = json.loads(manifest_path.read_text())
        if result_path.exists():
            analysis["appResult"] = json.loads(result_path.read_text())

    encoded = json.dumps(analysis, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
