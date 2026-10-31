import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('mount', Path(__file__).with_name('run-mac-mount.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MountTimingTests(unittest.TestCase):
    def fixture(self):
        return dict(responseMS=50, maxMainSectionMS=25, setupMS=25, mainSectionsMS=[25, 1])

    def testFiniteMeasurementsAreAccepted(self):
        self.assertTrue(module.valid_timings(self.fixture()))

    def testInvalidNumbersCannotAppearWithinLimits(self):
        for key in ['responseMS', 'maxMainSectionMS', 'setupMS']:
            for value in [float('nan'), float('inf'), -1, True, '10', None]:
                data = self.fixture()
                data[key] = value
                self.assertFalse(module.valid_timings(data))

    def testMissingOrInvalidSectionsAreRejected(self):
        for sections in [None, [], [float('nan')], [-1], [False], '25']:
            data = self.fixture()
            data['mainSectionsMS'] = sections
            self.assertFalse(module.valid_timings(data))
        self.assertFalse(module.valid_timings(None))

    def testContradictorySummaryCannotHideSlowSection(self):
        data = self.fixture()
        data['mainSectionsMS'] = [25, 150]
        self.assertFalse(module.valid_timings(data))
        data = self.fixture()
        data['responseMS'] = 10
        self.assertFalse(module.valid_timings(data))
