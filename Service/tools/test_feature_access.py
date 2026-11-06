import importlib.util
import pathlib
import sqlite3
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('feature_access', pathlib.Path(__file__).with_name('feature-access.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FeatureAccessAdminTests(unittest.TestCase):
    def test_remote_update_uses_query_mode_that_returns_the_receipt(self):
        result = SimpleNamespace(returncode=0, stdout='[{"success":true,"results":[{"accounts_updated":1}]}]')
        with patch('sys.argv', ['feature-access.py', '--environment', 'beta', '--account',
                               'test-account', '--feature', 'email', '--access', 'grant', '--apply']), \
             patch.object(module.subprocess, 'run', return_value=result) as run, patch('builtins.print'):
            module.main()
        command = run.call_args.args[0]
        self.assertNotIn('--file', command, 'remote imports omit the update receipt')
        self.assertIn('SELECT changes()', command[command.index('--command') + 1])
        self.assertEqual(command[command.index('--env') + 1], 'beta')

    def test_existing_identity_required_and_revoke_is_retained(self):
        db = sqlite3.connect(':memory:')
        db.execute('CREATE TABLE accounts (id TEXT PRIMARY KEY)')
        db.execute('CREATE TABLE devices (account_id TEXT, provider_protocol INTEGER)')
        db.executescript((module.SERVICE / 'migrations/0014_feature_access.sql').read_text())
        db.executescript(module.statement('absent', 'email', True, None, 100))
        self.assertEqual(db.execute('SELECT count(*) FROM feature_access').fetchone()[0], 0)
        db.execute("INSERT INTO accounts VALUES ('test-account')")
        db.executescript(module.statement('test-account', 'email', True, 200, 100))
        self.assertEqual(db.execute('SELECT enabled, expires_at FROM feature_access').fetchone(), (1, 200))
        db.executescript(module.statement('test-account', 'email', False, None, 110))
        self.assertEqual(db.execute('SELECT enabled, expires_at, updated_at FROM feature_access').fetchone(), (0, None, 110))

    def test_grant_waits_for_every_registered_device_to_upgrade(self):
        db = sqlite3.connect(':memory:')
        db.execute('CREATE TABLE accounts (id TEXT PRIMARY KEY)')
        db.execute('CREATE TABLE devices (account_id TEXT, provider_protocol INTEGER)')
        db.executescript((module.SERVICE / 'migrations/0014_feature_access.sql').read_text())
        db.execute("INSERT INTO accounts VALUES ('test-account')")
        db.execute("INSERT INTO devices VALUES ('test-account', 0)")
        db.executescript(module.statement('test-account', 'calendarCloud', True, None, 100))
        self.assertEqual(db.execute('SELECT count(*) FROM feature_access').fetchone()[0], 0)
        db.execute('UPDATE devices SET provider_protocol=1')
        db.executescript(module.statement('test-account', 'calendarCloud', True, None, 101))
        self.assertEqual(db.execute('SELECT enabled FROM feature_access').fetchone()[0], 1)

    def test_invalid_input_rejected(self):
        for args in [("a';DELETE FROM accounts;--", 'email', True, None, 100),
                     ('account', 'anything', True, None, 100),
                     ('account', 'email', True, 99, 100)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                module.statement(*args)

    def test_update_receipt_refuses_missing_accounts_and_old_devices(self):
        def receipt(**row):
            return [{'success': True, 'results': [row]}]
        module.verify_result(receipt(accounts_updated=1, account_exists=1, outdated_devices=0))
        with self.assertRaisesRegex(ValueError, 'does not exist'):
            module.verify_result(receipt(accounts_updated=0, account_exists=0, outdated_devices=0))
        with self.assertRaisesRegex(ValueError, '3 registered device'):
            module.verify_result(receipt(accounts_updated=0, account_exists=1, outdated_devices=3))
        for payload in [[], [{'success': False}], receipt(accounts_updated=2),
                        receipt(accounts_updated=0, account_exists=1, outdated_devices=0)]:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                module.verify_result(payload)
