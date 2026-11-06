import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('select_ios_device', Path(__file__).parents[1] / 'select-ios-device.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def device(identifier, reality, kind='iPhone'):
    return {'identifier': identifier, 'hardwareProperties': {'reality': reality, 'deviceType': kind, 'udid': 'udid-' + identifier}}


class PhysicalDeviceSelectionTests(unittest.TestCase):
    def test_simulator_does_not_compete_with_physical_phone(self):
        self.assertEqual(module.select({'result': {'devices': [device('sim', 'simulated'), device('phone', 'physical')]}}), 'phone')

    def test_explicit_simulator_and_unknown_reality_are_refused(self):
        for reality in ['simulated', None]:
            with self.assertRaises(ValueError):
                module.select({'result': {'devices': [device('sim', reality)]}}, 'sim')

    def test_multiple_physical_devices_require_explicit_selection(self):
        inventory = {'result': {'devices': [device('phone', 'physical'), device('pad', 'physical', 'iPad')]}}
        with self.assertRaises(ValueError):
            module.select(inventory)
        self.assertEqual(module.select(inventory, 'udid-pad'), 'pad')
