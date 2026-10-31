"""tools/private-text-check.sh finds denied text in a folder or a commit, minus the allowed literals;
tools/git-hooks/pre-push refuses a push with such a commit anywhere in it."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
GIT = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com']
Z40 = '0' * 40


def make_repo(root: Path) -> Path:
    src = root / 'repo'
    (src / 'tools' / 'git-hooks').mkdir(parents=True)
    shutil.copy(REPO / 'tools' / 'private-text-check.sh', src / 'tools' / 'private-text-check.sh')
    shutil.copy(REPO / 'tools' / 'git-hooks' / 'pre-push', src / 'tools' / 'git-hooks' / 'pre-push')
    subprocess.run(['git', 'init', '-q', '-b', 'main'], cwd=src, check=True)
    (root / 'deny').write_text('SECRETTOKEN\n@example\\.com\n')
    (root / 'allow').write_text('# public\nsupport@example.com\n')
    return src


def env_for(root: Path, deny=True):
    home = root / 'home'; home.mkdir(exist_ok=True)
    return dict(os.environ, HOME=str(home), BANANA_EXPORT_DENY=str(root / ('deny' if deny else 'absent')),
                BANANA_EXPORT_ALLOW=str(root / 'allow'))


def commit(src: Path, name: str, text: str, message: str) -> str:
    (src / name).parent.mkdir(parents=True, exist_ok=True)
    (src / name).write_text(text)
    subprocess.run(GIT + ['add', '-A'], cwd=src, check=True)
    subprocess.run(GIT + ['commit', '-q', '-m', message], cwd=src, check=True)
    return subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=src, capture_output=True, text=True, check=True).stdout.strip()


def check(src: Path, root: Path, *args, deny=True):
    return subprocess.run(['zsh', 'tools/private-text-check.sh', *args], cwd=src, env=env_for(root, deny),
                          capture_output=True, text=True)


def push(src: Path, root: Path, lines, deny=True):
    stdin = ''.join(f'{lref} {lsha} {rref} {rsha}\n' for lref, lsha, rref, rsha in lines)
    return subprocess.run(['zsh', 'tools/git-hooks/pre-push', 'origin', 'https://example.invalid/r.git'], cwd=src,
                          env=env_for(root, deny), input=stdin, capture_output=True, text=True)


class FolderTests(unittest.TestCase):
    def test_clean_folder_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            (src / 'a.md').write_text('nothing here\n')
            result = check(src, root, str(src))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_hit_is_listed_with_its_path_and_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            (src / 'notes.md').write_text('fine\nthe SECRETTOKEN is here\n')
            result = check(src, root, str(src))
            self.assertEqual(result.returncode, 1)
            self.assertIn('notes.md:2:the SECRETTOKEN is here', result.stdout)
            self.assertIn('1 lines in 1 files hold private text', result.stderr)

    def test_allowed_literal_passes_and_private_text_beside_it_does_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            (src / 'public.md').write_text('write to support@example.com\n')
            self.assertEqual(check(src, root, str(src)).returncode, 0)
            (src / 'mixed.md').write_text('support@example.com or boss@example.com\n')
            result = check(src, root, str(src))
            self.assertEqual(result.returncode, 1)
            self.assertIn('mixed.md:1:', result.stdout)

    def test_missing_deny_list_is_not_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            result = check(src, root, str(src), deny=False)
            self.assertEqual(result.returncode, 2)
            self.assertIn('nothing was checked for private text', result.stderr)


    def test_the_system_grep_path_finds_the_same_hit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            (src / 'notes.md').write_text('support@example.com\nthe SECRETTOKEN\n')
            env = dict(env_for(root), BANANA_CHECK_ENGINE='grep')
            result = subprocess.run(['zsh', 'tools/private-text-check.sh', str(src)], cwd=src, env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('notes.md:2:the SECRETTOKEN', result.stdout)
            self.assertNotIn('notes.md:1:', result.stdout)


class CommitTests(unittest.TestCase):
    def test_a_commit_is_checked_as_git_holds_it_not_the_worktree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            leaky = commit(src, 'notes.md', 'the SECRETTOKEN\n', 'leaky')
            clean = commit(src, 'notes.md', 'scrubbed\n', 'clean')
            (src / 'notes.md').write_text('SECRETTOKEN back in the worktree, uncommitted\n')
            self.assertEqual(check(src, root, '--commit', clean).returncode, 0)
            result = check(src, root, '--commit', leaky)
            self.assertEqual(result.returncode, 1)
            self.assertIn('notes.md:1:the SECRETTOKEN', result.stdout)


    def test_changes_mode_checks_only_what_the_commit_touched(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            first = commit(src, 'old.md', 'the SECRETTOKEN stays in an old file\n', 'root')
            second = commit(src, 'new.md', 'a clean addition\n', 'clean change')
            self.assertEqual(check(src, root, '--commit', second).returncode, 1, 'the whole tree still leaks')
            self.assertEqual(check(src, root, '--changes', second).returncode, 0, 'the change itself is clean')
            self.assertEqual(check(src, root, '--changes', first).returncode, 1, 'a root commit is checked whole')
            third = commit(src, 'new.md', 'now with SECRETTOKEN\n', 'leaky change')
            result = check(src, root, '--changes', third)
            self.assertEqual(result.returncode, 1)
            self.assertIn('new.md:1:', result.stdout)
            self.assertNotIn('old.md', result.stdout)

    def test_a_commit_that_only_deletes_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            commit(src, 'old.md', 'the SECRETTOKEN\n', 'root')
            (src / 'old.md').unlink()
            subprocess.run(GIT + ['add', '-A'], cwd=src, check=True)
            subprocess.run(GIT + ['commit', '-q', '-m', 'delete'], cwd=src, check=True)
            self.assertEqual(check(src, root, '--changes', 'HEAD').returncode, 0)


class PrePushTests(unittest.TestCase):
    def test_refuses_a_leaky_commit_behind_a_clean_tip(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            commit(src, 'notes.md', 'the SECRETTOKEN\n', 'leaky')
            tip = commit(src, 'notes.md', 'scrubbed\n', 'clean')
            result = push(src, root, [('refs/heads/main', tip, 'refs/heads/main', Z40)])
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('holds private text; nothing was pushed', result.stderr)

    def test_pushes_only_the_new_commits_and_passes_when_they_are_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            leaky = commit(src, 'notes.md', 'the SECRETTOKEN\n', 'leaky')
            tip = commit(src, 'notes.md', 'scrubbed\n', 'clean')
            result = push(src, root, [('refs/heads/main', tip, 'refs/heads/main', leaky)])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_refuses_a_tracked_file_under_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            tip = commit(src, 'private/plan.md', 'off the record\n', 'oops')
            result = push(src, root, [('refs/heads/main', tip, 'refs/heads/main', Z40)])
            self.assertEqual(result.returncode, 1)
            self.assertIn('tracks files under private/', result.stderr)

    def test_refuses_when_the_deny_list_is_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            tip = commit(src, 'a.md', 'clean\n', 'clean')
            result = push(src, root, [('refs/heads/main', tip, 'refs/heads/main', Z40)], deny=False)
            self.assertEqual(result.returncode, 1)

    def test_a_deleted_branch_is_not_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); src = make_repo(root)
            commit(src, 'a.md', 'clean\n', 'clean')
            result = push(src, root, [('(delete)', Z40, 'refs/heads/old', 'f' * 40)], deny=False)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
