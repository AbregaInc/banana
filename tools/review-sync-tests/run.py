#!/usr/bin/env python3
"""Exercise real review persistence and note wire-clock policy without opening an app."""
import argparse, hashlib, json, subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--out', required=True, type=Path)
a = p.parse_args()
a.out.mkdir(parents=True, exist_ok=False)
files = ['Shared/FitnessModels.swift', 'Shared/WorkoutPauses.swift', 'Shared/SnapshotPersistence.swift',
         'Shared/BananaDesign.swift', 'Banana/Model/SleepNights.swift', 'Banana/Model/WorkoutCleanup.swift',
         'Banana/Model/WorkoutEntry.swift', 'Banana/Model/HealthWorkout.swift',
         'Banana/Model/WorkoutReviewCoordinator.swift', 'Banana/Model/VoiceNote.swift',
         'Banana/Model/Sync/JSONValue.swift', 'tools/review-sync-tests/main.swift']
command = ['swiftc', '-O', '-parse-as-library', *[str(root/f) for f in files], '-o', str(a.out/'checks')]
with (a.out/'build.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
if result.returncode == 0:
    with (a.out/'run.log').open('w') as log:
        result = subprocess.run([str((a.out/'checks').resolve())], stdout=log, stderr=subprocess.STDOUT)
(a.out/'status.json').write_text(json.dumps({'exitCode': result.returncode,
    'sourceSHA256': {f: hashlib.sha256((root/f).read_bytes()).hexdigest() for f in files},
    'scope': 'Persistence and canonical clock correctness only; no UI performance certification.'}, indent=2))
raise SystemExit(result.returncode)
