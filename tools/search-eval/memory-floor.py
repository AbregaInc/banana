"""Compare minimum and standard one-day stress loads on the same stock Simulator app."""
import argparse
import json
import plistlib
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True, help="Stock iPhone Simulator UDID")
parser.add_argument("--app", required=True, type=Path)
parser.add_argument("--out", required=True, type=Path)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
bundle = plistlib.loads((args.app / "Info.plist").read_bytes())["CFBundleIdentifier"]


def sim(*words, check=True):
    return subprocess.run(["xcrun", "simctl", *words], check=check, text=True, capture_output=True).stdout.strip()


sim("boot", args.device, check=False)
sim("bootstatus", args.device, "-b")
sim("install", args.device, str(args.app.resolve()))
directory = Path(sim("get_app_container", args.device, bundle, "data"))
report = directory / "Documents/scale-stress.json"
samples = []
for trial, order in enumerate(((True, False), (False, True))):
    for small in order:
        sim("terminate", args.device, bundle, check=False)
        report.unlink(missing_ok=True)
        launch = ["--notes", "--stress-days", "1", "--stress-measure", "--disable-icloud", "--mail-fresh",
                  "-onboardingCompleted", "YES", "-planMode", "week", "-mobileWeekLayout", "calendar"]
        if small:
            launch += ["--stress-notes", "1", "--stress-podcasts", "0"]
        sim("launch", args.device, bundle, *launch)
        try:
            until = time.monotonic() + 100
            while not report.exists() and time.monotonic() < until:
                time.sleep(0.25)
            result = json.loads(report.read_text())
            expected = (1, 0) if small else (1000, 10000)
            if (result["notes"], result["episodes"]) != expected:
                raise ValueError("Unexpected fixture size")
            samples.append(dict(trial=trial, small=small, **{key: result[key] for key in
                           ("residentMB", "notes", "episodes", "emails", "events", "podcasts")}))
            (args.out / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")
        finally:
            sim("terminate", args.device, bundle, check=False)
