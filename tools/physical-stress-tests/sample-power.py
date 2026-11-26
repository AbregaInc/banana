#!/usr/bin/env python3
"""Sample whole-device power on a paired iPad while a Mail or Calendar scenario runs."""
import argparse
import asyncio
import json
import time
from datetime import datetime, timezone
from pathlib import Path


def power_fields(source):
    def signed(value):
        # Some IORegistry versions encode a negative battery current as an unsigned 64-bit value.
        return value - (1 << 64) if value >= 1 << 63 else value

    fields = {}
    for key in ("CurrentCapacity", "Voltage", "InstantAmperage", "ExternalConnected",
                "IsCharging", "FullyCharged", "Temperature"):
        value = source.get(key)
        if isinstance(value, (int, float)):
            fields[key] = signed(value) if key == "InstantAmperage" else value
    adapter = source.get("AdapterDetails")
    if isinstance(adapter, dict) and isinstance(adapter.get("Watts"), (int, float)):
        fields["adapterWatts"] = adapter["Watts"]
    telemetry = source.get("PowerTelemetryData")
    if not isinstance(telemetry, dict):
        return fields
    for key in ("SystemPowerIn", "SystemLoad", "BatteryPower"):
        value = telemetry.get(key)
        if isinstance(value, (int, float)):
            fields[key] = signed(value) if key == "BatteryPower" else value
    return fields


async def sample(device_id):
    from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
    from pymobiledevice3.services.diagnostics import DiagnosticsService

    async with NativeRemotedTunnel(device_id) as device:
        async with DiagnosticsService(device) as diagnostics:
            return power_fields(await diagnostics.get_battery() or {})


async def record(args):
    start = time.monotonic()
    deadline = start + args.seconds
    available = False
    with args.out.open("x", encoding="utf-8") as output:
        while time.monotonic() < deadline:
            at = time.monotonic()
            row = {"utc": datetime.now(timezone.utc).isoformat(), "elapsedSeconds": round(at - start, 3)}
            try:
                fields = await asyncio.wait_for(sample(args.device), timeout=min(30, deadline - at))
                if fields:
                    available = True
                    row.update(fields)
                else:
                    row["error"] = "Battery telemetry unavailable"
            except ImportError:
                raise
            except Exception as error:
                # Error messages from the transport can contain the owner's device identifier.
                row["error"] = type(error).__name__
            print(json.dumps(row, sort_keys=True), file=output, flush=True)
            await asyncio.sleep(max(0, min(at + args.interval, deadline) - time.monotonic()))
    return available


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="paired device UDID")
    parser.add_argument("--seconds", type=int, required=True)
    parser.add_argument("--interval", type=int, default=60, help="seconds between reads")
    parser.add_argument("--out", type=Path, required=True, help="new JSONL file")
    args = parser.parse_args()
    if min(args.seconds, args.interval) <= 0:
        parser.error("duration and interval must be positive")
    try:
        return 0 if asyncio.run(record(args)) else 1
    except ModuleNotFoundError as error:
        parser.exit(2, f"Install the documented pymobiledevice3 dependency. Missing {error.name}.\n")


if __name__ == "__main__":
    raise SystemExit(main())
