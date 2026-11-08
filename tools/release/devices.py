#!/usr/bin/env python3
"""Find the owner's iPhone and iPad through devicectl and run an install on each, waiting out a
locked or unreachable device instead of failing the rollout.

    devices.py list                                   # physical iPhones and iPads, their state
    devices.py find phone                             # the identifier for a role
    devices.py run phone ipad -- CMD ... {id} ...     # wait, run CMD per device, retry

Roles are kinds of device, never ids: `phone` is a physical iPhone, `ipad` a physical iPad. When
devicectl lists more than one of a kind, BANANA_RELEASE_PHONE_MODEL / BANANA_RELEASE_PAD_MODEL
(a productType such as iPhone16,2, kept in ~/.config/banana/distribution.env) picks one.

A device is ready when it is paired and its tunnel is not "unavailable" (devicectl's table shows
"available (paired)" or "connected"; note that "unavailable" contains "available", so the JSON is
read, not the table). A failure that reads like a locked or unreachable device waits and retries;
any other failure is reported at once. Exit status: 0 when every role succeeded.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

KINDS = {"phone": ("iPhone", "BANANA_RELEASE_PHONE_MODEL"), "ipad": ("iPad", "BANANA_RELEASE_PAD_MODEL")}
# Words in devicectl/xcodebuild output that mean "try again when the device is back".
TRANSIENT = ("locked", "passcode", "unavailable", "not connected", "disconnected", "timed out",
             "timeout", "tunnel", "could not connect", "connection", "not reachable", "unreachable",
             "kAMDMobileImageMounter", "busy", "0xe8000065", "DeviceNotAvailable")


def inventory():
    with tempfile.NamedTemporaryFile(suffix=".json") as out:
        subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", out.name],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False, timeout=120)
        try:
            return json.load(open(out.name)).get("result", {}).get("devices", [])
        except (json.JSONDecodeError, OSError):
            return []


def physical(devices):
    return [d for d in devices if d.get("hardwareProperties", {}).get("reality") == "physical"
            and d.get("hardwareProperties", {}).get("deviceType") in ("iPhone", "iPad")]


def state(device):
    c = device.get("connectionProperties", {})
    if c.get("pairingState") != "paired":
        return "unpaired"
    tunnel = c.get("tunnelState", "unavailable")
    return "unavailable" if tunnel == "unavailable" else ("connected" if tunnel == "connected" else "available (paired)")


def ready(device):
    return state(device) in ("connected", "available (paired)")


def describe(device):
    h = device.get("hardwareProperties", {})
    return f"{h.get('deviceType')} {h.get('productType')} [{state(device)}]"


def find(role, devices):
    kind, env = KINDS[role]
    matches = [d for d in physical(devices) if d["hardwareProperties"].get("deviceType") == kind]
    model = os.environ.get(env, "").strip()
    if model:
        matches = [d for d in matches if d["hardwareProperties"].get("productType") == model]
    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise LookupError(f"no paired {kind}{' ' + model if model else ''} is listed by devicectl")
    raise LookupError(f"{len(matches)} {kind}s are listed ({', '.join(describe(d) for d in matches)}); "
                      f"set {env} to the one that gets release installs")


def wait_ready(role, timeout, poll):
    deadline = time.time() + timeout
    said = 0.0
    while True:
        device = find(role, inventory())
        if ready(device):
            return device
        if time.time() >= deadline:
            raise TimeoutError(f"{role}: {describe(device)} did not become available in {timeout}s "
                               "(unlock it, keep it on the same network or cable, and run the step again)")
        if time.time() - said > 60:
            print(f"  {role}: {describe(device)}; waiting for it to be unlocked and reachable", flush=True)
            said = time.time()
        time.sleep(poll)


def run_on(role, command, args, log):
    for attempt in range(1, args.retries + 1):
        try:
            device = wait_ready(role, args.wait, args.poll)
        except (LookupError, TimeoutError) as error:
            return f"FAILED {role}: {error}"
        argv = [part.replace("{id}", device["identifier"]) for part in command]
        print(f"  {role}: {describe(device)}: attempt {attempt}", flush=True)
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        log.write(f"--- {role} attempt {attempt}: exit {result.returncode}\n{result.stdout}\n")
        log.flush()
        if result.returncode == 0:
            return f"ok     {role}: {describe(device)}"
        output = result.stdout.lower()
        transient = [word for word in TRANSIENT if word.lower() in output]
        if not transient:
            tail = " | ".join(result.stdout.strip().splitlines()[-3:])
            return f"FAILED {role}: exit {result.returncode}: {tail[:400]}"
        print(f"  {role}: looks locked or unreachable ({transient[0]}); retrying in {args.poll}s", flush=True)
        time.sleep(args.poll)
    return f"FAILED {role}: still locked or unreachable after {args.retries} attempts"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("list")
    f = sub.add_parser("find"); f.add_argument("role", choices=KINDS)
    r = sub.add_parser("run")
    r.add_argument("roles", nargs="+", choices=KINDS)
    r.add_argument("--wait", type=int, default=int(os.environ.get("BANANA_DEVICE_WAIT", 600)),
                   help="seconds to wait for each device to be ready (default 600)")
    r.add_argument("--retries", type=int, default=3)
    r.add_argument("--poll", type=int, default=20)
    r.add_argument("--log", default="-")
    argv = sys.argv[1:]
    command = []
    if "--" in argv:
        command = argv[argv.index("--") + 1:]
        argv = argv[:argv.index("--")]
    args = parser.parse_args(argv)
    if args.action == "list":
        for d in physical(inventory()):
            print(describe(d))
        return 0
    if args.action == "find":
        try:
            print(find(args.role, inventory())["identifier"])
            return 0
        except LookupError as error:
            print(error, file=sys.stderr)
            return 1
    if not command:
        parser.error("run needs a command after --, with {id} where the device goes")
    log = sys.stdout if args.log == "-" else open(args.log, "a")
    results = [run_on(role, command, args, log) for role in args.roles]
    for line in results:
        print(line)
    return 0 if all(line.startswith("ok") for line in results) else 1


if __name__ == "__main__":
    sys.exit(main())
