#!/usr/bin/env python3
"""Photograph every screen in tools/atlas/screens.json on sample data.

    tools/atlas/capture.py phone|pad|watch|mac [--out DIR] [--only ID ...] [--app PATH]

iPhone and iPad run in their simulators (the Debug build in .build/sim), the Watch in a Watch
simulator, the Mac as the Beta Debug build in a real window (it opens windows on the desktop, so
it runs only when nobody is at the Mac). Every launch is a cold one with launch arguments, never
a tap: the screens the walk test photographs (`walk: true`) are skipped here.

Writes <out>/<device>/<area>/<name>.png and <out>/<device>/capture.log.
"""
import argparse, importlib.util, json, shutil, subprocess, sys, time
from pathlib import Path

sys.dont_write_bytecode = True
TOOL = Path(__file__).resolve().parent
ROOT = TOOL.parents[1]
_spec = importlib.util.spec_from_file_location("generate", ROOT / "tools/app-store/generate.py")
gen = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(gen)

SIMULATORS = {
    "phone": "6DFFC0F9-AA09-41C8-B868-FB0D9CC28255",
    "pad": "43EFC551-5368-4F79-9E52-E3DB87A72F48",
}
WATCH_NAME = "Apple Watch Series 11 (46mm)"
IOS_APP = ROOT / ".build/sim/Build/Products/Debug-iphonesimulator/Banana.app"
WATCH_APP = ROOT / ".build/sim/Build/Products/Debug-watchsimulator/BananaWatch.app"
MAC_APP = ROOT / ".build/mac-beta-debug/Build/Products/Debug/Banana Beta.app"


def arguments(manifest: dict, screen: dict, device: str) -> list[str]:
    args = []
    for a in screen["args"]:
        args += manifest["shell"] if a == "@shell" else [a]
    base = list(manifest["base"])
    # A screen that sets a default the base also sets (first run) has its own value.
    for i in range(0, len(base) - 1):
        if base[i].startswith("-") and not base[i].startswith("--") and base[i] in args:
            base[i] = base[i + 1] = None
    base = [b for b in base if b is not None]
    # The fixed App Store day replaces some samples (travel, all-day, timing): those go without it.
    if screen.get("own_day"):
        base = [b for b in base if b != "--store-capture"]
    if device == "watch":
        base = []
    return base + args


def wanted(screen: dict, device: str) -> bool:
    if screen.get("walk"):
        return False
    return device in screen.get("devices", ["phone"])


def destination(out: Path, device: str, screen: dict) -> Path:
    area, name = screen["id"].split("/", 1)
    path = out / device / area / f"{name}.png"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def capture_ios(manifest: dict, screens: list, device: str, out: Path, app: Path, log) -> None:
    udid = SIMULATORS[device]
    gen.boot(udid)
    gen.deterministic_status_bar(udid)
    gen.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], check=False)
    gen.run(["xcrun", "simctl", "uninstall", udid, gen.BUNDLE_ID], check=False)
    gen.run(["xcrun", "simctl", "install", udid, str(app)])
    # A typed event matches guests against contacts and asks for them; the system's alert then
    # stays up over every later screen. The simulator's contacts are its own sample people.
    gen.run(["xcrun", "simctl", "privacy", udid, "grant", "contacts", gen.BUNDLE_ID], check=False)
    container = Path(gen.run(["xcrun", "simctl", "get_app_container", udid, gen.BUNDLE_ID, "data"], capture=True).strip())
    gen.write_demo_audio(container)
    # The first launch after an install draws an empty day: throw it away.
    gen.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, gen.BUNDLE_ID,
             "--ui-audit", "--disable-icloud", "--no-space-sync", "--ui-preview"])
    time.sleep(8)
    for screen in screens:
        target = destination(out, device, screen)
        args = arguments(manifest, screen, device)
        try:
            gen.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, gen.BUNDLE_ID, *args])
            gen.settled_screenshot(udid, target, screen.get("settle", 5))
            log.write(f"ok    {screen['id']}  {' '.join(args)}\n")
        except Exception as error:  # one screen failing never stops the rest
            log.write(f"FAIL  {screen['id']}  {error}\n")
        log.flush()
    gen.run(["xcrun", "simctl", "terminate", udid, gen.BUNDLE_ID], check=False)
    gen.run(["xcrun", "simctl", "shutdown", udid], check=False)


def capture_watch(manifest: dict, screens: list, out: Path, app: Path, log) -> None:
    udid = gen.available_device(WATCH_NAME)
    gen.boot(udid)
    gen.deterministic_status_bar(udid)
    gen.run(["xcrun", "simctl", "uninstall", udid, gen.WATCH_BUNDLE_ID], check=False)
    gen.run(["xcrun", "simctl", "install", udid, str(app)])
    for screen in screens:
        target = destination(out, "watch", screen)
        try:
            gen.run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, gen.WATCH_BUNDLE_ID, *screen["args"]])
            gen.settled_screenshot(udid, target, screen.get("settle", 5))
            log.write(f"ok    {screen['id']}\n")
        except Exception as error:
            log.write(f"FAIL  {screen['id']}  {error}\n")
        log.flush()
    gen.run(["xcrun", "simctl", "shutdown", udid], check=False)


def capture_mac(manifest: dict, screens: list, out: Path, app: Path, log) -> None:
    app = app.resolve()
    keep_awake = subprocess.Popen(["caffeinate", "-d", "-u", "-t", str(60 * len(screens) + 120)])
    try:
        for screen in screens:
            target = destination(out, "mac", screen)
            gen.stop_mac_app(app)
            try:
                gen.run(["open", "-n", str(app), "--args", *manifest["base"],
                         "-ApplePersistenceIgnoreState", "YES", "--mac-window-size", "1320x840", *screen["args"]])
                pid = gen.mac_process_id(app)
                window = gen.mac_window_id(pid, app)
                time.sleep(screen.get("settle", 6))
                gen.run(["screencapture", "-x", "-o", "-l", window, str(target)])
                log.write(f"ok    {screen['id']}\n")
            except Exception as error:
                log.write(f"FAIL  {screen['id']}  {error}\n")
            log.flush()
    finally:
        gen.stop_mac_app(app)
        keep_awake.terminate()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("device", choices=["phone", "pad", "watch", "mac"])
    ap.add_argument("--out", default=str(ROOT / "design-atlas/screens"))
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--app")
    a = ap.parse_args()
    manifest = json.loads((TOOL / "screens.json").read_text())
    screens = [s for s in manifest["screens"] if wanted(s, a.device) and (not a.only or s["id"] in a.only)]
    out = Path(a.out)
    (out / a.device).mkdir(parents=True, exist_ok=True)
    with open(out / a.device / "capture.log", "a") as log:
        log.write(f"--- {time.strftime('%Y-%m-%d %H:%M')}  {len(screens)} screens\n")
        if a.device in SIMULATORS:
            capture_ios(manifest, screens, a.device, out, Path(a.app) if a.app else IOS_APP, log)
        elif a.device == "watch":
            capture_watch(manifest, screens, out, Path(a.app) if a.app else WATCH_APP, log)
        else:
            capture_mac(manifest, screens, out, Path(a.app) if a.app else MAC_APP, log)


if __name__ == "__main__":
    main()
