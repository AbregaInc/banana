#!/usr/bin/env python3
"""Matched offscreen CoreGraphics/Skia raster jobs; pixel differences remain failures."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from performance_host import HostMonitor


def validate(data, seed, density, reverse, managed=None, paths=None, reuse=None):
    try:
        if managed is not None:
            assert data["managedColors"] == managed
        if paths is not None:
            assert data['cgPaths'] == paths
        if reuse is not None:
            assert data['reusePictures'] == reuse
            assert 0 <= data['pictureLimit'] <= 8388608
        assert data['fixture']['seed'] == str(seed)
        assert data['fixture']['meanDailyEvents'] == density
        assert data['fixture']['retainedEvents'] == 365 * density
        assert data['fixture']['calendarCount'] == 12
        assert len(data['results']) == 2
        assert {(r['widthPoints'], r['scale']) for r in data['results']} == {(393, 3), (1366, 2)}
        exact = True
        for result in data['results']:
            assert Counter(s['state'] for s in result['samples']) == Counter(['cold-raster', 'warm-reraster', 'eviction-reraster'])
            assert math.isfinite(result['startupMS']) and result['startupMS'] >= 0
            coldCount = result['samples'][0].get('pictureCount', 0)
            for sample in result['samples']:
                if reuse is not None:
                    assert 0 <= sample['pictureBytes'] <= data['pictureLimit']
                    assert 0 <= sample['pictureCount'] <= 4
                    expectedHits = coldCount if reuse and sample['state'] == 'warm-reraster' else 0
                    assert sample['pictureHits'] == expectedHits
                    assert sample['pictureMisses'] == 4 - expectedHits
                    if not reuse or data['pictureLimit'] == 0:
                        assert sample['pictureBytes'] == sample['pictureCount'] == 0

                assert sample['first'] == ('skia' if reverse else 'coreGraphics')
                for key in ['coreGraphicsRasterMS', 'skiaCompletionMS', 'skiaEncodeMS', 'skiaCacheBytes', 'coreGraphicsTileBytes']:
                    assert math.isfinite(sample[key]) and sample[key] >= 0
                assert sample['skiaEncodeMS'] <= sample['skiaCompletionMS']
                assert Counter(p['tile'] for p in sample['pixels']) == Counter(range(4))
                for pixels in sample['pixels']:
                    if reuse is not None:
                        assert 0 <= pixels['skiaPhaseMaxDifference'] <= 255
                        exact &= pixels['skiaPhaseMaxDifference'] <= 1
                    assert pixels['events'] == pixels['skiaEvents'] and pixels['events'] >= 0
                    assert pixels['totalPixels'] == result['widthPoints'] * 256 * result['scale'] ** 2
                    assert 0 <= pixels['pixelsOverOne'] <= pixels['totalPixels']
                    assert 0 <= pixels['maxChannelDifference'] <= 255
                    assert math.isfinite(pixels['meanAbsoluteChannelDifference']) and 0 <= pixels['meanAbsoluteChannelDifference'] <= 255
                    exact &= pixels['maxChannelDifference'] <= 1 and pixels['pixelsOverOne'] == 0
        return 'exact-pixels' if exact else 'pixel-mismatch'
    except (AssertionError, KeyError, TypeError, ValueError):
        return 'invalid'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--legacy-unmanaged-colors', action='store_true')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parent
    sources = [*root.glob('Shared/*.swift'), *root.glob('SkiaTests/*'), Path(__file__)]
    (args.out/'environment.json').write_text(json.dumps({
        'binarySHA256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        'sources': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources if p.is_file()},
        'os': subprocess.check_output(['sw_vers'], text=True),
        'scope': 'Mac offscreen raster jobs; first process viewport only is process-cold; no input/display evidence'
    }, indent=2)+'\n')
    rows = []
    for seed in [20261009, 20261010]:
        for density in [1, 100, 300]:
            for trial in range(3):
                reverse = (trial + seed) % 2 == 1
                name = f'{seed}-{density}-{trial}'
                destination = args.out/name
                command = ['/usr/bin/time', '-l', str(args.binary.resolve()), '--fixture', 'varied-v1',
                    '--mode', 'week', '--days', '365', '--density', str(density), '--seed', str(seed), '--out', str(destination)]
                if args.legacy_unmanaged_colors:
                    command.append("--legacy-unmanaged-colors")
                if reverse:
                    command.append('--reverse')
                with HostMonitor(args.out/(name+'-host.json')) as host, (args.out/(name+'.log')).open('w') as log:
                    try:
                        code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
                    except subprocess.TimeoutExpired:
                        code = 124
                status = 'unmeasured'
                if code == 0 and (destination/'report.json').exists():
                    status = validate(json.loads((destination/'report.json').read_text()), seed, density, reverse, not args.legacy_unmanaged_colors)
                rows.append({'name': name, 'command': command, 'exitCode': code, 'status': status, 'hostMonitor': host.report()})
                (args.out/'summary.json').write_text(json.dumps(rows, indent=2)+'\n')
                print(name, status, flush=True)
    # Exact-pixel success still leaves UI acceptance unmeasured.
    return 1 if any(row['status'] == 'pixel-mismatch' for row in rows) else 2


if __name__ == '__main__':
    raise SystemExit(main())
