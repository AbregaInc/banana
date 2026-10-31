import unittest
from report import summarize


def fixture(value=1):
    return dict(verticalScrollFound=True, samples=[
        dict(phase=phase, milliseconds=value, attachedEventViews=100, intersectingEventViews=40)
        for phase, count in [('coldMount', 1), ('page', 12), ('settledLayout', 13), ('scrollOffset', 120)]
        for _ in range(count)])


class EvidenceTests(unittest.TestCase):
    def test_fast_component_never_certifies_ui(self):
        self.assertEqual(summarize(fixture(8.3))['acceptance'], 'unmeasured')

    def test_one_slow_sample_is_retained(self):
        data = fixture()
        data['samples'][-1]['milliseconds'] = 101
        result = summarize(data)
        self.assertEqual(result['acceptance'], 'fail')
        self.assertEqual(result['phases']['scrollOffset']['over100MS'], 1)
        self.assertEqual(result['phases']['scrollOffset']['maxMS'], 101)

    def test_absent_or_invalid_evidence_cannot_pass(self):
        for field, value in [('verticalScrollFound', False), ('samples', [])]:
            data = fixture(); data[field] = value
            self.assertEqual(summarize(data)['status'], 'invalid-evidence')
        for value in [float('nan'), float('inf'), -1]:
            data = fixture(); data['samples'][-1]['milliseconds'] = value
            self.assertEqual(summarize(data)['status'], 'invalid-evidence')
        data = fixture(); data['samples'].pop()
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')
        data = fixture(); data['samples'][0]['phase'] = 'unknown'
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')

    def test_percentile_does_not_hide_maximum(self):
        data = fixture()
        for index, sample in enumerate(data['samples'][-120:]):
            sample['milliseconds'] = index + 1
        result = summarize(data)['phases']['scrollOffset']
        self.assertEqual([result[f'p{p}MS'] for p in (50, 95, 99)], [60, 114, 119])
        self.assertEqual(result['maxMS'], 120)

    def test_stale_calendar_page_is_invalid(self):
        data = fixture(); data['candidate'] = 'kvk'
        for sample in data['samples']:
            sample['requestedDatePresent'] = True
        self.assertEqual(summarize(data)['status'], 'measured')
        data['samples'][1]['requestedDatePresent'] = False
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')

    def test_native_requires_draw_coverage_and_all_recovery_experiments(self):
        data = fixture(); data['candidate'] = 'native'
        for row in data['samples']:
            row.update(visibleIDsMatch=True, drawCoverageMatches=True, requestedDatePresent=True, visiblePresentations=40)
        data['experiments'] = [dict(phase=phase, milliseconds=1, visibleIDsMatch=True,
            drawCoverageMatches=True, requestedDatePresent=True)
            for phase,count in [('uncachedPage',6),('memoryPressurePage',1),('resize',3)] for _ in range(count)]
        self.assertEqual(summarize(data)['status'], 'measured')
        data['experiments'][-1]['milliseconds'] = 101
        self.assertEqual(summarize(data)['acceptance'], 'fail')
        data['samples'][0]['drawCoverageMatches'] = False
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')
        data['samples'][0]['drawCoverageMatches'] = True
        data['experiments'].pop()
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')

    def test_raster_cache_limits_are_required_evidence(self):
        data = fixture(); data['candidate'] = 'native'; data['optimizations'] = {'renderer': 'raster'}
        data['experiments'] = [dict(phase=phase, milliseconds=1)
            for phase,count in [('uncachedPage',6),('memoryPressurePage',1),('resize',3)] for _ in range(count)]
        for row in data['samples'] + data['experiments']:
            row.update(visibleIDsMatch=True, drawCoverageMatches=True, requestedDatePresent=True,
                       visiblePresentations=40, rasterCacheBytes=128*1024*1024, rasterCachedPages=3)
        self.assertEqual(summarize(data)['status'], 'measured')
        data['samples'][0]['rasterCacheBytes'] += 1
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')
        data['samples'][0]['rasterCacheBytes'] -= 1
        data['experiments'][-1]['rasterCachedPages'] = 4
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')

    def test_tiles_require_contents_and_bounded_retention(self):
        data = fixture(); data['candidate'] = 'native'; data['optimizations'] = {'renderer': 'tiles'}
        data['experiments'] = [dict(phase=phase, milliseconds=1)
            for phase,count in [('uncachedPage',6),('memoryPressurePage',1),('resize',3)] for _ in range(count)]
        for row in data['samples'] + data['experiments']:
            row.update(visibleIDsMatch=True, drawCoverageMatches=True, requestedDatePresent=True,
                       visiblePresentations=40, tileContentsPresent=True, tileCacheBytes=64*1024*1024,
                       tileCacheCount=24, activeTiles=8)
        self.assertEqual(summarize(data)['status'], 'measured')
        for key, bad in [('tileContentsPresent', False), ('tileCacheBytes',64*1024*1024+1),
                         ('tileCacheCount',25), ('activeTiles',9), ('activeTiles',0)]:
            row=data['experiments'][-1]; old=row[key]; row[key]=bad
            self.assertEqual(summarize(data)['status'], 'invalid-evidence')
            row[key]=old

    def test_accessibility_page_cache_bounds_are_required(self):
        data = fixture(); data['candidate'] = 'native'
        data['optimizations'] = {'renderer': 'canvas', 'ablation': 'accessibility-page-cache'}
        data['experiments'] = [dict(phase=phase, milliseconds=1)
            for phase,count in [('uncachedPage',6),('memoryPressurePage',1),('resize',3)] for _ in range(count)]
        for row in data['samples'] + data['experiments']:
            row.update(visibleIDsMatch=True, drawCoverageMatches=True, requestedDatePresent=True,
                       visiblePresentations=40, accessibilityCachedPages=3, accessibilityCachedElements=4096)
        self.assertEqual(summarize(data)['status'], 'measured')
        for key, bad in [('accessibilityCachedPages',4), ('accessibilityCachedElements',4097)]:
            row=data['experiments'][-1]; old=row[key]; row[key]=bad
            self.assertEqual(summarize(data)['status'], 'invalid-evidence')
            row[key]=old
        del data['samples'][0]['accessibilityCachedElements']
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')

    def test_navigation_stress_cannot_omit_failures_or_coverage(self):
        data = fixture(); data['candidate'] = 'native'; data['navigationStress'] = True
        data['optimizations'] = {'renderer': 'canvas', 'ablation': 'accessibility-page-cache'}
        data['experiments'] = [dict(phase=phase, milliseconds=1)
            for phase,count in [('uncachedPage',6),('memoryPressurePage',1),('resize',3)] for _ in range(count)]
        data['navigationExperiments'] = [dict(phase=phase, milliseconds=1)
            for phase in ['forwardPage','returnPage','rapidForwardPage','rapidReturnPage'] for _ in range(12)]
        for row in data['samples'] + data['experiments'] + data['navigationExperiments']:
            row.update(visibleIDsMatch=True, drawCoverageMatches=True, requestedDatePresent=True,
                       visiblePresentations=40, accessibilityCachedPages=3, accessibilityCachedElements=4096)
        self.assertEqual(summarize(data)['status'], 'measured')
        data['accessibilityClient'] = 'all'
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')
        for row in data['samples'] + data['experiments'] + data['navigationExperiments']:
            row['accessibilityEnumeratedIDsMatch'] = True
        self.assertEqual(summarize(data)['status'], 'measured')
        data['navigationExperiments'][-1]['accessibilityEnumeratedIDsMatch'] = False
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')
        data['navigationExperiments'][-1]['accessibilityEnumeratedIDsMatch'] = True
        last = data['navigationExperiments'][-1]
        last['milliseconds'] = 101
        self.assertEqual(summarize(data)['acceptance'], 'fail')
        last['accessibilityCachedElements'] = 4097
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')
        last['accessibilityCachedElements'] = 4096
        data['navigationStress'] = False
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')
        data['navigationStress'] = True
        data['navigationExperiments'].pop()
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')

    def test_foreground_requires_complete_correct_measured_publication(self):
        data = fixture(); data.update(candidate='native', foregroundNavigation=True,
            optimizations={'renderer': 'tiles', 'ablation': 'tile-prefetch-async-two'})
        data['experiments'] = [dict(phase=phase, milliseconds=1)
            for phase,count in [('uncachedPage',6),('memoryPressurePage',1),('resize',3)] for _ in range(count)]
        data['foregroundExperiments'] = [dict(phase=phase, workers=2, responseMS=32,
            mainSectionsMS=[1,2,3], measuredMainMS=6, maxMainSectionMS=3,
            completed=True, requestedDateMatches=True, unexpectedSyncTileBuilds=0)
            for phase,count in [('foregroundColdPage',1),('foregroundWarmPage',12),
                ('foregroundUncachedPage',6),('foregroundMemoryPressurePage',1),
                ('foregroundForwardPage',12),('foregroundReturnPage',12),
                ('foregroundRapidForwardPage',12),('foregroundRapidReturnPage',12)] for _ in range(count)]
        for row in data['samples'] + data['experiments'] + data['foregroundExperiments']:
            row.update(visibleIDsMatch=True, drawCoverageMatches=True, requestedDatePresent=True,
                       tileContentsPresent=True, tileCacheBytes=1024, tileCacheCount=1, activeTiles=4)
        result = summarize(data)
        self.assertEqual(result['status'], 'measured')
        self.assertEqual(result['acceptance'], 'unmeasured')
        self.assertEqual(result['foregroundComponentBudget'], 'within-measured-limits')
        last = data['foregroundExperiments'][-1]
        for key, value in [('completed',False), ('requestedDateMatches',False), ('workers',1),
                           ('unexpectedSyncTileBuilds',1), ('responseMS',float('nan')),
                           ('maxMainSectionMS',4), ('mainSectionsMS',[]), ('tileCacheCount',25)]:
            original = last[key]; last[key] = value
            self.assertEqual(summarize(data)['status'], 'invalid-evidence', key)
            last[key] = original
        last['responseMS'] = 101
        result = summarize(data)
        self.assertEqual(result['acceptance'], 'fail')
        self.assertEqual(result['foregroundPhases']['foregroundRapidReturnPage']['responseMS']['over100MS'], 1)
        last['responseMS'] = 32
        last.update(mainSectionsMS=[9], measuredMainMS=9, maxMainSectionMS=9)
        self.assertEqual(summarize(data)['foregroundComponentBudget'], 'fail')
        data['foregroundExperiments'].pop()
        self.assertEqual(summarize(data)['status'], 'invalid-evidence')


if __name__ == '__main__':
    unittest.main()
