import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('live', Path(__file__).with_name('report-live-metal.py'))
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)


def frame(**values):
    return dict(kind='frame', requested=1.0, began=1.001, encoded=1.002,
                presented=1.006, input=1.0, date=5, ok=1, **values)


class ReportTests(unittest.TestCase):
    def test_dropped_is_never_counted_as_fast(self):
        value = frame(); value['presented'] = 0
        result = live.report([value])
        self.assertEqual(result['presentedFrames'], 0)
        self.assertEqual(len(result['unpresentedOrInvalid']), 1)
        self.assertEqual(result['acceptance'], 'unmeasured')

    def test_fast_samples_cannot_certify_full_acceptance(self):
        self.assertEqual(live.report([frame()])['acceptance'], 'unmeasured')

    def test_slow_cold_page_is_failure(self):
        request = dict(kind='pageRequest', time=.8, date=5, cached=False)
        result = live.report([request, frame()])
        self.assertEqual(result['acceptance'], 'failed')
        self.assertEqual(len(result['violations']['pageOver100']), 1)

    def test_superseded_request_cannot_borrow_later_frame(self):
        requests = [dict(kind='pageRequest', time=t, date=5, cached=True) for t in (.7, .9)]
        result = live.report(requests + [frame()])
        self.assertEqual(len(result['unmatchedPageRequests']), 1)
        self.assertEqual(len(result['pageSamples']), 1)

    def test_slow_encode_retained_when_presentation_missing(self):
        value = frame(); value.update(encoded=1.1, presented=0)
        self.assertEqual(live.report([value])['acceptance'], 'failed')

    def test_later_scroll_does_not_replace_missing_page_presentation(self):
        request = dict(kind='pageRequest', time=.9, date=5, cached=False)
        missing = frame(); missing['presented'] = 0
        later = frame(); later.update(requested=2., began=2.001, encoded=2.002, presented=2.006)
        result = live.report([request, missing, later])
        self.assertEqual(result['coldPageMS']['count'], 0)
        self.assertEqual(len(result['unmatchedPageRequests']), 1)

if __name__ == '__main__':
    unittest.main()
