#!/usr/bin/env python3
"""Retain a bounded physical-device trace. Successful capture alone is not UI acceptance."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


def recorders_running():
    return subprocess.run(['pgrep', '-x', 'xctrace'], capture_output=True).returncode == 0


def remove_recording_temps(temp_dir, since, busy=recorders_running):
    """xctrace records into $TMPDIR/instruments*.ktrace, 1–2.5 GB for an 8-second capture, and
    leaves the file there (30 of them held 38 GB on 30 Oct 2026). Remove the ones written since
    this recording began; leave everything alone while another recorder is still running."""
    if busy():
        return {'skipped': 'another xctrace is running'}
    removed = []
    for path in sorted(Path(temp_dir).glob('instruments*.ktrace')):
        try:
            stat = path.stat()
            if stat.st_mtime < since: continue
            path.unlink()
        except OSError:
            continue
        removed.append({'name': path.name, 'bytes': stat.st_size})
    return {'removed': removed, 'bytes': sum(r['bytes'] for r in removed)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='Instruments device name or identifier')
    parser.add_argument('--pid', required=True, type=int, help='Already-running isolated prototype process')
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--seconds', type=int, default=8)
    parser.add_argument('--template', choices=['Animation Hitches', 'Logging', 'Time Profiler'], default='Animation Hitches')
    parser.add_argument('--extra-metrics', action='store_true', help='Append commit, run-loop and signpost instruments')
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60 or args.pid <= 0:
        parser.error('Use a positive process ID and a 1–60 second recording')
    args.out.mkdir(parents=True, exist_ok=False)
    command = ['xcrun', 'xctrace', 'record', '--device', args.device, '--template', args.template]
    if args.extra_metrics:
        for instrument in ['Core Animation Commits', 'Run Loops', 'Points of Interest']:
            command += ['--instrument', instrument]
    command += ['--attach', str(args.pid), '--time-limit', f'{args.seconds}s',
                '--output', str((args.out / 'touch.trace').resolve()), '--no-prompt']
    status = dict(status='unmeasured', timestamp=datetime.datetime.now().astimezone().isoformat(),
                  command=command, device=args.device, pid=args.pid,
                  scope='Physical trace collection; verify input overlap, schema, completeness and process identity before analysis')
    def save():
        (args.out / 'record-status.json').write_text(json.dumps(status, indent=2) + '\n')
    save()
    if shutil.disk_usage(args.out).free < 1536 * 1024 * 1024:
        status.update(status='unmeasured', reason='Free disk below 1.5 GiB'); save(); return 2
    began = time.monotonic()
    began_wall = time.time() - 1
    reason = None
    with (args.out / 'record.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while process.poll() is None:
                if time.monotonic() - began > args.seconds + 180:
                    reason = 'Recorder/postprocessing deadline'
                elif shutil.disk_usage(args.out).free < 1536 * 1024 * 1024:
                    reason = 'Free disk below 1.5 GiB'
                if reason: break
                time.sleep(1)
        except KeyboardInterrupt:
            reason = 'Interrupted'
        finally:
            if process.poll() is None:
                for sig, timeout in [(signal.SIGINT, 15), (signal.SIGTERM, 5), (signal.SIGKILL, 5)]:
                    try: os.killpg(process.pid, sig)
                    except ProcessLookupError: break
                    try: process.wait(timeout=timeout); break
                    except subprocess.TimeoutExpired: pass
            status.update(status='recorded-unvalidated' if process.returncode == 0 and not reason else 'failed-unmeasured',
                          exitCode=process.returncode, reason=reason, elapsedSeconds=time.monotonic() - began)
            status['temporaryRecordings'] = remove_recording_temps(os.environ.get('TMPDIR') or tempfile.gettempdir(), began_wall)
            save()
    print(json.dumps(status, indent=2))
    return 0 if status['status'] == 'recorded-unvalidated' else 2


if __name__ == '__main__':
    raise SystemExit(main())
