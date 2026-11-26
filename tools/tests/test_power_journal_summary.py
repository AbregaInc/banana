from pathlib import Path
import runpy
import unittest


summarize = runpy.run_path(str(Path(__file__).resolve().parents[1] / "power-journal-summary.py"))["summarize"]


class PowerJournalTests(unittest.TestCase):
    def test_transport_errors_count_once_without_identifiers(self):
        rows = [
            "11-24 12:00:00.001  ☁️ account  PUT /v1/devices/private-id failed: The request timed out.",
            "11-24 12:00:00.002  mail read  cloud pull unknownOutcome",
            "11-24 12:00:01.001  ☁️ account  GET /private-path failed: offline",
            "11-23 12:00:01.001  ☁️ account  POST /v1/mail/read failed: offline",
        ]
        result = summarize(rows, "11-24")
        self.assertEqual(result["byEndpoint"], {"device registration": {"failures": 1, "timeouts": 1},
                                               "other": {"failures": 1, "timeouts": 0}})
        self.assertEqual(result["minutesWithMultipleFailures"], 1)
        self.assertIsNone(result["firstBattery"])

    def test_battery_order_and_individually_reported_elapsed_time(self):
        rows = [
            "11-24 12:00:59.000  ⚡ POWER 60s  cpu=9.0% avg/10% max scene=foreground "
            "battery=73%/charging transcribe=idle done=[transcription×1/4ms]",
            "11-24 11:59:59.000  ⚡ POWER 60s  cpu=7.0% avg/8% max scene=foreground "
            "battery=80%/charging transcribe=2active done=[transcription×2/100ms]",
        ]
        result = summarize(rows, "11-24")
        self.assertEqual(len(result["observedDecreases"]), 1)
        self.assertEqual(result["firstBattery"]["percent"], 80)
        self.assertEqual(result["longestIndividuallyReportedTranscriptionElapsedMS"], 4)
        self.assertEqual(result["highestSampledProcessCPUAvgPctWithTranscriptionActive"], 7)
