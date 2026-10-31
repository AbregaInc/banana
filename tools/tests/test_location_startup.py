"""The fault collector must not accept incomplete or mismatched comparison evidence."""
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / 'onboarding-location-tests/profile-startup.py'
spec = importlib.util.spec_from_file_location('location_startup', path)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class LocationStartupVerdictTests(unittest.TestCase):
    def rows(self):
        return [dict(policy=p, ready=True, workloadMatches=True)
                for p in ['before', 'after', 'after', 'before']]

    def test_normal_service_all_ready(self):
        self.assertEqual(collector.verdict(self.rows()), 0)

    def test_retains_expected_baseline_timeouts(self):
        rows = self.rows()
        for index in [0, 3]:
            rows[index] = dict(policy='before', ready=False)
        self.assertEqual(collector.verdict(rows), 0)

    def test_candidate_timeout_fails(self):
        rows = self.rows()
        rows[2] = dict(policy='after', ready=False)
        self.assertEqual(collector.verdict(rows), 1)

    def test_wrong_workload_invalidates_either_policy(self):
        for index in range(4):
            rows = self.rows()
            rows[index]['workloadMatches'] = False
            self.assertEqual(collector.verdict(rows), 2)

    def test_incomplete_or_reordered_evidence_is_not_a_pass(self):
        rows = self.rows()
        for invalid in [[], rows[:2], list(reversed(rows[:3])), rows + rows]:
            self.assertEqual(collector.verdict(invalid), 2)


if __name__ == '__main__':
    unittest.main()
