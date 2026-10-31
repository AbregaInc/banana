"""tools/public-export.sh must refuse a tree that holds denied text, however many hits."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


def make_private_repo(root: Path, denied_lines: int) -> Path:
    src = root / 'private'
    (src / 'tools').mkdir(parents=True)
    shutil.copy(REPO / 'tools' / 'public-export.sh', src / 'tools' / 'public-export.sh')
    shutil.copy(REPO / 'tools' / 'private-text-check.sh', src / 'tools' / 'private-text-check.sh')
    (src / 'tools' / 'public-export.exclude').write_text('tools/public-export.sh\ntools/public-export.exclude\n')
    (src / 'project.yml').write_text('settings:\n  MARKETING_VERSION: "1.0"\n  CURRENT_PROJECT_VERSION: "1"\n')
    (src / 'notes.md').write_text(''.join(f'line {i} SECRETTOKEN here\n' for i in range(denied_lines)) or 'clean\n')
    (src / 'clean.md').write_text('nothing private\n')
    git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com']
    subprocess.run(['git', 'init', '-q', '-b', 'main'], cwd=src, check=True)
    subprocess.run(git + ['add', '-A'], cwd=src, check=True)
    subprocess.run(git + ['commit', '-q', '-m', 'private'], cwd=src, check=True)
    return src


def run_export(src: Path, root: Path, deny):
    deny_file = root / 'deny'
    if deny is not None:
        deny_file.write_text(deny)
    home = root / 'home'; home.mkdir(exist_ok=True)
    env = dict(os.environ, HOME=str(home), BANANA_EXPORT_DENY=str(deny_file), BANANA_EXPORT_ALLOW=str(root / 'allow'),
               BANANA_PUBLIC_NAME='Public', BANANA_PUBLIC_EMAIL='public@example.com')
    out = root / 'public'
    result = subprocess.run(['zsh', 'tools/public-export.sh', str(out)], cwd=src, env=env, capture_output=True, text=True)
    return result, out


class PublicExportDenyTests(unittest.TestCase):
    def test_refuses_more_than_two_hundred_denied_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_private_repo(root, denied_lines=300)
            result, out = run_export(src, root, 'SECRETTOKEN\n')
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('300 lines in 1 files hold private text', result.stderr)
            self.assertFalse((out / '.git').exists(), 'nothing may be committed')

    def test_refuses_a_single_denied_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_private_repo(root, denied_lines=1)
            result, out = run_export(src, root, 'SECRETTOKEN\n')
            self.assertEqual(result.returncode, 1)
            self.assertFalse((out / '.git').exists())

    def test_refuses_to_export_unchecked_when_the_deny_list_is_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_private_repo(root, denied_lines=0)
            result, out = run_export(src, root, None)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('nothing was checked for private text', result.stderr)
            self.assertFalse((out / '.git').exists())

    def test_exports_a_clean_tree_as_one_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_private_repo(root, denied_lines=0)
            result, out = run_export(src, root, 'SECRETTOKEN\n')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            log = subprocess.run(['git', 'log', '--format=%an %s'], cwd=out, capture_output=True, text=True).stdout
            self.assertEqual(log.strip(), 'Public Banana 1.0 (1)')
            self.assertFalse((out / 'tools' / 'public-export.sh').exists())


if __name__ == '__main__':
    unittest.main()
