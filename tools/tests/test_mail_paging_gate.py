import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('mail_paging_gate', Path(__file__).parents[1] / 'mail-paging-tests/run.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class MailPagingGateTests(unittest.TestCase):
    def fixture(self):
        summary = dict(result='Passed', failedTests=0, skippedTests=0, runtimeWarnings=[],
                       devicesAndConfigurations=[{'device': {'deviceId': 'device'}}])
        tree = [{'nodeType': 'Test Case', 'result': 'Passed',
                 'nodeIdentifierURL': 'test://project/' + name} for name in sorted(gate.REQUIRED)]
        return summary, tree

    def test_requires_real_case_coverage(self):
        summary, tree = self.fixture()
        self.assertEqual(gate.validate([(summary, tree)], 'device')['status'], 'pass')
        self.assertEqual(gate.validate([(summary, tree[:-1])], 'device')['status'], 'fail')

    def test_rejects_failure_skip_wrong_device_and_warning(self):
        for key, value in [('result', 'Failed'), ('failedTests', 1), ('skippedTests', 1),
                           ('runtimeWarnings', [{'message': 'layout warning'}]), ('devicesAndConfigurations', [])]:
            summary, tree = self.fixture()
            summary[key] = value
            self.assertEqual(gate.validate([(summary, tree)], 'device')['status'], 'fail', key)

    def test_failed_required_case_is_not_coverage(self):
        summary, tree = self.fixture()
        tree[0]['result'] = 'Failed'
        self.assertEqual(gate.validate([(summary, tree)], 'device')['status'], 'fail')
