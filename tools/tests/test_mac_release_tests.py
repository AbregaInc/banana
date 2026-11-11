"""The release gate must fail closed without exact-candidate, actual-runtime UI evidence."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("mac_release_tests", ROOT / "tools/mac-release-tests.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def passed_results(os_version="27.2", os_build=gate.REGRESSION_OS_BUILD):
    return ({"result": "Passed", "passedTests": 2, "totalTestCount": 2, "failedTests": 0,
             "skippedTests": 0, "expectedFailures": 0},
            {"devices": [{"osVersion": os_version, "osBuildNumber": os_build}], "testNodes": [{"children": [
                {"nodeType": "Test Case", "nodeIdentifier": name, "result": "Passed"}
                for name in sorted(gate.TESTS)]}]})


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.identity = {"build": "123", "source": "a" * 40, "sdk": "macosx27.2",
                         "uuids": [("arm64", "sample-uuid")], "appSHA256": "app", "dSYMSHA256": "symbols"}
        self.receipt = {"candidate": json.loads(json.dumps(self.identity)), "harnessSHA256": "suite",
                        "status": "passed", "environment": {"osVersion": "27.2", "osBuild": gate.REGRESSION_OS_BUILD}}

    def test_accepts_complete_exact_candidate_evidence(self):
        self.assertEqual(gate.validate_receipt(self.receipt, self.identity, "suite", *passed_results()), (27, 2))

    def test_rejects_zero_tests_skips_expected_failures_and_wrong_test(self):
        summary, tree = passed_results()
        for key, value in (("passedTests", 0), ("totalTestCount", 0), ("skippedTests", 1),
                           ("failedTests", 1), ("expectedFailures", 1), ("result", "Failed")):
            changed = dict(summary, **{key: value})
            with self.subTest(key=key):
                self.assertFalse(gate.successful(changed, tree))
        for mutation in (lambda t: t["testNodes"].clear(),
                         lambda t: t["testNodes"][0]["children"][0].update(nodeIdentifier="Other/test()"),
                         lambda t: t["testNodes"][0]["children"][0].update(result="Skipped")):
            changed = copy.deepcopy(tree)
            mutation(changed)
            self.assertFalse(gate.successful(summary, changed))

    def test_rejects_changed_artifact_symbols_source_sdk_build_and_suite(self):
        for key in self.identity:
            receipt = copy.deepcopy(self.receipt)
            receipt["candidate"][key] = "changed"
            with self.subTest(key=key), self.assertRaises(ValueError):
                gate.validate_receipt(receipt, self.identity, "suite", *passed_results())
        with self.assertRaises(ValueError):
            gate.validate_receipt(self.receipt, self.identity, "changed suite", *passed_results())

    def test_rejects_failed_or_interrupted_receipt_and_runtime_disagreement(self):
        for status in ("started", "failed", "skipped"):
            with self.subTest(status=status), self.assertRaises(ValueError):
                gate.validate_receipt(dict(self.receipt, status=status), self.identity, "suite", *passed_results())
        with self.assertRaisesRegex(ValueError, "runtime"):
            gate.validate_receipt(self.receipt, self.identity, "suite", *passed_results("27.0.1"))
        self.receipt["environment"].pop("osBuild")
        with self.assertRaisesRegex(ValueError, "build number"):
            gate.validate_receipt(self.receipt, self.identity, "suite", *passed_results())

    def verify_with_runtimes(self, versions, sdk="macosx27.2", builds=None):
        self.identity["sdk"] = sdk
        builds = builds or [gate.REGRESSION_OS_BUILD if v == "27.2" else "other-os-build" for v in versions]
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            for index, version in enumerate(versions):
                folder = evidence / str(index)
                folder.mkdir()
                receipt = copy.deepcopy(self.receipt)
                receipt["candidate"] = self.identity
                receipt["environment"]["osVersion"] = version
                receipt["environment"]["osBuild"] = builds[index]
                (folder / "receipt.json").write_text(json.dumps(receipt))
            def results(path):
                index = int(path.parent.name)
                return passed_results(versions[index], builds[index])
            with patch.object(gate, "candidate", return_value=(Path("candidate"), self.identity)), \
                 patch.object(gate, "harness_digest", return_value="suite"), \
                 patch.object(gate, "results", side_effect=results):
                gate.verify(Path("archive"), evidence)

    def test_old_or_newer_os_does_not_substitute_for_regression_runtime(self):
        for versions in ([], ["27.0.1"], ["27.3"]):
            with self.subTest(versions=versions), self.assertRaisesRegex(ValueError, "27.2"):
                self.verify_with_runtimes(versions)
        self.verify_with_runtimes(["27.2"])

    def test_same_version_and_patch_release_do_not_replace_exact_review_build(self):
        for version, build in (("27.2", "26B123"), ("27.2", "26B5112a"), ("27.2.1", "26B131")):
            with self.subTest(version=version, build=build), self.assertRaisesRegex(ValueError, gate.REGRESSION_OS_BUILD):
                self.verify_with_runtimes([version], builds=[build])

    def test_xctest_build_must_match_receipt(self):
        summary, tree = passed_results(os_build="different-build")
        with self.assertRaisesRegex(ValueError, "macOS build"):
            gate.validate_receipt(self.receipt, self.identity, "suite", summary, tree)

    def test_new_sdk_requires_both_sdk_and_regression_runtime(self):
        with self.assertRaisesRegex(ValueError, "27.3"):
            self.verify_with_runtimes(["27.2"], sdk="macosx27.3")
        self.verify_with_runtimes(["27.2", "27.3"], sdk="macosx27.3")

    def test_submission_build_must_match_the_retained_archive(self):
        with patch.object(gate, "candidate", return_value=(Path("candidate"), self.identity)):
            with self.assertRaisesRegex(ValueError, "build being submitted"):
                gate.verify(Path("archive"), Path("evidence"), expected_build="124")

    def test_bundle_digest_detects_resource_and_symlink_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "resource").write_text("before")
            before = gate.digest_tree(root)
            (root / "resource").write_text("after")
            self.assertNotEqual(before, gate.digest_tree(root))
            (root / "alias").symlink_to("resource")
            before = gate.digest_tree(root)
            (root / "alias").unlink()
            (root / "alias").symlink_to("elsewhere")
            self.assertNotEqual(before, gate.digest_tree(root))

    def test_runner_configuration_keeps_exact_url_and_original_testroot(self):
        config = {"TestConfigurations": [{"TestTargets": [{"IsUITestBundle": True,
                  "TestBundlePath": "__TESTROOT__/Runner.app/PlugIns/Tests.xctest",
                  "EnvironmentVariables": {"EXISTING": "kept"}}]}]}
        result = gate.configure_runner(config, Path("/runner products"), Path("/archive/app with spaces.app"), [">="])
        target = result["TestConfigurations"][0]["TestTargets"][0]
        self.assertEqual(target["TestBundlePath"], "/runner products/Runner.app/PlugIns/Tests.xctest")
        self.assertEqual(target["EnvironmentVariables"], {"EXISTING": "kept", "BANANA_RELEASE_APP": "/archive/app with spaces.app",
                                                         "BANANA_RELEASE_DATE_OPERATORS": ">="})

    def test_run_without_explicit_interactive_scope_stops_before_candidate_or_ui(self):
        with patch.object(gate, "candidate") as candidate, patch.object(gate, "command") as command:
            with self.assertRaisesRegex(ValueError, "dedicated"):
                gate.run(Path("archive"), Path("out"), False)
            candidate.assert_not_called()
            command.assert_not_called()

    def test_session_mode_may_be_disabled_but_activation_must_not_require_authentication(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            marker = home / ".config/banana/mac-release-test-account"
            marker.parent.mkdir(parents=True)
            marker.touch()
            for state in ("enabled", "disabled"):
                for requires in (True, False):
                    output = f"Automation Mode is {state}.\nThis device " + (
                        "REQUIRES" if requires else "DOES NOT REQUIRE") + " user authentication to enable Automation Mode.\n"
                    status = subprocess.CompletedProcess(["automationmodetool"], 0, output, "")
                    with self.subTest(state=state, requires=requires), \
                         patch.object(gate.Path, "home", return_value=home), \
                         patch.object(gate, "command", side_effect=[str(os.getuid()), '"IOConsoleLocked" = No']), \
                         patch.object(gate.subprocess, "run", return_value=status), \
                         patch.object(gate, "candidate", side_effect=RuntimeError("artifact inspection reached")) as candidate:
                        if requires:
                            with self.assertRaisesRegex(ValueError, "without authentication"):
                                gate.run(Path("archive"), Path("out"), True)
                            candidate.assert_not_called()
                        else:
                            with self.assertRaisesRegex(RuntimeError, "artifact inspection reached"):
                                gate.run(Path("archive"), Path("out"), True)
                            candidate.assert_called_once()


class ArtifactTests(unittest.TestCase):
    def test_signature_sandbox_release_identity_and_matching_symbols_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory)
            app = archive / "Products/Applications/Candidate.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "MacOS/Candidate").write_bytes(b"binary")
            symbols = archive / "dSYMs/Candidate.app.dSYM/Contents/Resources/DWARF/Candidate"
            symbols.parent.mkdir(parents=True)
            symbols.write_bytes(b"symbols")
            info = {"BananaReleaseChannel": "appstore", "BananaSourceCommit": "a" * 40,
                    "DTSDKName": "macosx27.2", "CFBundleExecutable": "Candidate", "CFBundleIdentifier": "test.example",
                    "CFBundleVersion": "123", "CFBundleShortVersionString": "1.0"}
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            with patch.object(gate, "command", return_value=""), \
                 patch.object(gate, "uuids", return_value=[("arm64", "uuid")]), \
                 patch.object(gate.subprocess, "check_output", return_value=plistlib.dumps({"com.apple.security.app-sandbox": True})):
                _, identity = gate.candidate(archive)
                self.assertEqual(identity["build"], "123")
                with patch.object(gate, "uuids", side_effect=[[("arm64", "one")], [("arm64", "two")]]):
                    with self.assertRaisesRegex(ValueError, "dSYM"):
                        gate.candidate(archive)
                for entitlements in ({}, {"com.apple.security.app-sandbox": True, "get-task-allow": True}):
                    with patch.object(gate.subprocess, "check_output", return_value=plistlib.dumps(entitlements)), self.assertRaises(ValueError):
                        gate.candidate(archive)
                info["BananaReleaseChannel"] = "testflight"
                (contents / "Info.plist").write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(ValueError, "AppStore"):
                    gate.candidate(archive)


class PipelineTests(unittest.TestCase):
    def test_cleanup_keeps_store_archives_and_symbols_but_removes_compile_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tools").mkdir()
            (root / "bin").mkdir()
            pgrep = root / "bin/pgrep"
            pgrep.write_text("#!/bin/sh\nexit 1\n")
            pgrep.chmod(0o755)
            shutil.copy(ROOT / "tools/clean-builds.sh", root / "tools/clean-builds.sh")
            keep = ("ios-appstore", "mac-appstore", "ios-appstore-check", "mac-appstore-check", "dsyms")
            for name in (*keep, "mac-check"):
                path = root / ".build" / name
                path.mkdir(parents=True)
                (path / "evidence").write_text("retained artifact")
            env = dict(os.environ, BANANA_XCODE_CAS=str(root / "no-cache"), TMPDIR=str(root),
                       PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
            subprocess.run(["sh", str(root / "tools/clean-builds.sh")], env=env, check=True, capture_output=True)
            for name in keep:
                self.assertTrue((root / ".build" / name / "evidence").exists(), name)
            self.assertFalse((root / ".build/mac-check").exists())

    def test_upload_cannot_export_without_launch_evidence_even_without_preflight(self):
        for gate_passes in (False, True):
            with self.subTest(gate_passes=gate_passes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "tools").mkdir()
                (root / "bin").mkdir()
                (root / ".build/mac-appstore/Banana-123.xcarchive").mkdir(parents=True)
                shutil.copy(ROOT / "tools/testflight.sh", root / "tools/testflight.sh")
                (root / "tools/config.sh").write_text('banana_setting() { echo test; }\nbanana_source_revision() { echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }\nASC_KEY_ID=test\nASC_ISSUER_ID=test\nASC_KEY_PATH="$PWD/key.p8"\n')
                (root / "key.p8").touch()
                (root / "TestFlightExportOptions.plist").write_bytes(plistlib.dumps({}))
                stubs = {
                    "git": '#!/bin/sh\n[ "$1" != rev-parse ] || echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n',
                    "python3": '#!/bin/sh\nif [ "$1" = tools/mac-release-tests.py ]; then\n echo "$@" >> gate-called\n exit ' + ('0' if gate_passes else '2') + '\nfi\nexit 0\n',
                    "xcodebuild": '#!/bin/sh\necho exported > export-called\n',
                }
                for name, text in stubs.items():
                    path = root / "bin" / name
                    path.write_text(text)
                    path.chmod(0o755)
                check = root / "tools/check-release.sh"
                check.write_text('#!/bin/sh\nexit 0\n')
                check.chmod(0o755)
                env = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
                archive_marker = root / ".build/mac-appstore/Banana-123.xcarchive/tested-artifact"
                archive_marker.write_text("immutable candidate")
                checked = subprocess.run(["bash", str(root / "tools/testflight.sh"), "mac", "123", "check", "appstore"],
                                         env=env, capture_output=True, text=True)
                self.assertEqual(checked.returncode, 0, checked.stderr)
                self.assertEqual(archive_marker.read_text(), "immutable candidate")
                self.assertFalse((root / "export-called").exists())
                result = subprocess.run(["bash", str(root / "tools/testflight.sh"), "mac", "123", "upload", "appstore"],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0 if gate_passes else 2, result.stderr)
                self.assertEqual((root / "export-called").exists(), gate_passes)
                self.assertIn("verify .build/mac-appstore/Banana-123.xcarchive", (root / "gate-called").read_text())


if __name__ == "__main__":
    unittest.main()
