#!/usr/bin/env python3
"""Build a UI runner, test an archived Mac App Store candidate, or verify its release evidence.

build is background-only. run requires an idle desktop in a dedicated signed-out macOS account.
It never rebuilds, re-signs, installs or resets the candidate. verify never opens an application.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TESTS = {"ReleaseLaunchTests/testFirstLaunchOnboardingCalendarAndRelaunch()",
         "ReleaseLaunchTests/testFoundationDateOperatorsOnRuntime()"}
REGRESSION_RUNTIME = (27, 2)
REGRESSION_OS_BUILD = "26B5091g"


def command(args, **kwargs):
    return subprocess.check_output(args, text=True, timeout=60, **kwargs).strip()


def digest_tree(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            data = b"link\0" + os.readlink(path).encode()
        elif path.is_file():
            data = hashlib.sha256(path.read_bytes()).digest()
        else:
            continue
        digest.update(path.relative_to(root).as_posix().encode() + b"\0" + data + b"\0")
    return digest.hexdigest()


def harness_digest():
    digest = hashlib.sha256()
    for name in ("tools/mac-release-tests.py", "BananaMacReleaseUITests/ReleaseLaunchTests.swift", "project.yml"):
        digest.update(name.encode() + b"\0" + (ROOT / name).read_bytes())
    return digest.hexdigest()


def runtime_version(value):
    match = re.fullmatch(r"(?:macosx)?(\d+)\.(\d+)(?:\.\d+)?", value)
    if not match:
        raise ValueError("Missing or invalid macOS/SDK version")
    return tuple(map(int, match.groups()))


def uuids(path):
    output = command(["xcrun", "dwarfdump", "--uuid", str(path)])
    found = re.findall(r"UUID: ([A-Fa-f0-9-]{36}) \(([^)]+)\)", output)
    if not found:
        raise ValueError("Executable or dSYM has no UUID")
    return sorted((arch, uuid.upper()) for uuid, arch in found)


def candidate(archive):
    apps = list((archive / "Products/Applications").glob("*.app"))
    if len(apps) != 1:
        raise ValueError("Expected exactly one app in the retained archive")
    app = apps[0]
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("BananaReleaseChannel") != "appstore":
        raise ValueError("Use the AppStore archive, not Stable, Beta or a Debug build")
    source = info.get("BananaSourceCommit", "")
    if not re.fullmatch(r"[a-f0-9]{40}", source):
        raise ValueError("Candidate must identify a clean source commit")
    runtime_version(info.get("DTSDKName", ""))
    command(["codesign", "--verify", "--deep", "--strict", str(app)], stderr=subprocess.DEVNULL)
    entitlements = plistlib.loads(subprocess.check_output(
        ["codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL, timeout=60))
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise ValueError("Candidate must retain the App Store sandbox")
    if entitlements.get("get-task-allow") or entitlements.get("com.apple.security.get-task-allow"):
        raise ValueError("Candidate permits debugging; use the release archive")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    symbols = archive / "dSYMs" / (app.name + ".dSYM") / "Contents/Resources/DWARF" / info["CFBundleExecutable"]
    image_uuids = uuids(binary)
    if image_uuids != uuids(symbols):
        raise ValueError("Retained dSYM does not match the candidate executable")
    imports = command(["xcrun", "nm", "-u", str(binary)])
    date_operators = [operator for operator, symbol in (
        (">=", "_$s10Foundation4DateV2geoiySbAC_ACtFZ"),
        ("<=", "_$s10Foundation4DateV2leoiySbAC_ACtFZ")) if symbol in imports.split()]
    return app, {
        "bundle": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"], "source": source, "sdk": info["DTSDKName"],
        "sdkBuild": info.get("DTSDKBuild"), "xcodeBuild": info.get("DTXcodeBuild"),
        "minimumOS": info.get("LSMinimumSystemVersion"), "uuids": image_uuids,
        "dateOperators": date_operators,
        "appSHA256": digest_tree(app), "dSYMSHA256": hashlib.sha256(symbols.read_bytes()).hexdigest(),
    }


def successful(summary, tree):
    def cases(nodes):
        for node in nodes:
            if node.get("nodeType") == "Test Case":
                yield node
            yield from cases(node.get("children", []))
    tests = list(cases(tree.get("testNodes", [])))
    return (summary.get("result") == "Passed" and summary.get("passedTests") == len(TESTS)
            and summary.get("totalTestCount") == len(TESTS) and summary.get("failedTests") == 0
            and summary.get("skippedTests") == 0 and summary.get("expectedFailures", 0) == 0
            and len(tests) == len(TESTS) and {case.get("nodeIdentifier") for case in tests} == TESTS
            and all(case.get("result") == "Passed" for case in tests))


def results(bundle):
    values = [json.loads(command(["xcrun", "xcresulttool", "get", "test-results", kind,
                                  "--path", str(bundle), "--compact"])) for kind in ("summary", "tests")]
    return values


def execute_tests(args, log):
    # Kill the entire test command's process group on timeout/interruption, not just its lock shell.
    process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=300)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise


def validate_receipt(receipt, identity, harness, summary, tree):
    # JSON turns UUID tuples into lists. Compare their canonical representation.
    if json.dumps(receipt.get("candidate"), sort_keys=True) != json.dumps(identity, sort_keys=True):
        raise ValueError("Evidence belongs to different candidate contents, source, SDK or symbols")
    if receipt.get("harnessSHA256") != harness:
        raise ValueError("Launch suite changed since this evidence was recorded")
    if receipt.get("status") != "passed" or not successful(summary, tree):
        raise ValueError("Launch suite failed, skipped, did not run, or ran different tests")
    environment = receipt.get("environment", {})
    if not environment.get("osBuild"):
        raise ValueError("Evidence has no macOS build number")
    tested = runtime_version(environment.get("osVersion", ""))
    # Check XCTest's own runtime metadata too, rather than trusting only the receipt.
    devices = tree.get("devices", [])
    if len(devices) != 1 or runtime_version(devices[0].get("osVersion", "")) != tested:
        raise ValueError("XCTest runtime does not match the recorded macOS version")
    if devices[0].get("osBuildNumber") != environment["osBuild"]:
        raise ValueError("XCTest runtime does not match the recorded macOS build")
    return tested


def verify(archive, evidence, expected_build=None):
    _, identity = candidate(archive)
    if expected_build is not None and identity["build"] != str(expected_build):
        raise ValueError("Local archive is not the build being submitted")
    required = {REGRESSION_RUNTIME, runtime_version(identity["sdk"])}
    covered, failures = set(), []
    regression_build_covered = False
    for file in sorted(evidence.rglob("receipt.json")):
        try:
            receipt = json.loads(file.read_text())
            summary, tree = results(file.parent / "result.xcresult")
            tested = validate_receipt(receipt, identity, harness_digest(), summary, tree)
            covered.add(tested)
            regression_build_covered |= (tested == REGRESSION_RUNTIME
                                         and receipt["environment"]["osBuild"] == REGRESSION_OS_BUILD)
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            failures.append(f"{file.parent}: {error}")
    # Keep failed attempts, even when a later, complete run supplies passing evidence.
    for failure in failures:
        print("Retained non-passing evidence:", failure, file=sys.stderr)
    missing = required - covered
    if missing or not regression_build_covered:
        versions = ", ".join("%s.%s" % value for value in sorted(missing))
        requirements = [f"macOS {versions}"] if versions else []
        if not regression_build_covered:
            requirements.append(f"review OS build {REGRESSION_OS_BUILD}")
        raise ValueError("Missing exact-candidate launch coverage on " + " and ".join(requirements) + ". "
                         "Run tools/mac-release-tests.py run in the dedicated test account; see tools/release/README.md")
    print(f"Mac App Store build {identity['build']}: exact candidate launch evidence passed")


def configure_runner(value, products, app, date_operators=()):
    """Preserve __TESTROOT__ paths when moving the runner configuration beside retained evidence."""
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(products))
    if isinstance(value, list):
        return [configure_runner(item, products, app, date_operators) for item in value]
    if isinstance(value, dict):
        configured = {key: configure_runner(item, products, app, date_operators) for key, item in value.items()}
        if configured.get("IsUITestBundle"):
            configured.setdefault("EnvironmentVariables", {})["BANANA_RELEASE_APP"] = str(app)
            configured["EnvironmentVariables"]["BANANA_RELEASE_DATE_OPERATORS"] = ",".join(date_operators)
        return configured
    return value


def runner_identity():
    products = ROOT / ".build/mac-check/Build/Products"
    configs = list(products.glob("BananaMacReleaseUITests_*.xctestrun"))
    if len(configs) != 1:
        raise ValueError("Build the separate UI runner first: python3 tools/mac-release-tests.py build")
    host = products / "Debug/BananaMacReleaseUITests-Runner.app"
    if not host.is_dir():
        raise ValueError("UI runner is missing; rebuild it")
    return configs[0], {"harnessSHA256": harness_digest(), "runnerSHA256": digest_tree(host),
                        "configurationSHA256": hashlib.sha256(configs[0].read_bytes()).hexdigest()}


def run(archive, out, interactive):
    marker = Path.home() / ".config/banana/mac-release-test-account"
    if not interactive or not marker.is_file():
        raise ValueError("Visible tests require --interactive and the dedicated account marker; see tools/release/README.md")
    if command(["stat", "-f", "%u", "/dev/console"]) != str(os.getuid()):
        raise ValueError("Run from the dedicated account's unlocked console session")
    if '"IOConsoleLocked" = Yes' in command(["ioreg", "-n", "Root", "-d1", "-l"]):
        raise ValueError("Unlock the dedicated test desktop first")
    automation = subprocess.run(["automationmodetool"], capture_output=True, text=True, timeout=15)
    # XCTest activates Automation Mode for its session. It is normally disabled beforehand;
    # the prerequisite for unattended CI is that activation will not ask for authentication.
    if automation.returncode or "DOES NOT REQUIRE user authentication" not in (automation.stdout + automation.stderr):
        raise ValueError("Configure Automation Mode without authentication in the dedicated test account first")
    app, identity = candidate(archive)
    config, runner = runner_identity()
    stamp = json.loads((config.parent / "mac-release-runner.json").read_text())
    if stamp != runner:
        raise ValueError("UI runner is stale or changed; rebuild it before testing")
    out.mkdir(parents=True, exist_ok=False)
    receipt = {"schema": 1, "status": "started", "candidate": identity, "harnessSHA256": runner["harnessSHA256"],
               "runner": runner,
               "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "environment": {"osVersion": command(["sw_vers", "-productVersion"]),
                               "osBuild": command(["sw_vers", "-buildVersion"])}}
    receipt_file = out / "receipt.json"
    def save():
        receipt_file.write_text(json.dumps(receipt, indent=2) + "\n")
    save()
    configuration = configure_runner(plistlib.loads(config.read_bytes()), config.parent, app,
                                     identity["dateOperators"])
    custom = out / "launch.xctestrun"
    custom.write_bytes(plistlib.dumps(configuration))
    args = [str(ROOT / "tools/agents/xcode-lock.sh"), "-l", "mac-release-ui", "-d", str(ROOT / ".build/mac-check"),
            "xcodebuild", "test-without-building", "-xctestrun", str(custom), "-destination", "platform=macOS",
            "-parallel-testing-enabled", "NO", "-resultBundlePath", str(out / "result.xcresult"),
            "-only-testing:BananaMacReleaseUITests/ReleaseLaunchTests",
            "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "180",
            "-maximum-test-execution-time-allowance", "180"]
    try:
        with (out / "run.log").open("w") as log:
            returncode = execute_tests(args, log)
        summary, tree = results(out / "result.xcresult")
        (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        (out / "tests.json").write_text(json.dumps(tree, indent=2) + "\n")
        _, after = candidate(archive)
        if returncode or after != identity or not successful(summary, tree):
            raise ValueError("Launch tests failed, skipped, or candidate changed; see retained run.log and result.xcresult")
        receipt["status"] = "passed"
    except (ValueError, OSError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        receipt.update(status="failed", error=str(error))
        raise
    finally:
        save()
    print(f"Launch tests passed; evidence: {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("build", help="Compile only the UI runner; no app launch")
    for name in ("run", "verify"):
        p = sub.add_parser(name)
        p.add_argument("archive", type=Path)
        if name == "run":
            p.add_argument("--out", type=Path, required=True, help="New retained result directory outside .build")
            p.add_argument("--interactive", action="store_true", help="Dedicated test desktop is idle")
        else:
            p.add_argument("--evidence", type=Path, default=Path(os.environ.get(
                "BANANA_MAC_LAUNCH_EVIDENCE", ROOT / "private/releases/mac-launch")))
    args = parser.parse_args()
    try:
        if args.action == "build":
            subprocess.run(["bash", "-c", ". tools/config.sh require; xcodegen generate && "
                            "banana_xcode -project Banana.xcodeproj -scheme BananaMacReleaseUITests "
                            "-configuration Debug -destination 'generic/platform=macOS' "
                            "-derivedDataPath .build/mac-check build-for-testing"], cwd=ROOT, check=True)
            config, runner = runner_identity()
            (config.parent / "mac-release-runner.json").write_text(json.dumps(runner, indent=2) + "\n")
        elif args.action == "run":
            output = args.out.resolve()
            if ".build" in output.parts:
                raise ValueError("Keep launch evidence outside disposable .build folders")
            run(args.archive.resolve(), output, args.interactive)
        else:
            verify(args.archive.resolve(), args.evidence.resolve())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(2, f"Mac release launch gate: {error}\n")


if __name__ == "__main__":
    main()
