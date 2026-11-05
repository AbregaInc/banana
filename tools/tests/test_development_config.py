import os
import pathlib
import subprocess
import tempfile
import unittest

CONFIG = pathlib.Path(__file__).resolve().parents[1] / 'config.sh'


class DevelopmentConfigurationTests(unittest.TestCase):
    def check(self, **overrides):
        settings = {
            'BANANA_SERVICE_HOST': 'service.example',
            'BANANA_SERVICE_HOST_DEV': 'staging.example',
            'BANANA_GOOGLE_CLIENT': 'stable-native',
            'BANANA_GOOGLE_CLIENT_DEV': 'dev-native',
            'BANANA_GOOGLE_SERVER_CLIENT': 'stable-server',
            'BANANA_GOOGLE_SERVER_CLIENT_DEV': 'staging-server',
        }
        settings.update(overrides)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'Config').mkdir()
            (root / 'Config/Base.xcconfig').write_text(''.join(f'{k} = {v}\n' for k, v in settings.items()))
            return subprocess.run(['sh', '-c', '. "$1"; banana_require_dev', 'check', str(CONFIG)],
                                  cwd=root, env={**os.environ, 'BANANA_NO_LOCAL_CONFIG': '1'},
                                  capture_output=True, text=True).returncode

    def test_isolated_config_passes(self):
        self.assertEqual(self.check(), 0)

    def test_missing_or_production_credentials_fail_before_install(self):
        for field, stable in [('BANANA_SERVICE_HOST_DEV', 'service.example'),
                              ('BANANA_GOOGLE_CLIENT_DEV', 'stable-native'),
                              ('BANANA_GOOGLE_SERVER_CLIENT_DEV', 'stable-server')]:
            for value in ['', stable]:
                with self.subTest(field=field, value=value):
                    self.assertNotEqual(self.check(**{field: value}), 0)

    def test_official_production_or_url_instead_of_hostname_is_refused(self):
        for host in ['api.bananatheapp.com', 'https://staging.example', 'staging.example/path']:
            with self.subTest(host=host):
                self.assertNotEqual(self.check(BANANA_SERVICE_HOST_DEV=host), 0)


class SigningConfigurationTests(unittest.TestCase):
    def invoke(self, key_exists=True, configured=True):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'Config').mkdir()
            key = root / 'signing key.p8'
            if key_exists:
                key.write_text('test-only-placeholder')
            command = root / 'xcodebuild'
            command.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            command.chmod(0o755)
            env = {k: v for k, v in os.environ.items()
                   if k not in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_PATH', 'AUTH_ARGS')}
            env.update(PATH=str(root) + os.pathsep + env.get('PATH', ''), BANANA_NO_LOCAL_CONFIG='1')
            if configured:
                env.update(ASC_KEY_ID='test-key', ASC_ISSUER_ID='test-issuer', ASC_KEY_PATH=str(key))
            return subprocess.run(['sh', '-c', '. "$1"; banana_xcodebuild -scheme "Banana Dev" build',
                                   'check', str(CONFIG)], cwd=root, env=env, capture_output=True, text=True)

    def test_configured_key_is_passed_as_separate_arguments(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0)
        args = result.stdout.splitlines()
        self.assertEqual(args[0], '-authenticationKeyPath')
        self.assertTrue(args[1].endswith('/signing key.p8'))
        self.assertEqual(args[-3:], ['-scheme', 'Banana Dev', 'build'])

    def test_missing_configured_key_stops_before_xcode(self):
        result = self.invoke(key_exists=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('-scheme', result.stdout)

    def test_interactive_xcode_login_remains_supported(self):
        result = self.invoke(configured=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), ['-scheme', 'Banana Dev', 'build'])


if __name__ == '__main__':
    unittest.main()
