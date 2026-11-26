import importlib.util
import unittest
from pathlib import Path


path = Path(__file__).resolve().parents[1] / "physical-stress-tests" / "sample-power.py"
spec = importlib.util.spec_from_file_location("sample_power", path)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class PluggedPowerTests(unittest.TestCase):
    def test_negative_net_power_survives_the_charging_flag(self):
        fields = collector.power_fields({
            "IsCharging": True, "ExternalConnected": True, "InstantAmperage": (1 << 64) - 464,
            "AdapterDetails": {"Watts": 8, "SerialNumber": "ignored"},
            "PowerTelemetryData": {"SystemPowerIn": 7825, "SystemLoad": 8183, "BatteryPower": -358},
        })
        self.assertEqual(fields, {
            "IsCharging": True, "ExternalConnected": True, "InstantAmperage": -464,
            "adapterWatts": 8, "SystemPowerIn": 7825, "SystemLoad": 8183, "BatteryPower": -358,
        })

    def test_missing_measurements_remain_absent_and_zero_is_recorded(self):
        self.assertEqual(collector.power_fields({}), {})
        self.assertEqual(collector.power_fields({"PowerTelemetryData": {"BatteryPower": 0}}), {"BatteryPower": 0})
        self.assertEqual(collector.power_fields({"PowerTelemetryData": {"BatteryPower": (1 << 64) - 25}}), {"BatteryPower": -25})
