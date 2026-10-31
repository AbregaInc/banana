import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('capacity_report', Path(__file__).with_name('report-capacity.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class CapacityReportTests(unittest.TestCase):
    def fixture(self, root, seed, maxima):
        directory = root / str(seed)
        directory.mkdir()
        env = dict(device='test', binarySHA256='binary', variant='fixed', accessibilityClient='none')
        (directory / 'environment.json').write_text(json.dumps(env))
        rows = []
        for trial, maximum in enumerate(maxima):
            name = f'trial-{trial}'
            phases = {k: dict(maxMS=maximum) for k in ['coldMount', 'page', 'uncachedPage', 'memoryPressurePage',
                'resize', 'forwardPage', 'returnPage', 'rapidForwardPage', 'rapidReturnPage']}
            phases['scrollOffset'] = dict(maxMS=2, p95MS=1)
            fg = {str(i): dict(responseMS=dict(maxMS=maximum), maxMainSectionMS=dict(maxMS=2)) for i in range(8)}
            rows.append(dict(scenario=name, status='measured', phases=phases, foregroundPhases=fg))
            raw = dict(days=365, eventsPerDay=60, retainedEvents=21900, thermalStateAtCompletion=0,
                lowPowerModeAtCompletion=False, fixture=dict(profile='varied-v1', calendarCount=12,
                hiddenCalendars=[], seed=seed, contentChecksum='test', maximumDailyEvents=100, sevenDayBlockEvents=420))
            (directory / (name + '.json')).write_text(json.dumps(raw))
        (directory / 'summary.json').write_text(json.dumps(rows))
        return directory

    def test_retains_one_failure_across_seeds_and_never_certifies_ui(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            a = self.fixture(root, 1, [50, 50, 100.01])
            b = self.fixture(root, 2, [50, 50, 50])
            result = report.aggregate([a, b]); group = result['groups'][0]
            self.assertTrue(group['minimumRepeatCoverage'])
            self.assertFalse(group['componentResponseWithin100MS'])
            self.assertFalse(group['allSynchronousWorkWithin8_3MS'])
            self.assertEqual(result['acceptance'], 'unmeasured')
            self.assertEqual(len(group['runs']), 6)

    def test_missing_runs_and_duplicate_directories_cannot_confirm(self):
        with tempfile.TemporaryDirectory() as temp:
            a = self.fixture(Path(temp), 1, [50])
            p = a / 'summary.json'; rows = json.loads(p.read_text())
            rows.append(dict(scenario='missing', status='invalid-evidence')); p.write_text(json.dumps(rows))
            result = report.aggregate([a])
            self.assertFalse(result['groups'][0]['minimumRepeatCoverage'])
            self.assertEqual(len(result['invalidOrIncompleteRuns']), 1)
            with self.assertRaises(ValueError): report.aggregate([a, a])


if __name__ == '__main__':
    unittest.main()
