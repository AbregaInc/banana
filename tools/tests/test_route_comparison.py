import json
from pathlib import Path
import subprocess
import tempfile
import unittest


GATE = Path(__file__).resolve().parents[1] / "perf-gate.sh"


def report(**routes):
    return {"meta": {}, "devices": {"ipad": {"routes": {
        route: {"launch": {mark: {"median": ms, "min": ms, "max": ms}
                           for mark, ms in marks.items()}}
        for route, marks in routes.items()}}}}


class RouteComparisonTests(unittest.TestCase):
    anchor = {"app.init.body": 100}

    def compare(self, base, candidate, *args):
        with tempfile.TemporaryDirectory() as tmp:
            files = [Path(tmp) / name for name in ("base.json", "new.json")]
            for path, content in zip(files, (base, candidate)):
                path.write_text(json.dumps(content))
            return subprocess.run([GATE, "compare", *files, *args], capture_output=True).returncode

    def test_missing_evidence(self):
        base = report(day=self.anchor, week=self.anchor)
        self.assertEqual(self.compare(base, report()), 2)
        self.assertEqual(self.compare(base, report(day=self.anchor)), 2)
        self.assertEqual(self.compare(report(day={**self.anchor, "ready": 130}), report(day=self.anchor)), 2)

    def test_explicit_partial_run(self):
        base = report(day=self.anchor, week=self.anchor)
        candidate = report(day=self.anchor)
        self.assertEqual(self.compare(base, candidate, "--only", "day"), 0)
        candidate["meta"]["only"] = "day"
        self.assertEqual(self.compare(base, candidate), 0)
        self.assertNotEqual(self.compare(base, candidate, "--only", "week"), 0)

    def test_launch_stall_indicator_is_optional_when_healthy(self):
        healthy = report(day=self.anchor)
        stalled = report(day={**self.anchor, "_stalled_launches": 1})
        self.assertEqual(self.compare(healthy, stalled), 1)
        self.assertEqual(self.compare(stalled, healthy), 0)
        extra = report(day=self.anchor, week={**self.anchor, "_stalled_launches": 1})
        self.assertEqual(self.compare(healthy, extra), 1)

    def test_device_selection(self):
        candidate = report(day=self.anchor)
        base = report(day=self.anchor)
        base["devices"]["iphone"] = base["devices"]["ipad"]
        self.assertEqual(self.compare(base, candidate), 2)
        candidate["meta"]["selected_devices"] = ["ipad"]
        self.assertEqual(self.compare(base, candidate), 0)
        self.assertEqual(self.compare(base, candidate, "--device", "iphone"), 2)

    def test_common_mode_slowdown(self):
        base = report(day={**self.anchor, "ready": 200})
        self.assertEqual(self.compare(base, report(day={"app.init.body": 200, "ready": 400})), 1)
