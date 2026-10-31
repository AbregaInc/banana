#!/usr/bin/env python3
"""Bundle the complete licenses from the exact SwiftPM revisions used by Banana."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def render(resolved, checkouts):
    pins = json.loads(resolved.read_text())["pins"]
    directories = {p.name.casefold(): p for p in checkouts.iterdir() if p.is_dir()}
    sections = ["Third-party software notices\n============================\n\n"
                "The following license texts accompany the pinned software packages used by Banana.\n"]
    for pin in sorted(pins, key=lambda p: p["identity"]):
        folder = directories.get(pin["identity"].casefold())
        if folder is None:
            raise RuntimeError("Missing pinned checkout: " + pin["identity"])
        licenses = sorted(p for p in folder.iterdir() if p.is_file() and p.name.upper().startswith(("LICENSE", "LICENCE", "NOTICE", "COPYING")))
        if not licenses:
            raise RuntimeError("Missing license text: " + pin["identity"])
        revision = pin["state"]["revision"]
        sections.append(f"\n\n{folder.name}\n{'=' * len(folder.name)}\n\nSource: {pin['location']}\nRevision: {revision}\n"
                        + (f"Version: {pin['state']['version']}\n" if pin["state"].get("version") else ""))
        for license_file in licenses:
            sections.append(f"\n{license_file.name}\n{'-' * len(license_file.name)}\n\n{license_file.read_text().rstrip()}\n")
    return "".join(sections)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resolved", type=Path, default=ROOT / "Banana.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    parser.add_argument("--checkouts", type=Path, default=ROOT / ".build/ios-prod/SourcePackages/checkouts")
    parser.add_argument("--output", type=Path, default=ROOT / "Banana/Resources/ThirdPartyLicenses.txt")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = render(args.resolved, args.checkouts)
    if args.check:
        if args.output.read_text() != expected:
            raise SystemExit("Bundled third-party notices differ from the pinned licenses.")
        print("Bundled notices match every pinned SwiftPM license.")
    else:
        args.output.write_text(expected)
        print("Updated", args.output)
