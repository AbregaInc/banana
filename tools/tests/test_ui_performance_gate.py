import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('gate', pathlib.Path(__file__).parents[1] / 'ui-performance-gate.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class UIPerformanceGateTests(unittest.TestCase):
    def fixture(self):
        return dict(environment=dict(device='Test device', os='Test OS', build='fixture',
                                     measurementMethod='Synthetic unit-test data', physicalDevice=True, refreshHz=120),
                    scenarios=[dict(name=f'{kind} {cache}', kind=kind, cache=cache, samplesMS=[5])
                               for kind in ('direct', 'ui') for cache in ('cold', 'warm')]
                    + [dict(name='scroll frames', kind='frame', cache='warm', samplesMS=[8.3])])

    def testSingleSlowSampleCannotBeHiddenByPercentiles(self):
        report = self.fixture()
        report['scenarios'][2]['samplesMS'] = [1] * 1000 + [100.01]
        result = gate.evaluate(report)
        self.assertEqual(result['status'], 'fail')
        self.assertEqual(result['scenarios'][2]['violations'], [dict(sample=1000, ms=100.01)])

    def testFrameAndDirectLimits(self):
        for index, value in [(0, 20.01), (4, 8.31)]:
            report = self.fixture()
            report['scenarios'][index]['samplesMS'] = [value]
            self.assertEqual(gate.evaluate(report)['status'], 'fail')
        report = self.fixture()
        report['scenarios'][0]['samplesMS'] = [10]  # Most direct responses must be under 10.
        self.assertEqual(gate.evaluate(report)['status'], 'fail')

    def testExactly100AllowedButTargetMissIsReported(self):
        report = self.fixture()
        report['scenarios'][2]['samplesMS'] = [100]
        result = gate.evaluate(report)
        self.assertEqual(result['status'], 'pass')
        self.assertFalse(result['scenarios'][2]['targetMet'])

    def testSimulatorAndMissingCoverageCannotCertifyAcceptance(self):
        report = self.fixture()
        report['environment']['physicalDevice'] = False
        self.assertEqual(gate.evaluate(report)['status'], 'unmeasured')
        report = self.fixture()
        report['scenarios'].pop()
        self.assertEqual(gate.evaluate(report)['missingCoverage'], ['frame'])
        self.assertEqual(gate.evaluate(report)['status'], 'unmeasured')

    def testInvalidSamplesAreRejected(self):
        for samples in ([], [float('nan')], [float('inf')], [-1], [True]):
            report = self.fixture()
            report['scenarios'][0]['samplesMS'] = samples
            with self.assertRaises(ValueError):
                gate.evaluate(report)


if __name__ == '__main__':
    unittest.main()
