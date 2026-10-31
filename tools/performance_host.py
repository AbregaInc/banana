"""Retain sampled competing developer workloads without stopping or altering them."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import threading
import time

DEVELOPER_PROCESSES = {'xcodebuild', 'swift-frontend', 'swiftc', 'xctest'}


def developer_processes(output):
    result = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        name = Path(fields[1]).name
        if name in DEVELOPER_PROCESSES:
            result.append({'pid': int(fields[0]), 'process': name})
    return result


def classify_developer_processes(output, workload_pid):
    """Separate only a known workload's process tree; retain unrelated peers."""
    rows = []
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            rows.append((int(fields[0]), int(fields[1]), fields[2]))
    owned = {workload_pid}
    while True:
        expanded = owned | {pid for pid, parent, _ in rows if parent in owned}
        if expanded == owned:
            break
        owned = expanded
    external, workload = [], []
    for pid, parent, command in rows:
        name = Path(command).name
        if name in DEVELOPER_PROCESSES:
            (workload if pid in owned else external).append(
                {'pid': pid, 'parentPID': parent, 'process': name})
    return external, workload


class HostMonitor:
    def __init__(self, output=None, workload_pid=None):
        self.output = output
        self.workload_pid = workload_pid
        self.started = time.monotonic()
        self.started_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.stop = threading.Event()
        self.samples = 0
        self.overlaps = []
        self.workload_processes = []
        self.errors = []
        self.load_samples = []
        self.thread = None

    def sample(self):
        try:
            self.load_samples.append(dict(elapsedSeconds=time.monotonic()-self.started,
                                          loadAverage=list(os.getloadavg())))
            columns = 'pid=,comm=' if self.workload_pid is None else 'pid=,ppid=,comm='
            output = subprocess.check_output(['ps', '-axo', columns], text=True, timeout=2)
            self.samples += 1
            if self.workload_pid is None:
                external, workload = developer_processes(output), []
            else:
                external, workload = classify_developer_processes(output, self.workload_pid)
            for process in external:
                self.overlaps.append(dict(elapsedSeconds=time.monotonic()-self.started, **process))
            for process in workload:
                self.workload_processes.append(dict(elapsedSeconds=time.monotonic()-self.started, **process))
        except (OSError, subprocess.SubprocessError) as error:
            self.errors.append(str(error))

    def run(self):
        while not self.stop.wait(1):
            self.sample()

    def __enter__(self):
        self.sample()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=3)
        if self.thread.is_alive():
            self.errors.append('Host monitor failed to stop within 3 seconds')
        self.sample()
        if self.output is not None:
            Path(self.output).write_text(json.dumps(self.report(), indent=2)+"\n")

    def report(self):
        return dict(startedUTC=self.started_utc, samples=self.samples,
                    clean=self.samples >= 2 and not self.overlaps and not self.errors,
                    overlappingDeveloperProcesses=self.overlaps, errors=self.errors,
                    workloadPID=self.workload_pid, workloadDeveloperProcesses=self.workload_processes,
                    loadSamples=self.load_samples,
                    scope='One-second developer-process samples; short tasks and other system contention may be missed')
