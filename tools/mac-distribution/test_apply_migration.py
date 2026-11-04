import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('apply_migration', Path(__file__).with_name('apply-migration.py'))
apply = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apply)


class ApplyMigrationTests(unittest.TestCase):
    def fixture(self, root):
        source, target = root / 'source', root / 'target'
        source.mkdir(); target.mkdir()
        (source / 'wellness.json').write_text('current local')
        (target / 'wellness.json').write_text('older sandbox')
        (target / 'routines.json').write_text('sandbox only')
        (target / 'unrelated').write_text('untouched')
        names = ['wellness.json', 'routines.json']
        expected = apply.migration.inventory(target, names)
        return source, target, names, expected

    def test_selected_store_replaces_without_merging_and_retains_old(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, target, names, expected = self.fixture(root)
            apply.replace_roots(source, target, root / 'transaction', names, expected,
                                lambda: None, lambda: None, lambda: None)
            self.assertEqual((target / 'wellness.json').read_text(), 'current local')
            self.assertFalse((target / 'routines.json').exists())
            self.assertEqual((target / 'unrelated').read_text(), 'untouched')
            self.assertEqual(apply.migration.inventory(root / 'transaction/displaced', names), expected)
            self.assertEqual((source / 'wellness.json').read_text(), 'current local')

    def test_preference_failure_rolls_back_all_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, target, names, expected = self.fixture(root)
            rollback = []
            def fail(): raise RuntimeError('simulated preference failure')
            with self.assertRaises(RuntimeError):
                apply.replace_roots(source, target, root / 'transaction', names, expected,
                                    lambda: None, fail, lambda: rollback.append(True))
            self.assertEqual(apply.migration.inventory(target, names), expected)
            self.assertEqual(rollback, [True])

    def test_live_change_refuses_without_overwriting(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, target, names, expected = self.fixture(root)
            (target / 'wellness.json').write_text('new edit')
            with self.assertRaises(RuntimeError):
                apply.replace_roots(source, target, root / 'transaction', names, expected,
                                    lambda: None, lambda: None, lambda: None)
            self.assertEqual((target / 'wellness.json').read_text(), 'new edit')

    def test_running_app_guard_prevents_any_live_move(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, target, names, expected = self.fixture(root)
            def fail(): raise RuntimeError('app running')
            with self.assertRaises(RuntimeError):
                apply.replace_roots(source, target, root / 'transaction', names, expected,
                                    fail, lambda: None, lambda: None)
            self.assertEqual(apply.migration.inventory(target, names), expected)


if __name__ == '__main__': unittest.main()
