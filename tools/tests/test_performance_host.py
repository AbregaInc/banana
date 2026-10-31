import importlib.util
from pathlib import Path
import unittest
import tempfile
import json
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('performance_host', Path(__file__).resolve().parents[1] / 'performance_host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class HostMonitorTests(unittest.TestCase):
    def test_workload_descendants_are_retained_separately_from_competitors(self):
        # Deliberately list grandchildren before parents; process snapshots are unordered.
        processes = '103 102 /Xcode Beta/usr/bin/xctest\n102 101 helper\n101 90 swift-test\n104 90 xctest\n105 1 swift-frontend\n'
        external, workload = host.classify_developer_processes(processes, 101)
        self.assertEqual([p['pid'] for p in workload], [103])
        self.assertEqual([p['pid'] for p in external], [104, 105])
        with patch.object(host.subprocess, 'check_output', return_value=processes):
            with host.HostMonitor(workload_pid=101) as monitor:
                pass
        self.assertFalse(monitor.report()['clean'])
        self.assertTrue(monitor.report()['workloadDeveloperProcesses'])

    def test_only_known_workload_tree_can_be_excluded(self):
        with patch.object(host.subprocess, 'check_output', return_value='102 101 xctest\n'):
            with host.HostMonitor(workload_pid=101) as monitor:
                pass
        self.assertTrue(monitor.report()['clean'])
        self.assertEqual(monitor.report()['workloadPID'], 101)
        self.assertTrue(monitor.report()['workloadDeveloperProcesses'])
        external, workload = host.classify_developer_processes('102 1 xctest\n', 101)
        self.assertEqual([p['pid'] for p in external], [102])
        self.assertEqual(workload, [])

    def test_load_is_retained_without_calling_it_cpu_utilization(self):
        with patch.object(host.os, 'getloadavg', return_value=(300, 200, 100)), \
             patch.object(host.subprocess, 'check_output', return_value=''):
            with host.HostMonitor() as monitor:
                pass
        self.assertEqual(monitor.report()['loadSamples'][0]['loadAverage'], [300, 200, 100])
        self.assertIn('other system contention may be missed', monitor.report()['scope'])

    def test_only_developer_executables_are_recorded(self):
        found = host.developer_processes('12 /Applications/Xcode Beta.app/usr/bin/xcodebuild\n13 swift-frontend\n14 CalendarLibraryBenchmark\n15 xctest\n16 ps\n')
        self.assertEqual([p['pid'] for p in found], [12, 13, 15])

    def test_overlapping_process_prevents_clean_evidence(self):
        with patch.object(host.subprocess, 'check_output', return_value='12 xcodebuild\n'):
            with host.HostMonitor() as monitor:
                pass
        self.assertFalse(monitor.report()['clean'])
        self.assertGreaterEqual(len(monitor.report()['overlappingDeveloperProcesses']), 2)

    def test_sampling_failure_is_retained(self):
        with patch.object(host.subprocess, 'check_output', side_effect=OSError('ps unavailable')):
            with host.HostMonitor() as monitor:
                pass
        self.assertFalse(monitor.report()['clean'])
        self.assertTrue(monitor.report()['errors'])

    def test_clean_samples_and_exception_propagation(self):
        with patch.object(host.subprocess, 'check_output', return_value='14 CalendarLibraryBenchmark\n'):
            with self.assertRaisesRegex(ValueError, 'workload failure'):
                with host.HostMonitor() as monitor:
                    raise ValueError('workload failure')
        self.assertTrue(monitor.report()['clean'])

    def test_metadata_survives_a_failed_workload(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'host.json'
            with patch.object(host.subprocess, 'check_output', return_value='12 xcodebuild\n'):
                with self.assertRaises(ValueError):
                    with host.HostMonitor(output):
                        raise ValueError('workload failed')
            saved = json.loads(output.read_text())
            self.assertFalse(saved['clean'])
            self.assertGreaterEqual(saved['samples'], 2)
