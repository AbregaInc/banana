import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('metal_runner', Path(__file__).with_name('run-metal-tiles.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class MetalEvidenceTests(unittest.TestCase):
    def report(self):
        cases = []
        for width, scale in [(393, 3), (1366, 2)]:
            samples = [dict(trial=trial, state=state, offsetPixels=offset, uploadMS=1,
                cpuCompositeMS=1, metal=dict(encodeSubmitMS=1, completionMS=1, gpuMS=1),
                maxChannelDifference=0)
                for trial in range(3) for state in ['cold-upload', 'warm', 'eviction-reupload']
                for offset in [0, 128 * scale, 256 * scale, 0]]
            cases.append(dict(widthPoints=width, scale=scale, samples=samples))
        return dict(textureSource='surface-shared', fixture=dict(seed='1', meanDailyEvents=100,
            calendarCount=12, retainedEvents=36500), results=cases)

    def test_old_binary_or_wrong_source_cannot_pass(self):
        data = self.report()
        self.assertTrue(runner.valid_report(data, 1, 100, 'surface-shared'))
        self.assertFalse(runner.valid_report(data, 1, 100, 'surface-copy'))
        del data['textureSource']
        self.assertFalse(runner.valid_report(data, 1, 100, 'surface-shared'))

    def test_wrong_pixels_missing_eviction_and_nonfinite_fail(self):
        for mutation in ['pixels', 'eviction', 'nan']:
            data = copy.deepcopy(self.report())
            sample = data['results'][0]['samples'][0]
            if mutation == 'pixels': sample['maxChannelDifference'] = 2
            if mutation == 'nan': sample['metal']['gpuMS'] = float('nan')
            if mutation == 'eviction':
                for s in data['results'][0]['samples']:
                    if s['state'] == 'eviction-reupload': s['state'] = 'warm'
            self.assertFalse(runner.valid_report(data, 1, 100, 'surface-shared'))


if __name__ == '__main__': unittest.main()
