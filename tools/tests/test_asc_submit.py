"""tools/asc-submit.py submits only a manual-release draft that has the named build, once."""
import importlib.util
from pathlib import Path
import unittest


def load():
    spec = importlib.util.spec_from_file_location("asc_submit", Path(__file__).resolve().parents[1] / "asc-submit.py")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return {"plan": module.plan}

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


if __name__ == "__main__":
    unittest.main()
