#!/usr/bin/env python3
"""What a build's modules bring with them (Config/Modules.json), applied and checked.

    tools/modules/modules.py generate
        After `xcodegen generate` (project.yml's postGenCommand): writes the App Store app's
        Info.plist and entitlements (Config/Generated/) from the full ones xcodegen just wrote,
        with only the modules BANANA_APP_STORE_MODULES (Config/Base.xcconfig) lists, and
        Config/Generated/Modules.xcconfig, which embeds a target that serves only modules
        (the Watch app) beside the App Store app instead of inside it when it carries none of them.
    tools/modules/modules.py check ARTIFACT
        tools/check-release.sh: an .xcarchive, .app or folder must carry nothing of a module its
        app's BananaModules leaves out: no Info.plist key, background mode, task identifier, URL
        scheme, entitlement, linked framework, embedded target or marker in any executable.

A module is named in BANANA_MODULES by its compile condition (BANANA_MODULE_PODCASTS). An item
several modules list stays while any of them is carried.
"""
from __future__ import annotations

import fnmatch
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAP = json.loads((ROOT / "Config/Modules.json").read_text())
MODULES: dict = MAP["modules"]

# The App Store flavour's derived files: (full file xcodegen writes, derived file the AppStore
# configuration points at). project.yml names the derived ones; ModuleCapabilityTests checks
# they are current.
APP_STORE_FILES = [
    ("Banana/Info.plist", "Config/Generated/Banana-AppStore-Info.plist"),
    ("Banana/Banana.entitlements", "Config/Generated/Banana-AppStore.entitlements"),
    ("BananaMac/Info.plist", "Config/Generated/BananaMac-AppStore-Info.plist"),
    ("BananaMac/BananaMacAppStore.entitlements", "Config/Generated/BananaMac-AppStore.entitlements"),
]


def carried(setting: str) -> set[str]:
    """Module names (keys of Modules.json) a BANANA_MODULES value lists."""
    words = set(setting.split())
    return {name for name, module in MODULES.items() if module["condition"] in words}


def owners(kind: str, item: str) -> list[str]:
    """The modules that list `item` under `kind`; an item may be a pattern (`transcribe.*`)."""
    return [name for name, module in MODULES.items()
            if any(item == entry or fnmatch.fnmatchcase(item, entry) for entry in module.get(kind, []))]


def removed(kind: str, item: str, have: set[str]) -> bool:
    """Whether `item` belongs to modules, none of which this build carries."""
    names = owners(kind, item)
    return bool(names) and not (set(names) & have)


def xcconfig(name: str) -> str:
    for line in (ROOT / "Config/Base.xcconfig").read_text().splitlines():
        match = re.match(rf"^{re.escape(name)}\s*=(.*)$", line)
        if match:
            return match.group(1).strip()
    raise SystemExit(f"{name} is not in Config/Base.xcconfig")


# MARK: - Deriving

def derive_info(info: dict, have: set[str]) -> dict:
    out = {key: value for key, value in info.items() if not removed("info", key, have)}
    if "UIBackgroundModes" in out:
        out["UIBackgroundModes"] = [m for m in out["UIBackgroundModes"] if not removed("backgroundModes", m, have)]
        if not out["UIBackgroundModes"]:
            del out["UIBackgroundModes"]
    if "BGTaskSchedulerPermittedIdentifiers" in out:
        out["BGTaskSchedulerPermittedIdentifiers"] = [
            t for t in out["BGTaskSchedulerPermittedIdentifiers"] if not removed("taskIdentifiers", t, have)]
        if not out["BGTaskSchedulerPermittedIdentifiers"]:
            del out["BGTaskSchedulerPermittedIdentifiers"]
    if "CFBundleURLTypes" in out:
        types = []
        for entry in out["CFBundleURLTypes"]:
            entry = dict(entry)
            entry["CFBundleURLSchemes"] = [s for s in entry.get("CFBundleURLSchemes", [])
                                           if not removed("urlSchemes", s, have)]
            if entry["CFBundleURLSchemes"]:
                types.append(entry)
        out["CFBundleURLTypes"] = types
    for name, module in MODULES.items():
        if name in have:
            continue
        for reword in module.get("rewords", []):
            text = out.get(reword["key"])
            if isinstance(text, str) and reword["when"] in text.lower():
                out[reword["key"]] = reword["text"]
    return out


def derive_entitlements(entitlements: dict, have: set[str]) -> dict:
    return {key: value for key, value in entitlements.items() if not removed("entitlements", key, have)}


def generate() -> None:
    have = carried(xcconfig("BANANA_APP_STORE_MODULES"))
    for source, target in APP_STORE_FILES:
        data = plistlib.loads((ROOT / source).read_bytes())
        derived = derive_entitlements(data, have) if source.endswith(".entitlements") else derive_info(data, have)
        path = ROOT / target
        path.parent.mkdir(parents=True, exist_ok=True)
        encoded = plistlib.dumps(derived, sort_keys=True)
        if not path.exists() or path.read_bytes() != encoded:
            path.write_bytes(encoded)
    point_entitlements()
    settings = ROOT / "Config/Generated/Modules.xcconfig"
    text = embed_settings(have)
    if not settings.exists() or settings.read_text() != text:
        settings.write_text(text)


