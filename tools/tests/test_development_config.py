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


if __name__ == '__main__':
    unittest.main()
