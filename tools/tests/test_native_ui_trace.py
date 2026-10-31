import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('native_trace', Path(__file__).parents[1] / 'native-ui-trace.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeTraceTests(unittest.TestCase):
    def report(self, durations, complete=True):
        with tempfile.TemporaryDirectory() as tmp:
            commits = Path(tmp) / 'commits.xml'
            loops = Path(tmp) / 'loops.xml'
            rows = ''.join(f'<row><start-time>0</start-time><duration>{int(d*1e6)}</duration>'
                           '<sentinel/><thread fmt="Main Thread (app)"/></row>' for d in durations)
            commits.write_text('<root>'+rows+'</root>')
            loops.write_text('<root/>')
            return module.summarize(commits, loops, complete)

    def testSlowCommitFailsEvenIfRecordingIncomplete(self):
        r = self.report([1, 8.3, 101], False)
        self.assertEqual(r['status'], 'fail')
        self.assertEqual(r['commits']['maxMS'], 101)
        self.assertEqual(len(r['commits']['violations']), 1)
        self.assertFalse(r['recordingComplete'])

    def testFastCommitsNeverCertifyVisibleLatency(self):
        self.assertEqual(self.report([1, 8.3])['status'], 'unmeasured')

    def testMissingCommitsNeverPass(self):
        self.assertEqual(self.report([])['status'], 'unmeasured')

    def testReferenceElementsAreResolved(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'table.xml'
            p.write_text('<root><row><duration id="1">5000000</duration></row>'
                         '<row><duration ref="1"/></row></root>')
            self.assertEqual(module.table_rows(p)[1][0].text, '5000000')

    def loop(self, start, duration, kind='Busy', main=True):
        return list(ET.fromstring(f'<row><start>{int(start*1e6)}</start><duration>{int(duration*1e6)}</duration>'
            f'<kind>{kind}</kind><unused/><unused/><unused/><unused/><main>{int(main)}</main></row>'))

    def testNestedButtonTrackingWaitIsNotUninterruptedWork(self):
        rows=[self.loop(0,100),self.loop(5,90,'Waiting For Events'),self.loop(3,2),self.loop(95,5)]
        result=module.nonwaiting_busy(rows)
        self.assertEqual(result['samples'],[{'startMS':0,'durationMS':5},{'startMS':95,'durationMS':5}])
        self.assertEqual(result['violations'],[])

    def testNestedOverlapsDoNotDoubleCountAndSlowWorkRemains(self):
        rows=[self.loop(0,100),self.loop(1,98),self.loop(10,80,'Waiting For Events'),
              self.loop(12,76,'Waiting For Events'),self.loop(100,500,main=False)]
        result=module.nonwaiting_busy(rows)
        self.assertEqual(result['count'],2)
        self.assertEqual(result['maxMS'],10)
        self.assertEqual(len(result['violations']),2)

    def testWaitingOutsideBusyAndEmptyDataCannotInventWork(self):
        self.assertEqual(module.nonwaiting_busy([])['count'],0)
        result=module.nonwaiting_busy([self.loop(10,5),self.loop(0,11,'Waiting For Events'),
                                       self.loop(13,10,'Waiting For Events')])
        self.assertEqual(result['samples'],[{'startMS':11,'durationMS':2}])
