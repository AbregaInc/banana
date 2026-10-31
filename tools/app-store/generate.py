#!/usr/bin/env python3
"""Capture and compose Banana's complete App Store submission package."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import struct
import subprocess
import sys
import time
import wave
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
TOOL = Path(__file__).resolve().parent
MANIFEST = TOOL / "manifest.json"
DERIVED = ROOT / ".build/sim"
MAC_DERIVED = ROOT / ".build/mac-check"
def _bundle_id() -> str:
    """The bundle id the simulator build was made with: yours (Config/Local.xcconfig), else the stand-in."""
    import re
    for name in ("Local.xcconfig", "Base.xcconfig"):
        path = ROOT / "Config" / name
        if path.exists():
            found = re.search(r"^BANANA_BUNDLE_ID\s*=\s*(\S+)", path.read_text(), re.M)
            if found:
                return found.group(1)
    raise SystemExit("BANANA_BUNDLE_ID is not set in Config/")


BUNDLE_ID = _bundle_id()
# Tells the app's sample data this is a marketing capture: a day that reads the same whatever
# the hour of the run, and workouts without the layout tests' deliberately awkward strings.
STORE_CAPTURE = "--store-capture"
WATCH_BUNDLE_ID = BUNDLE_ID + ".watchkitapp"
# The Mac capture runs the Beta variant: see `build_mac`.
MAC_APP = "Banana Beta.app"


def run(command: list[str], *, check: bool = True, capture: bool = False) -> str:
    print("+", " ".join(command))
    result = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    if check and result.returncode:
        if result.stdout:
            print(result.stdout)
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(command)}")
    return result.stdout or ""


def binary_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record_captures(output: Path, platform: str, executable: Path, before: str) -> None:
    if binary_hash(executable) != before:
        raise RuntimeError("The app executable changed during capture; keep the raw images for inspection.")
    path = output / "capture-status.json"
    status = json.loads(path.read_text()) if path.exists() else {"freshPlatforms": {}}
    status.setdefault("freshPlatforms", {})[platform] = {
        "capturedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "binarySHA256": before,
        "sourceNote": "Actual product hash. A provided product need not match the current checkout.",
        "rawSHA256": {p.name: binary_hash(p) for p in sorted((output / "raw" / platform).glob("*.png"))},
    }
    status["submissionReady"] = False
    status["rawCaptureStatus"] = "Fresh captures recorded for: " + ", ".join(sorted(status["freshPlatforms"]))
    status["rawSHA256"] = {str(p.relative_to(output)): binary_hash(p) for p in sorted((output / "raw").rglob("*.png"))}
    path.write_text(json.dumps(status, indent=2) + "\n")


def available_device(name: str) -> str:
    payload = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "-j"], capture=True))
    candidates = [
        device
        for runtime in payload["devices"].values()
        for device in runtime
        if device["name"] == name and device.get("isAvailable", True)
    ]
    if not candidates:
        raise RuntimeError(f"Required simulator is unavailable: {name}")
    return candidates[-1]["udid"]


def boot(udid: str) -> None:
    run(["xcrun", "simctl", "boot", udid], check=False)
    run(["xcrun", "simctl", "bootstatus", udid, "-b"])


def deterministic_status_bar(udid: str) -> None:
    run(
        [
            "xcrun", "simctl", "status_bar", udid, "override",
            "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
            "--wifiBars", "3", "--cellularBars", "4",
        ],
        check=False,
    )


def write_demo_audio(data_container: Path) -> None:
    documents = data_container / "Documents"
    documents.mkdir(parents=True, exist_ok=True)
    destination = documents / "banana-demo.wav"
    rate = 8_000
    duration = 2
    with wave.open(str(destination), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes(struct.pack("<h", 0) * rate * duration)


def build_iphone(udid: str) -> Path:
    run(
        [
            "xcodebuild", "-project", "Banana.xcodeproj", "-scheme", "Banana",
            "-configuration", "Debug", "-destination", f"id={udid}",
            "-derivedDataPath", str(DERIVED), "-jobs", "2",
            "OTHER_SWIFT_FLAGS=$(inherited) -j2", "build",
        ]
    )
    return DERIVED / "Build/Products/Debug-iphonesimulator/Banana.app"


def build_watch(udid: str) -> Path:
    run(
        [
            "xcodebuild", "-project", "Banana.xcodeproj", "-scheme", "BananaWatch",
            "-configuration", "Debug", "-destination", f"id={udid}",
            "-derivedDataPath", str(DERIVED), "-jobs", "2",
            "OTHER_SWIFT_FLAGS=$(inherited) -j2", "build",
        ]
    )
    return DERIVED / "Build/Products/Debug-watchsimulator/BananaWatch.app"


def build_mac() -> Path:
    """The Beta variant, signed. It has its own bundle id and keeps everything it writes in its
    own folder (`AppSupport.directory`), so a capture can never read or change the data of the
    Banana installed on this Mac. This used to build the daily app's own target unsigned, which
    shares that app's identity and its files in ~/Library/Application Support.

    Signing may need the developer portal: pass the App Store Connect key through AUTH_ARGS, as
    for tools/mac-install.sh.
    """
    run(
        [
            "xcodebuild", "-project", "Banana.xcodeproj", "-scheme", "BananaMacBeta",
            "-configuration", "Debug", "ONLY_ACTIVE_ARCH=YES",
            "-derivedDataPath", str(MAC_DERIVED), "-allowProvisioningUpdates",
            *shlex.split(os.environ.get("AUTH_ARGS", "")), "-jobs", "2",
            "OTHER_SWIFT_FLAGS=$(inherited) -j2", "build",
        ]
    )
    return MAC_DERIVED / "Build/Products/Debug" / MAC_APP


def mac_executable(app: Path) -> Path:
    return app / "Contents/MacOS" / app.stem


def mac_process_id(app: Path) -> int:
    executable = mac_executable(app)
    command_prefix = f"{executable} "
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        processes = run(["ps", "-axo", "pid=,command="], capture=True)
        matches = []
        for line in processes.splitlines():
            fields = line.strip().split(maxsplit=1)
            if len(fields) != 2:
                continue
            pid, command = fields
            if command.startswith(command_prefix) and "--ui-audit" in command:
                matches.append(int(pid))
        if matches:
            return max(matches)
        time.sleep(0.25)
    raise RuntimeError(f"Mac capture timed out waiting for {executable}")


def mac_window_id(pid: int, app: Path | None = None) -> str:
    finder = DERIVED / "window_id"
    source = TOOL / "window_id.swift"
    if not finder.exists() or finder.stat().st_mtime < source.stat().st_mtime:
        finder.parent.mkdir(parents=True, exist_ok=True)
        run(["xcrun", "swiftc", str(source), "-o", str(finder)])

    # A minute: the first launch of a freshly built app on a busy Mac has taken longer than 20 s
    # to put its window up, and the run then failed with the window on screen.
    started = time.monotonic()
    deadline = started + 60
    asked_again = False
    while time.monotonic() < deadline:
        identifier = run([str(finder), str(pid)], check=False, capture=True).strip()
        if identifier.isdigit():
            return identifier
        # A Mac app launched while someone is working in another app can come up without being
        # brought forward, and then opens no window at all (9 Oct 2026: three runs in a row waited
        # a minute for a window that never came). Asking the running app to open, the way a click
        # on its Dock icon does, brings one up.
        if app is not None and not asked_again and time.monotonic() - started > 8:
            asked_again = True
            run(["open", str(app)], check=False)
        time.sleep(0.25)
    raise RuntimeError("Mac capture timed out waiting for the Banana window")


def stop_mac_app(app: Path) -> None:
    executable = mac_executable(app)
    pattern = rf"^{re.escape(str(executable))}( |$)"
    run(["pkill", "-TERM", "-f", pattern], check=False)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not run(["pgrep", "-f", pattern], check=False, capture=True).strip():
            return
        time.sleep(0.1)
    run(["pkill", "-KILL", "-f", pattern], check=False)


def settled_screenshot(udid: str, destination: Path, settle: float) -> None:
    """Screenshot after first render, not before it.

    A cold launch right after a fresh install can take longer than the settle window to put
    its first frame up; the capture then lands on the empty window background and every scene
    in the run ships blank. A near-uniform frame is never a real scene, so treat it as
    "not rendered yet", wait, and recapture — and fail loudly rather than emit a blank.
    """
    from PIL import Image, ImageStat

    for attempt in range(4):
        time.sleep(settle * (attempt + 1))
        run(["xcrun", "simctl", "io", udid, "screenshot", "--type=png", str(destination)])
        stddev = ImageStat.Stat(Image.open(destination).convert("L")).stddev[0]
        # A light calendar day with a handful of events measures about 25; an empty window
        # background is in single digits. 30 turned the Plan tab's own Day view away as blank.
        if stddev >= 15:
            return
        print(f"  blank frame (stddev {stddev:.1f}), waiting for first render…")
    raise RuntimeError(f"Capture stayed blank after retries: {destination}")


def capture_ios(manifest: dict, output: Path, skip_build: bool, ios_app: Path | None,
                platform: str, folder: str, udid: str | None = None) -> None:
    """The iPhone set or the iPad set: the same app, another simulator and another canvas."""
    # By name, there can be one per installed iOS version, and the one picked may be a simulator
    # nobody has booted in months. `--ios-udid` names the one to use.
    udid = udid or available_device(manifest["capture"][f"{platform}_device"])
    boot(udid)
    deterministic_status_bar(udid)
    if platform == "ipad":
        # Orca's simulator helper rotates without opening/focusing Simulator.app.
        # The caller must coordinate ownership of this existing simulator first.
        emulator = [os.environ.get("ORCA_CLI_COMMAND", "orca"), "emulator"]
        target = ["--device", udid, "--worktree", "path:" + str(ROOT), "--json"]
        run([*emulator, "attach", *target])
        run([*emulator, "rotate", manifest["capture"]["ipad_orientation"], *target])
    # The sets are light; a simulator left in Dark Mode by something else would mix them.
    run(["xcrun", "simctl", "ui", udid, "appearance", "light"], check=False)
    if ios_app is not None:
        app = ios_app
    elif skip_build:
        app = DERIVED / "Build/Products/Debug-iphonesimulator/Banana.app"
    else:
        app = build_iphone(udid)
    if not app.exists():
        raise RuntimeError(f"Missing iOS simulator build: {app}")
    executable = app / "Banana"
    captured_binary = binary_hash(executable)
    run(["xcrun", "simctl", "uninstall", udid, BUNDLE_ID], check=False)
    run(["xcrun", "simctl", "install", udid, str(app)])
    # The quick-add scene looks a guest up in Contacts; grant it so no permission sheet lands in the capture.
    run(["xcrun", "simctl", "privacy", udid, "grant", "contacts", BUNDLE_ID], check=False)
    data_path = Path(run(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"], capture=True).strip())
    write_demo_audio(data_path)
    # A first launch after an install is not like the rest: on 9 Oct 2026 the first scene came out
    # as an empty day under a "Calendar isn't connected" card, and the same scene launched again
    # had its sample. Launch once and throw it away.
    run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE_ID,
         "--ui-audit", "--disable-icloud", "--ui-preview"])
    time.sleep(10)
    run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], check=False)

    expected = tuple(manifest["capture"][f"{platform}_size"])
    raw_dir = output / f"raw/{platform}"
    final_dir = output / f"screenshots/{folder}"
    raw_dir.mkdir(parents=True, exist_ok=True)
    final_dir.mkdir(parents=True, exist_ok=True)
    for scene in manifest[f"{platform}_scenes"]:
        raw = raw_dir / f"{scene['id']}.png"
        final = final_dir / f"{scene['id']}.png"
        run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], check=False)
        run(
            [
                "xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE_ID,
                "--ui-audit", "--disable-icloud", STORE_CAPTURE,
                # The "Finish setup" line above the plan is for someone who has just installed.
                "-finishSetupDismissed", "YES", "-planNotificationsLater", "YES",
                "-planRemindersLater", "YES", *scene["route"],
            ]
        )
        # A scene may ask for longer: a map draws its tiles after the screen is up.
        settled_screenshot(udid, raw, scene.get("settle_seconds", manifest["capture"]["settle_seconds"]))
        with Image.open(raw) as image:
            if platform == "ipad" and image.size != expected:
                raise RuntimeError(
                    f"{raw}: the iPad simulator gave {image.width}x{image.height}, not "
                    f"{expected[0]}x{expected[1]}. Check the emulator orientation before retrying."
                )
        run(
            [
                sys.executable, str(TOOL / "compose.py"), "--platform", platform,
                "--raw", str(raw), "--output", str(final), "--scene", scene["id"],
            ]
        )

    record_captures(output, platform, executable, captured_binary)


def capture_iphone(manifest: dict, output: Path, skip_build: bool, ios_app: Path | None = None,
                   udid: str | None = None) -> None:
    capture_ios(manifest, output, skip_build, ios_app, "iphone", "iphone-6.9", udid)


def capture_ipad(manifest: dict, output: Path, skip_build: bool, ios_app: Path | None = None,
                 udid: str | None = None) -> None:
    capture_ios(manifest, output, skip_build, ios_app, "ipad", "ipad-13", udid)


def capture_watch(manifest: dict, output: Path, skip_build: bool) -> None:
    udid = available_device(manifest["capture"]["watch_device"])
    boot(udid)
    deterministic_status_bar(udid)
    app = DERIVED / "Build/Products/Debug-watchsimulator/BananaWatch.app" if skip_build else build_watch(udid)
    if not app.exists():
        raise RuntimeError(f"Missing Watch build: {app}")
    executable = app / "BananaWatch"
    captured_binary = binary_hash(executable)
    run(["xcrun", "simctl", "uninstall", udid, WATCH_BUNDLE_ID], check=False)
    run(["xcrun", "simctl", "install", udid, str(app)])
    raw_dir = output / "raw/watch"
    final_dir = output / "screenshots/watch"
    raw_dir.mkdir(parents=True, exist_ok=True)
    final_dir.mkdir(parents=True, exist_ok=True)
    for scene in manifest["watch_scenes"]:
        destination = raw_dir / f"{scene['id']}.png"
        run(["xcrun", "simctl", "terminate", udid, WATCH_BUNDLE_ID], check=False)
        run(
            [
                "xcrun", "simctl", "launch", "--terminate-running-process", udid,
                WATCH_BUNDLE_ID, *scene["route"],
            ]
        )
        settled_screenshot(udid, destination, manifest["capture"]["settle_seconds"])
        # Apple requires an opaque RGB upload, even when the simulator emits RGBA.
        with Image.open(destination) as capture:
            flattened = Image.new("RGBA", capture.size, (0, 0, 0, 255))
            flattened.alpha_composite(capture.convert("RGBA"))
            flattened.convert("RGB").save(final_dir / destination.name, "PNG", optimize=True)

    record_captures(output, "watch", executable, captured_binary)


def capture_mac(manifest: dict, output: Path, skip_build: bool, mac_app: Path | None = None) -> None:
    if mac_app is not None:
        app = mac_app
    elif skip_build:
        app = MAC_DERIVED / "Build/Products/Debug" / MAC_APP
    else:
        app = build_mac()
    if app.name != MAC_APP:
        # See `build_mac`: only the Beta variant keeps its files apart from the installed app's.
        raise RuntimeError(f"The Mac capture runs {MAC_APP}, not {app.name}")
    # macOS reports processes under the canonical `/private/tmp/...` path even when the launcher
    # was handed `/tmp/...`. Use one canonical spelling for launch, discovery, and cleanup or a
    # timed-out capture can fail to find (and therefore fail to terminate) the app it just opened.
    app = app.resolve()
    if not app.exists():
        raise RuntimeError(f"Missing Mac build: {app}")
    raw_dir = output / "raw/mac"
    final_dir = output / "screenshots/mac"
    raw_dir.mkdir(parents=True, exist_ok=True)
    final_dir.mkdir(parents=True, exist_ok=True)
    captured_binary = binary_hash(mac_executable(app))
    wake_assertion = subprocess.Popen(
        ["caffeinate", "-d", "-u", "-t", "120"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        for scene in manifest["mac_scenes"]:
            stop_mac_app(app)
            raw = raw_dir / f"{scene['id']}.png"
            final = final_dir / f"{scene['id']}.png"
            raw.unlink(missing_ok=True)
            run(
                [
                    "open", "-n", str(app), "--args", "--ui-audit", "--disable-icloud", STORE_CAPTURE,
                    # Start from the default window, not whatever the last (killed) run left saved.
                    "-ApplePersistenceIgnoreState", "YES",
                    "-AppleInterfaceStyle", "Dark", "--mac-section", scene["section"],
                    "--mac-window-size", manifest["capture"]["mac_window"],
                    "--modules", "workouts,food,notes,podcasts",
                    *scene.get("route", []),
                ]
            )
            pid = mac_process_id(app)
            identifier = mac_window_id(pid, app)
            time.sleep(manifest["capture"]["settle_seconds"])
            run(["screencapture", "-x", "-o", "-l", identifier, str(raw)])
            run(
                [
                    sys.executable, str(TOOL / "compose.py"), "--platform", "mac",
                    "--raw", str(raw), "--output", str(final), "--scene", scene["id"],
                ]
            )
    finally:
        stop_mac_app(app)
        wake_assertion.terminate()
        wake_assertion.wait()

    record_captures(output, "mac", mac_executable(app), captured_binary)


def write_metadata(output: Path) -> None:
    source = TOOL / "metadata/en-US"
    destination = output / "metadata/en-US"
    destination.mkdir(parents=True, exist_ok=True)
    for path in source.iterdir():
        if path.is_file():
            shutil.copy2(path, destination / path.name)
    for filename in ("submission-checklist.md", "app-preview-storyboard.md"):
        shutil.copy2(TOOL / filename, output / filename)


def replace_pngs(source: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for stale in destination.glob("*.png"):
        stale.unlink()
    for image in sorted(source.glob("*.png")):
        shutil.copy2(image, destination / image.name)


def contact_sheet(
    source: Path,
    destination: Path,
    columns: int,
    cell: tuple[int, int],
    background: tuple[int, int, int],
) -> None:
    images = [Image.open(path).convert("RGB") for path in sorted(source.glob("*.png"))]
    if not images:
        return
    rows = (len(images) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * cell[0], rows * cell[1]), background)
    for index, image in enumerate(images):
        sheet.paste(
            image.resize(cell, Image.Resampling.LANCZOS),
            ((index % columns) * cell[0], (index // columns) * cell[1]),
        )
    destination.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(destination, "PNG", optimize=True)


def publish_landing_assets(output: Path, platforms: tuple[str, ...]) -> None:
    assets = ROOT / "LandingPage/assets/screenshots"
    if "iphone" in platforms:
        replace_pngs(output / "raw/iphone", assets / "iphone/raw")
        replace_pngs(output / "screenshots/iphone-6.9", assets / "iphone/composed")
        contact_sheet(
            assets / "iphone/composed",
            assets / "contact-sheets/iphone.png",
            columns=4,
            cell=(330, 717),
            background=(251, 246, 234),
        )
    if "ipad" in platforms:
        replace_pngs(output / "raw/ipad", assets / "ipad/raw")
        replace_pngs(output / "screenshots/ipad-13", assets / "ipad/composed")
        contact_sheet(
            assets / "ipad/composed",
            assets / "contact-sheets/ipad.png",
            columns=3,
            cell=(688, 516),
            background=(251, 246, 234),
        )
    if "mac" in platforms:
        replace_pngs(output / "raw/mac", assets / "mac/raw")
        replace_pngs(output / "screenshots/mac", assets / "mac/composed")
        contact_sheet(
            assets / "mac/composed",
            assets / "contact-sheets/mac.png",
            columns=3,
            cell=(720, 450),
            background=(251, 246, 234),
        )
    if "watch" in platforms:
        replace_pngs(output / "raw/watch", assets / "watch/raw")
        replace_pngs(output / "screenshots/watch", assets / "watch/composed")
        contact_sheet(
            assets / "watch/composed",
            assets / "contact-sheets/watch.png",
            columns=3,
            cell=(416, 496),
            background=(0, 0, 0),
        )


def refresh_site_screenshots(output: Path, platforms: tuple[str, ...]) -> None:
    """Keep the served website's existing screenshot derivatives on these same captures."""
    mapping = {
        "iphone": {"phone-plan": "01-plan", "phone-routines": "04-routines", "phone-nutrition": "05-nutrition",
                   "phone-workouts": "07-workouts", "phone-listenmap": "08-listening", "phone-transcript": "09-transcripts"},
        "ipad": {"ipad-plan": "01-plan"},
        "mac": {"mac-plan": "01-plan", "mac-sleep": "03-sleep"},
        "watch": {"watch-workout": "01-workout", "watch-playing": "02-now-playing"},
    }
    for platform in platforms:
        for name, scene in mapping[platform].items():
            destination = ROOT / "LandingPage/site/assets/img" / (name + ".webp")
            with Image.open(destination) as previous:
                width = previous.width
            with Image.open(output / "raw" / platform / (scene + ".png")) as capture:
                size = (width, round(width*capture.height/capture.width))
                capture.convert("RGB").resize(size, Image.Resampling.LANCZOS).save(destination, "WEBP", quality=88, method=6)


