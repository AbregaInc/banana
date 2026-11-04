import importlib.util
import json
from pathlib import Path
import plistlib
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('migration', Path(__file__).with_name('migration.py'))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def test_owned_files_only_and_no_source_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / 'source'; source.mkdir()
            (source / 'wellness.json').write_text('{"fixture":true}')
            (source / 'unrelated.json').write_text('leave alone')
            before = migration.inventory(source, ['wellness.json', 'unrelated.json'])
            migration.snapshot(source, root / 'snapshot', ['wellness.json'])
            self.assertEqual(migration.inventory(source, ['wellness.json', 'unrelated.json']), before)
            self.assertFalse((root / 'snapshot/unrelated.json').exists())
            with self.assertRaises(ValueError): migration.snapshot(source, root / 'snapshot', ['wellness.json'])

    def test_symlink_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / 'source'; source.mkdir()
            (root / 'outside').write_text('private fixture')
            (source / 'wellness.json').symlink_to(root / 'outside')
            with self.assertRaises(ValueError): migration.snapshot(source, root / 'snapshot', ['wellness.json'])

    def test_sqlite_wal_rows_survive_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / 'source'; source.mkdir()
            db = sqlite3.connect(source / 'podcast-catalog.sqlite')
            db.execute('PRAGMA journal_mode=WAL'); db.execute('PRAGMA wal_autocheckpoint=0')
            db.execute('CREATE TABLE fixture (value TEXT)'); db.execute("INSERT INTO fixture VALUES ('retained')"); db.commit()
            try:
                migration.snapshot(source, root / 'snapshot', ['podcast-catalog.sqlite', 'podcast-catalog.sqlite-wal', 'podcast-catalog.sqlite-shm'])
                with sqlite3.connect(root / 'snapshot/podcast-catalog.sqlite') as copied:
                    self.assertEqual(copied.execute('SELECT value FROM fixture').fetchall(), [('retained',)])
            finally: db.close()

    def test_corrupt_database_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / 'source'; source.mkdir()
            (source / 'podcast-catalog.sqlite').write_text('broken')
            with self.assertRaises(sqlite3.DatabaseError):
                migration.snapshot(source, root / 'snapshot', ['podcast-catalog.sqlite'])

    def test_manifest_covers_same_explicit_roots(self):
        root = Path(__file__).resolve().parents[2]
        manifest = plistlib.loads((root / 'BananaMac/container-migration.plist').read_bytes())
        self.assertEqual(manifest['Move'], ['${ApplicationSupport}/' + n for n in migration.roots()]
                         + ['${Library}/Preferences/${BundleId}.plist'])
        self.assertNotIn('${ApplicationSupport}', manifest['Move'])
        self.assertNotIn('notes.json', migration.roots())  # lives inside VoiceNotes, not the shared root

    def test_changes_during_copy_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root / 'source'; source.mkdir()
            (source / 'wellness.json').write_text('before')
            copy = migration.shutil.copy2
            def concurrent_write(src, dest):
                result = copy(src, dest); src.write_text('changed'); return result
            with patch.object(migration.shutil, 'copy2', side_effect=concurrent_write):
                with self.assertRaises(RuntimeError): migration.snapshot(source, root / 'snapshot', ['wellness.json'])


if __name__ == '__main__': unittest.main()
