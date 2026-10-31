import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('redact_evidence', Path(__file__).resolve().parents[1] / 'redact-evidence.py')
redact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(redact)


class RedactEvidenceTests(unittest.TestCase):
    def test_udids_home_paths_and_deny_patterns_go_and_numbers_stay(self):
        deny = [__import__('re').compile(r'\bAyePad\b'), __import__('re').compile('TEAMID1234')]
        text = json.dumps({'device': '00001234-0000ABCDEF123456', 'instrumentsDevice': 'AyePad (27.0.1)',
                           'command': ['/Users/someone/repo/tools/x.py', '--team', 'TEAMID1234'], 'p50MS': 11.75})
        out = redact.redact(text, deny)
        data = json.loads(out)
        self.assertEqual(data['device'], '<device-udid>')
        self.assertEqual(data['instrumentsDevice'], '<redacted> (27.0.1)')
        self.assertEqual(data['command'], ['~/repo/tools/x.py', '--team', '<redacted>'])
        self.assertEqual(data['p50MS'], 11.75)

    def test_rewrites_text_files_in_place_and_leaves_binaries_and_clean_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dirty = root / 'run' / 'status.json'; dirty.parent.mkdir()
            dirty.write_text('{"device": "00005678-0000FEDCBA654321"}')
            clean = root / 'run' / 'clean.json'; clean.write_text('{"ok": true}')
            binary = root / 'run' / 'trace.bin'; binary.write_bytes(b'\xff\xfe00005678-0000FEDCBA654321\x00')
            changed = redact.redact_tree([root], [])
            self.assertEqual(changed, [dirty])
            self.assertEqual(dirty.read_text(), '{"device": "<device-udid>"}')
            self.assertEqual(clean.read_text(), '{"ok": true}')
            self.assertIn(b'00005678', binary.read_bytes())

    def test_deny_file_comments_and_blank_lines_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            deny = Path(tmp) / 'deny'; deny.write_text('# comment\n\nSECRET\n')
            self.assertEqual([p.pattern for p in redact.patterns(deny)], ['SECRET'])
            self.assertEqual(redact.patterns(None), [])


if __name__ == '__main__':
    unittest.main()
