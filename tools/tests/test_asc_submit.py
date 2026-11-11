"""tools/asc-submit.py submits only a manual-release draft that has the named build, once."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


def load():
    spec = importlib.util.spec_from_file_location("asc_submit", Path(__file__).resolve().parents[1] / "asc-submit.py")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return {"plan": module.plan, "build_to_attach": module.build_to_attach}

def version(platform, build="83", release="MANUAL", vid="v1"):
    return {"id": vid, "attributes": {"platform": platform, "versionString": "1.0", "appVersionState": "PREPARE_FOR_SUBMISSION", "releaseType": release}, "build": build}


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.plan = load()["plan"]

    def test_submits_the_one_manual_draft_with_the_build(self):
        self.assertEqual(self.plan("IOS", [version("IOS"), version("MAC_OS", vid="v2")], [], "83"), ("submit", "v1", None))

    def test_refuses_another_build_or_automatic_release(self):
        self.assertEqual(self.plan("IOS", [version("IOS", build="82")], [], "83")[0], "stop")
        self.assertEqual(self.plan("IOS", [version("IOS", release="AFTER_APPROVAL")], [], "83")[0], "stop")
        self.assertEqual(self.plan("IOS", [], [], "83")[0], "stop")

    def test_reuses_an_unsubmitted_submission_and_stops_on_a_submitted_one(self):
        ready = {"id": "s1", "attributes": {"platform": "IOS", "state": "READY_FOR_REVIEW"}}
        waiting = {"id": "s2", "attributes": {"platform": "IOS", "state": "WAITING_FOR_REVIEW"}}
        self.assertEqual(self.plan("IOS", [version("IOS")], [ready], "83"), ("submit", "v1", "s1"))
        self.assertEqual(self.plan("IOS", [version("IOS")], [waiting], "83")[0], "stop")
        self.assertEqual(self.plan("IOS", [version("IOS")], [{"id": "s3", "attributes": {"platform": "MAC_OS", "state": "WAITING_FOR_REVIEW"}}], "83"), ("submit", "v1", None))

    def test_resubmits_a_rejected_submission_and_refuses_two_open_ones(self):
        rejected = {"id": "s4", "attributes": {"platform": "IOS", "state": "UNRESOLVED_ISSUES"}}
        ready = {"id": "s1", "attributes": {"platform": "IOS", "state": "READY_FOR_REVIEW"}}
        self.assertEqual(self.plan("IOS", [version("IOS", build="117")], [rejected], "117"), ("resubmit", "v1", "s4"))
        self.assertEqual(self.plan("IOS", [version("IOS", build="116")], [rejected], "117")[0], "stop")
        self.assertEqual(self.plan("IOS", [version("IOS")], [rejected, ready], "83")[0], "stop")

    def test_rejected_version_is_editable_but_reviewed_or_released_version_is_not(self):
        rejected = {"id": "s4", "attributes": {"platform": "MAC_OS", "state": "UNRESOLVED_ISSUES"}}
        for state in ("REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED"):
            candidate = version("MAC_OS")
            candidate["attributes"]["appVersionState"] = state
            self.assertEqual(self.plan("MAC_OS", [candidate], [rejected], "83"), ("resubmit", "v1", "s4"))
        for state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_SALE"):
            candidate = version("MAC_OS")
            candidate["attributes"]["appVersionState"] = state
            self.assertEqual(self.plan("MAC_OS", [candidate], [], "83")[0], "stop")

    def test_attaches_only_the_one_processed_build_for_the_platform(self):
        pick = load()["build_to_attach"]
        builds = [{"id": "i", "platform": "IOS", "state": "VALID", "expired": False, "version": "1.0"},
                  {"id": "m", "platform": "MAC_OS", "state": "PROCESSING", "expired": False, "version": "1.0"}]
        self.assertEqual(pick("IOS", builds, "1.0"), ("attach", "i"))
        self.assertEqual(pick("MAC_OS", builds, "1.0")[0], "stop")
        self.assertEqual(pick("IOS", builds, "1.0.4")[0], "stop")


class MacLaunchGateTests(unittest.TestCase):
    def module(self):
        spec = importlib.util.spec_from_file_location("asc_submit", Path(__file__).resolve().parents[1] / "asc-submit.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_missing_mac_launch_proof_stops_before_contacting_apple(self):
        module = self.module()
        for platforms in ([], ["--platform", "MAC_OS"]):
            with patch("sys.argv", ["asc-submit.py", "123", "--apply", *platforms]), \
                 patch.object(module, "verify_mac_launch", side_effect=ValueError("missing coverage")) as gate, \
                 patch.object(module, "asc_module") as apple:
                with self.assertRaisesRegex(SystemExit, "launch gate"):
                    module.main()
                gate.assert_called_once_with("123")
                apple.assert_not_called()

    def test_ios_submission_draft_attachment_and_read_only_planning_do_not_launch_or_gate(self):
        module = self.module()
        for flags in (["--apply", "--platform", "IOS"], ["--apply", "--attach"], []):
            with self.subTest(flags=flags), patch("sys.argv", ["asc-submit.py", "123", *flags]), \
                 patch.object(module, "verify_mac_launch") as gate, \
                 patch.object(module, "asc_module", side_effect=RuntimeError("read-only API boundary")):
                with self.assertRaisesRegex(RuntimeError, "API boundary"):
                    module.main()
                gate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
