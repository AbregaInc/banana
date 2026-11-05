import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release_plan', Path(__file__).with_name('release-plan.py'))
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


class ReleasePlanTests(unittest.TestCase):
    def test_increments_past_existing_drafts_and_ignores_other_platforms(self):
        value = plan.make_plan('1.0.1', '86', ['mac-v1.0-90', 'ios-v1.0-300'], 'a' * 40)
        self.assertEqual(value['version'], '91')
        self.assertTrue(value['baseURL'].endswith('/mac-v1.0.1-91'))
        plan.validate_plan(value, 'a' * 40)

    def test_other_commit_cannot_reuse_plan(self):
        value = plan.make_plan('1.0.1', '86', [], 'a' * 40)
        with self.assertRaises(ValueError): plan.validate_plan(value, 'b' * 40)

    def test_version_and_commit_validation(self):
        for version, commit in [('abc123', 'a' * 40), ('1.0.1', 'abc123')]:
            with self.assertRaises(ValueError): plan.make_plan(version, '86', [], commit)

    def test_dirty_checkout_rejected(self):
        with patch.object(plan, 'run', return_value=' M changed.swift'):
            with self.assertRaises(ValueError): plan.clean_commit()


if __name__ == '__main__': unittest.main()
