import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('live_runner', Path(__file__).with_name('run-live-metal-device.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ConfigurationTests(unittest.TestCase):
    def test_requires_exact_requested_test_and_device(self):
        summary = dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0,
                       expectedFailures=0, result='Passed')
        case = dict(nodeType='Test Case', nodeIdentifier='LiveTests/testPixelsAfterPagingAndEviction()', result='Passed')
        tree = dict(devices=[dict(deviceId='phone')], testNodes=[dict(children=[case])])
        self.assertTrue(runner.valid_test_coverage(summary, tree, 'pixels', 'phone'))
        self.assertFalse(runner.valid_test_coverage(summary, tree, 'scroll', 'phone'))
        self.assertFalse(runner.valid_test_coverage(summary, tree, 'pixels', 'ipad'))
        self.assertFalse(runner.valid_test_coverage({**summary, 'totalTestCount': 0}, tree, 'pixels', 'phone'))
        self.assertFalse(runner.valid_test_coverage({**summary, 'skippedTests': 1}, tree, 'pixels', 'phone'))
        self.assertFalse(runner.valid_test_coverage(summary, {}, 'pixels', 'phone'))

    def test_nested_profile_runs_with_same_basename_do_not_collide(self):
        products = Path('/test/Products')
        first = runner.capture_configuration_path(products, Path('/test/sparse/touch'))
        second = runner.capture_configuration_path(products, Path('/test/dense/touch'))
        self.assertNotEqual(first, second)
        self.assertEqual(first.parent, products)
        self.assertEqual(first, runner.capture_configuration_path(products, Path('/test/sparse/touch')))

if __name__ == '__main__': unittest.main()