def clean_output(output: Path) -> None:
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "AppStore/Generated")
    parser.add_argument("--platform", choices=("all", "iphone", "ipad", "watch", "mac"), default="all")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--keep-output", action="store_true")
    parser.add_argument("--ios-app", type=Path,
                        help="an iOS simulator build of Banana.app to use instead of building one")
    parser.add_argument("--ios-udid",
                        help="the simulator to use for a single --platform iphone or ipad run")
    parser.add_argument("--mac-app", type=Path,
                        help=f"a signed {MAC_APP} to use instead of building one")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    if not args.keep_output:
        clean_output(args.output)
    write_metadata(args.output)
    run([sys.executable, str(TOOL / "brand.py"), "--output", str(args.output)])
    # In this order: the iPhone composes last, because its continuity and workout scenes embed
    # the Mac and Watch captures. (It used to run first whatever this said, so a full run
    # composed them with the previous run's.)
    platforms = ("watch", "mac", "ipad", "iphone") if args.platform == "all" else (args.platform,)
    if args.ios_udid and args.platform not in ("iphone", "ipad"):
        parser.error("--ios-udid goes with --platform iphone or --platform ipad")
    udid = args.ios_udid
    capture = {
        "watch": lambda: capture_watch(manifest, args.output, args.skip_build),
        "mac": lambda: capture_mac(manifest, args.output, args.skip_build, args.mac_app),
        "ipad": lambda: capture_ipad(manifest, args.output, args.skip_build, args.ios_app, udid),
        "iphone": lambda: capture_iphone(manifest, args.output, args.skip_build, args.ios_app, udid),
    }
    for platform in platforms:
        capture[platform]()
    publish_landing_assets(args.output, platforms)
    refresh_site_screenshots(args.output, platforms)
    if (args.output / "raw/mac/01-plan.png").exists() and (args.output / "raw/iphone/01-plan.png").exists():
        run([sys.executable, str(TOOL / "creative.py"), "--output", str(args.output)])
    run([sys.executable, str(TOOL / "validate.py"), str(args.output), "--platform", args.platform])
    print(f"\nApp Store package generated at {args.output}")


if __name__ == "__main__":
    main()
