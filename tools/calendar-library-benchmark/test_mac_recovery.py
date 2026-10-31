import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('recovery', Path(__file__).with_name('run-mac-recovery.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecoveryReportTests(unittest.TestCase):
    def fixture(self, asynchronous=True):
        return dict(eventsPerDay=300, asyncRecoveryRequested=asynchronous, samples=[dict(
            index=i, responseMS=30, actionMS=1, flushMS=1, peakResidentBytes=100,
            physicalFootprintBytes=80, mainSectionsMS=[1]*(5 if asynchronous else 2),
            completed=True, visibleIDsMatch=True, drawCoverageMatches=True,
            asyncSamplePresent=True, unexpectedSyncTileBuilds=0) for i in range(21)])

    def testCompleteFastComponentsDoNotCertifyUI(self):
        result = module.evaluate(self.fixture(), 300, True)
        self.assertEqual(result['status'], 'measured')
        self.assertEqual(result['componentBudget'], 'within-measured-limits-only')

    def testOneColdOutlierCannotDisappearInPercentiles(self):
        data = self.fixture()
        data['samples'][0]['responseMS'] = 135
        result = module.evaluate(data, 300, True)
        self.assertEqual(result['response']['maxMS'], 135)
        self.assertEqual(result['componentBudget'], 'fail')

    def testMainSectionBudgetIsIndependentOfResponseBudget(self):
        data = self.fixture(False)
        data['samples'][0]['mainSectionsMS'][0] = 9
        self.assertEqual(module.evaluate(data, 300, False)['componentBudget'], 'fail')

    def testMissingCoverageOrSynchronousFallbackInvalidates(self):
        for key, value in [('completed', False), ('visibleIDsMatch', False),
                           ('asyncSamplePresent', False), ('unexpectedSyncTileBuilds', 1),
                           ('responseMS', float('nan')), ('physicalFootprintBytes', -1)]:
            data = self.fixture()
            data['samples'][0][key] = value
            self.assertEqual(module.evaluate(data, 300, True)['status'], 'invalid-or-unmeasured')

    def testWrongScenarioOrDroppedSampleInvalidates(self):
        data = self.fixture()
        self.assertEqual(module.evaluate(data, 100, True)['status'], 'invalid-or-unmeasured')
        self.assertEqual(module.evaluate(data, 300, False)['status'], 'invalid-or-unmeasured')
        self.assertEqual(module.evaluate(data, 300, True, native_text=True)['status'], 'invalid-or-unmeasured')
        self.assertEqual(module.evaluate(data, 300, True, dispatch=True)['status'], 'invalid-or-unmeasured')
        data['samples'].pop()
        self.assertEqual(module.evaluate(data, 300, True)['status'], 'invalid-or-unmeasured')

    def testMalformedShapeIsUnmeasuredRatherThanACollectorCrash(self):
        for value in [None, [], {'samples': None}, {'samples': [None]}]:
            self.assertEqual(module.evaluate(value, 300, True)['status'], 'invalid-or-unmeasured')
        data = self.fixture()
        data['samples'][0]['mainSectionsMS'] = None
        self.assertEqual(module.evaluate(data, 300, True)['status'], 'invalid-or-unmeasured')

    def testCombinedComparisonRequiresBothActualPolicies(self):
        data = self.fixture()
        data.update(foregroundDispatchRequested=True, nativeTextRequested=True)
        self.assertEqual(module.evaluate(data, 300, True, dispatch=True,
                                        native_text=True)['status'], 'measured')
        for missing in ['foregroundDispatchRequested', 'nativeTextRequested']:
            partial = dict(data)
            partial[missing] = False
            self.assertEqual(module.evaluate(partial, 300, True, dispatch=True,
                                            native_text=True)['status'], 'invalid-or-unmeasured')
