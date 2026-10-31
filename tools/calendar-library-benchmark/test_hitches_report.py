import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('hitches_report', Path(__file__).with_name('report-hitches.py'))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class HitchesReportTests(unittest.TestCase):
    def test_wait_intersections_are_clipped_and_union_counted(self):
        self.assertEqual(report.overlapping_duration(10, 10, [(0, 12), (11, 15), (18, 30)]), 7)
        self.assertEqual(report.overlapping_duration(10, 10, [(0, 10), (20, 30)]), 0)

    def test_wait_diagnostic_does_not_erase_inclusive_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            (root/'hitches-framewait.xml').write_text((root/'hitches-renders.xml').read_text().replace('9000000','6000000'))
            result=report.summarize(root,123)
            self.assertEqual(result['renderWaitDiagnostic']['stats']['maxMS'],3)
            self.assertEqual(result['measuredWorkBudget'],'fail')

    def fixture(self, root, render_duration=9_000_000):
        def write(name, columns, rows):
            schema = ''.join('<col><mnemonic>'+name+'</mnemonic></col>' for name in columns)
            root.joinpath(name+'.xml').write_text('<result><schema>'+schema+'</schema>'+rows+'</result>')
        frame = '<start-time>100</start-time><duration>{}</duration><display-name>Display 1</display-name><uint32>42</uint32><uint32>10</uint32>'
        write('hitches-updates', ['start','duration','display','swap-id','surface-id','process'],
              '<row>'+frame.format(500_000)+'<process><pid id="p">123</pid></process></row>')
        for name, duration in [('hitches-renders',render_duration),('hitches-frame-lifetimes',25_000_000)]:
            write(name,['start','duration','display','swap-id','surface-id'],'<row>'+frame.format(duration)+'</row>')
        write('hitches',['start','duration','process'],'')
        write('display-vsyncs-interval',['timestamp'], '<row><start-time>0</start-time></row><row><start-time>8333333</start-time></row>')

    def test_no_hitches_does_not_erase_render_overrun(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            result=report.summarize(root,123)
            self.assertEqual(result['appHitchRows'],0)
            self.assertEqual(result['measuredWorkBudget'],'fail')
            self.assertEqual(result['timings']['associatedRenders']['stats']['over8_3MS'],1)

    def test_pipeline_lifetime_is_not_single_frame_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root,2_000_000)
            result=report.summarize(root,123)
            self.assertEqual(result['measuredWorkBudget'],'within-measured-intervals-only')
            self.assertEqual(result['status'],'analyzed-partial-evidence')

    def test_wrong_process_and_missing_compositor_coverage_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root)
            with self.assertRaises(ValueError):report.summarize(root,999)
            path=root/'hitches-renders.xml'
            path.write_text(path.read_text().replace('<uint32>42</uint32>','<uint32>43</uint32>'))
            with self.assertRaises(ValueError):report.summarize(root,123)

    def test_gpu_overrun_is_retained_independently(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); self.fixture(root,2_000_000)
            (root/'hitches-gpu.xml').write_text((root/'hitches-renders.xml').read_text().replace('2000000','10000000'))
            result=report.summarize(root,123)
            self.assertEqual(result['measuredWorkBudget'],'fail')
            self.assertEqual(result['timings']['associatedGPU']['stats']['maxMS'],10)

    def test_export_references_are_resolved(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'refs.xml'
            path.write_text('<r><schema><col><mnemonic>duration</mnemonic></col></schema><row><duration id="a">200</duration></row><row><duration ref="a"/></row></r>')
            self.assertEqual([row['duration'].text for row in report.table(path)],['200','200'])
