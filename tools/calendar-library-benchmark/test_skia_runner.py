import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('skia_runner', Path(__file__).with_name('run-skia-raster.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SkiaValidationTests(unittest.TestCase):
    def fixture(self):
        return {'fixture': {'seed': '20261009', 'meanDailyEvents': 100, 'retainedEvents': 36500, 'calendarCount': 12},
            'results': [{'widthPoints': width, 'scale': scale, 'startupMS': 1,
                'samples': [{'state': state, 'first': 'coreGraphics', 'coreGraphicsRasterMS': 20,
                    'skiaCompletionMS': 10, 'skiaEncodeMS': 8, 'skiaCacheBytes': 100, 'coreGraphicsTileBytes': 100,
                    'pixels': [{'tile': tile, 'events': 8, 'skiaEvents': 8, 'totalPixels': width*256*scale**2,
                        'pixelsOverOne': 0, 'maxChannelDifference': 0, 'meanAbsoluteChannelDifference': 0}
                        for tile in range(4)]} for state in ['cold-raster', 'warm-reraster', 'eviction-reraster']]}
                for width, scale in [(393, 3), (1366, 2)]]}

    def test_mismatch_is_not_exact_success(self):
        report = self.fixture()
        self.assertEqual(runner.validate(report, 20261009, 100, False), 'exact-pixels')
        report['results'][0]['samples'][0]['pixels'][0].update(maxChannelDifference=250, pixelsOverOne=1)
        self.assertEqual(runner.validate(report, 20261009, 100, False), 'pixel-mismatch')

    def test_missing_work_nonfinite_and_wrong_order_rejected(self):
        for defect in ['missing-eviction', 'missing-tile', 'nan', 'skipped-event', 'wrong-order', 'wrong-history']:
            with self.subTest(defect=defect):
                report = copy.deepcopy(self.fixture())
                sample = report['results'][0]['samples'][0]
                if defect == 'missing-eviction': report['results'][0]['samples'].pop()
                if defect == 'missing-tile': sample['pixels'].pop()
                if defect == 'nan': sample['skiaCompletionMS'] = float('nan')
                if defect == 'skipped-event': sample['pixels'][0]['skiaEvents'] = 0
                if defect == 'wrong-order': sample['first'] = 'skia'
                if defect == 'wrong-history': report['fixture']['retainedEvents'] = 100
                self.assertEqual(runner.validate(report, 20261009, 100, False), 'invalid')

    def test_picture_policy_and_lifecycle(self):
        report = self.fixture()
        report.update(managedColors=True, cgPaths=True, reusePictures=True, pictureLimit=8388608)
        for result in report['results']:
            for sample in result['samples']:
                warm = sample['state'] == 'warm-reraster'
                sample.update(pictureBytes=1000, pictureCount=4, pictureHits=4 if warm else 0, pictureMisses=0 if warm else 4)
                for pixel in sample['pixels']: pixel['skiaPhaseMaxDifference'] = 0
        self.assertEqual(runner.validate(report, 20261009, 100, False, True, True, True), 'exact-pixels')
        for defect in ['ignored-flag', 'over-budget', 'stale-pixels', 'eviction-hit']:
            broken = copy.deepcopy(report)
            sample = broken['results'][0]['samples'][2]
            if defect == 'ignored-flag': broken['reusePictures'] = False
            if defect == 'over-budget': sample['pictureBytes'] = 8388609
            if defect == 'stale-pixels': sample['pixels'][0]['skiaPhaseMaxDifference'] = 2
            if defect == 'eviction-hit': sample['pictureHits'] = 4
            self.assertEqual(runner.validate(broken, 20261009, 100, False, True, True, True),
                'pixel-mismatch' if defect == 'stale-pixels' else 'invalid')