def point_entitlements() -> None:
    """XcodeGen gives every configuration of a target with `entitlements:` that file, whatever
    the configuration says. A configuration that uses a derived Info.plist gets the derived
    entitlements of the same app (APP_STORE_FILES pairs them in order)."""
    project = ROOT / "Banana.xcodeproj/project.pbxproj"
    if not project.exists():
        return
    text = project.read_text()
    pairs = list(zip(APP_STORE_FILES[0::2], APP_STORE_FILES[1::2]))
    changed = text
    for (_, info), (full, derived) in pairs:
        pattern = re.compile(r"(isa = XCBuildConfiguration;\s*buildSettings = \{)(.*?)(\};\s*name = [^;]+;)", re.S)
        def fix(match):
            body = match.group(2)
            if f'INFOPLIST_FILE = "{info}"' not in body and f"INFOPLIST_FILE = {info};" not in body:
                return match.group(0)
            body = re.sub(r"CODE_SIGN_ENTITLEMENTS = [^;]+;", f'CODE_SIGN_ENTITLEMENTS = "{derived}";', body)
            return match.group(1) + body + match.group(3)
        changed = pattern.sub(fix, changed)
    if changed != text:
        project.write_text(changed)


def embed_settings(have: set[str]) -> str:
    """The xcconfig lines that leave out, for the App Store configuration, each embedded target
    whose modules it carries none of: BANANA_<FOLDER>_EMBED_PATH points outside the app."""
    lines = ["// Generated by tools/modules/modules.py from Config/Modules.json. Do not edit.", ""]
    # The files only left-out modules bundle (EXCLUDED_SOURCE_FILE_NAMES applies to resources too).
    left_out = sorted({name for module, entry in MODULES.items() if module not in have
                       for name in entry.get("resources", [])
                       if not set(owners("resources", name)) & have})
    if left_out:
        lines.append("EXCLUDED_SOURCE_FILE_NAMES[config=AppStore] = $(inherited) " + " ".join(left_out))
    for folder, modules in MAP["embeds"].items():
        if not set(modules) & have:
            lines.append(f"BANANA_{folder.upper()}_EMBED_PATH[config=AppStore] = ModulesLeftOut/{folder}")
    return "\n".join(lines) + "\n"


# MARK: - Checking an artifact

def primary_app(target: Path) -> Path:
    if target.suffix == ".app":
        return target
    apps = [p for p in target.rglob("*.app") if not any(part.endswith(".app") for part in p.relative_to(target).parts[:-1])]
    apps = [p for p in apps if p.parent.name in ("Applications", target.name) or len(apps) == 1]
    if len(apps) != 1:
        raise SystemExit(f"Expected one app under {target}, found {len(apps)}")
    return apps[0]


def info_plist(app: Path) -> dict:
    for candidate in (app / "Info.plist", app / "Contents/Info.plist"):
        if candidate.exists():
            return plistlib.loads(candidate.read_bytes())
    raise SystemExit(f"No Info.plist in {app}")


def executable(app: Path, info: dict) -> Path:
    flat = app / info["CFBundleExecutable"]
    return flat if flat.exists() else app / "Contents/MacOS" / info["CFBundleExecutable"]


def entitlements(binary: Path) -> dict:
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(binary)],
                            capture_output=True)
    if result.returncode != 0 or not result.stdout.strip():
        return {}
    try:
        return plistlib.loads(result.stdout)
    except Exception:
        return {}


def macho_files(root: Path):
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as handle:
                head = handle.read(4)
            if head in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
                yield path


def check(target: Path) -> int:
    app = primary_app(target)
    info = info_plist(app)
    setting = info.get("BananaModules")
    if setting is None:
        print(f"Not for distribution: {app.name} has no BananaModules in its Info.plist")
        return 1
    have = carried(setting)
    absent = [name for name in MODULES if name not in have]
    problems: list[str] = []

    for key in info:
        if removed("info", key, have):
            problems.append(f"Info.plist key {key}")
    for mode in info.get("UIBackgroundModes", []):
        if removed("backgroundModes", mode, have):
            problems.append(f"background mode {mode}")
    for task in info.get("BGTaskSchedulerPermittedIdentifiers", []):
        if removed("taskIdentifiers", task, have):
            problems.append(f"background task {task}")
    for entry in info.get("CFBundleURLTypes", []):
        for scheme in entry.get("CFBundleURLSchemes", []):
            if removed("urlSchemes", scheme, have):
                problems.append(f"URL scheme {scheme}")

    binary = executable(app, info)
    for key in entitlements(binary):
        if removed("entitlements", key, have):
            problems.append(f"entitlement {key}")
    linked = subprocess.run(["otool", "-L", str(binary)], capture_output=True, text=True).stdout
    frameworks = set(re.findall(r"/([A-Za-z0-9]+)\.framework/", linked))
    for framework in sorted(frameworks):
        if removed("frameworks", framework, have):
            problems.append(f"linked framework {framework}")

    for path in app.rglob("*"):
        if removed("resources", path.name, have):
            problems.append(f"bundled file {path.relative_to(app)}")
    for folder, modules in MAP["embeds"].items():
        if not set(modules) & have and (app / folder).exists():
            problems.append(f"embedded {folder} (serves {', '.join(modules)})")

    markers = {marker: name for name in absent for marker in MODULES[name].get("markers", [])}
    files = list(macho_files(app))
    for path in files:
        data = path.read_bytes()
        for marker, name in markers.items():
            if marker.encode() in data:
                problems.append(f"{name} marker \"{marker}\" in {path.relative_to(app)}")

    if problems:
        print(f"Not for distribution: {app.name} leaves out {', '.join(absent) or 'nothing'} but carries:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"OK: {app.name} carries {', '.join(sorted(have)) or 'no module'}; nothing of "
          f"{', '.join(absent) or 'no other module'} in {len(files)} executable(s)")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "generate":
        generate()
        return 0
    if len(argv) == 3 and argv[1] == "check":
        return check(Path(argv[2]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
