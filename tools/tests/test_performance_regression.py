import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('regression', ROOT / 'tools/performance-regression.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class RegressionTests(unittest.TestCase):
    def setUp(self):
        self.policy = json.loads(gate.POLICY.read_text())
        self.bundle = dict(environment=copy.deepcopy(self.policy['environment']), cases={
            c['name']: json.loads((ROOT / c['reference']).read_text()) for c in self.policy['cases']})

    def test_reference_integrity(self):
        self.assertEqual({c['days'] for c in self.policy['cases'] if not c['redraw']}, {1, 7, 30, 90})
        self.assertEqual({c['route'] for c in self.policy['cases'] if c['redraw']}, {'notes', 'library', 'plan', 'mail'})
        self.assertEqual(len(self.policy['cases']), 8)
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'pass')

    def test_raw_samples_preserve_outliers_and_match_summary(self):
        metric = self.bundle['cases']['scale-90d']['metrics'][4]
        metric['samplesMS'] = [metric['medianMS']] * 6 + [metric['p95MS']]
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'pass')
        metric['samplesMS'][0] = 150
        with self.assertRaisesRegex(ValueError, 'raw samples'):
            gate.evaluate(self.policy, self.bundle)
        metric['p95MS'] = 150
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'fail')

    def test_raw_sample_count_cannot_silently_change(self):
        metric = self.bundle['cases']['scale-90d']['metrics'][4]
        metric['samplesMS'] = [metric['medianMS']] * 6
        with self.assertRaisesRegex(ValueError, 'seven-sample'):
            gate.evaluate(self.policy, self.bundle)

    def test_competing_workload_cannot_pass_even_with_fast_samples(self):
        self.bundle['cases']['scale-1d']['hostMonitor'] = {'clean': False}
        result = gate.evaluate(self.policy, self.bundle)
        self.assertEqual(result['status'], 'fail')
        self.assertIn('Competing developer workload', result['failures']['scale-1d'][0])

    def test_incomplete_monitor_cannot_claim_clean(self):
        self.bundle['cases']['scale-1d']['hostMonitor'] = {'clean': True}
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'fail')

    def test_valid_clean_monitor_preserves_reference_result(self):
        self.bundle['cases']['scale-1d']['hostMonitor'] = {
            'clean': True, 'samples': 2, 'overlappingDeveloperProcesses': [], 'errors': []}
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'pass')

    def test_slowdown_below_absolute_budget_still_fails(self):
        m = self.bundle['cases']['scale-30d']['metrics'][4]
        m['medianMS'] += 5
        m['p95MS'] = max(m['medianMS'], m['p95MS'])
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'fail')

    def test_p95_regression_with_unchanged_median(self):
        self.bundle['cases']['scale-30d']['metrics'][0]['p95MS'] += 8
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'fail')

    def test_absolute_budget_cannot_be_relaxed_by_candidate(self):
        self.bundle['cases']['scale-90d']['metrics'][1]['budgetMS'] = 1000
        with self.assertRaises(ValueError):
            gate.evaluate(self.policy, self.bundle)

    def test_missing_case_metric_and_checksum(self):
        for mutation in [lambda b: b['cases'].pop('scale-90d'),
                         lambda b: b['cases']['scale-1d']['metrics'].pop(),
                         lambda b: b['cases']['scale-1d']['metrics'][0].update(checksum=0)]:
            with self.subTest(mutation=mutation):
                b = copy.deepcopy(self.bundle)
                mutation(b)
                with self.assertRaises(ValueError):
                    gate.evaluate(self.policy, b)

    def test_nonfinite_or_negative_numbers_rejected(self):
        for value in [float('nan'), float('inf'), -1, True]:
            self.bundle['cases']['scale-1d']['residentMB'] = value
            with self.assertRaises(ValueError):
                gate.evaluate(self.policy, self.bundle)

    def test_memory_growth(self):
        self.bundle['cases']['scale-90d']['residentMB'] += 50
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'fail')

    def test_redraw_regression_and_missing_root(self):
        idle = self.bundle['cases']['redraw-notes']['idle']
        idle['rendersPerSecond']['RootView'] = .1
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'fail')
        idle['observedRoot'] = False
        with self.assertRaises(ValueError):
            gate.evaluate(self.policy, self.bundle)

    def test_environment_and_binary_mismatch(self):
        self.bundle['environment']['xcode'] = 'different'
        with self.assertRaises(ValueError):
            gate.evaluate(self.policy, self.bundle)
        self.bundle['environment'] = self.policy['environment']
        self.bundle['cases']['scale-1d']['binarySHA256'] = '0' * 64
        with self.assertRaises(ValueError):
            gate.evaluate(self.policy, self.bundle)

    def test_single_over_100_sample_fails(self):
        self.bundle['cases']['scale-90d']['metrics'][1]['p95MS'] = 100.01
        self.assertEqual(gate.evaluate(self.policy, self.bundle)['status'], 'fail')


if __name__ == '__main__':
    unittest.main()
