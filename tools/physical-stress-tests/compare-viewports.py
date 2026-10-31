#!/usr/bin/env python3
"""Matched reference-versus-native scroll traces on one physical device, and a summary table.

    python3 tools/physical-stress-tests/compare-viewports.py run \
        --device UDID --instruments-device 'Name (27.0.1)' --xctestrun PLAN --out DIR [--modes Day Week]
    python3 tools/physical-stress-tests/compare-viewports.py summarize DIR...

Each mode is captured in reference/native/native/reference order so run-order effects show up
in the retained pairs instead of hiding in a single run. Every trace keeps its own folder from
profile-scroll.py; a failed capture is retained and marked, never rerun silently. The summary
reads the app-update and associated-render intervals that report-hitches.py already computes.
It is a scrolling sample on one device, not input-to-visible latency and not a frame budget pass.
"""
import argparse, json, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ORDER = ['reference', 'native', 'native', 'reference']


def run(a):
    a.out.mkdir(parents=True, exist_ok=False)
    plan = {'device': a.device, 'instrumentsDevice': a.instruments_device, 'xctestrun': str(a.xctestrun), 'orientation': a.orientation, 'runs': []}
    for mode in a.modes:
        for index, viewport in enumerate(ORDER, 1):
            folder = a.out / f'{mode.lower()}-{index}-{viewport}'
            command = [sys.executable, str(HERE / 'profile-scroll.py'), '--device', a.device,
                       '--instruments-device', a.instruments_device, '--xctestrun', str(a.xctestrun),
                       '--mode', mode, '--viewport', viewport, '--orientation', a.orientation, '--out', str(folder)]
            print(f'[{len(plan["runs"]) + 1}/{len(a.modes) * len(ORDER)}] {mode} {viewport} -> {folder}', flush=True)
            code = subprocess.run(command).returncode
            plan['runs'].append({'mode': mode, 'order': index, 'viewport': viewport, 'folder': str(folder), 'exit': code})
            (a.out / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    print(json.dumps(summarize_dirs([a.out]), indent=2))


def timings(folder: Path):
    status = json.loads((folder / 'status.json').read_text()) if (folder / 'status.json').exists() else {}
    analysis = folder / 'trace' / 'analysis.json'
    if not analysis.exists():
        return {'status': status.get('status', 'missing'), 'orientation': status.get('orientation'), 'error': status.get('error')}
    data = json.loads(analysis.read_text())
    t = data.get('timings', {})
    def pick(name):
        d = t.get(name, {}).get('stats', {})
        return {k: d.get(k) for k in ('count', 'p50MS', 'p95MS', 'p99MS', 'maxMS', 'over8_3MS')}
    return {'status': status.get('status'), 'orientation': status.get('orientation'), 'verdict': data.get('measuredWorkBudget'),
            'appUpdates': pick('appUpdates'), 'associatedRenders': pick('associatedRenders'),
            'associatedGPU': pick('associatedGPU')}


def summarize_dirs(dirs):
    out = {}
    for d in dirs:
        plan = json.loads((Path(d) / 'plan.json').read_text())
        rows = []
        for r in plan['runs']:
            rows.append({**{k: r[k] for k in ('mode', 'order', 'viewport', 'exit')}, **timings(Path(r['folder']))})
        out[str(d)] = {'device': plan['device'], 'instrumentsDevice': plan['instrumentsDevice'], 'orientation': plan.get('orientation', 'unrecorded'), 'runs': rows}
    return out


def table(summary):
    lines = []
    for d, s in summary.items():
        lines.append(f"\n{s['instrumentsDevice']}  {s.get('orientation', 'unrecorded')}  ({d})")
        lines.append(f"{'mode':5} {'#':>1} {'viewport':9} {'status':26} {'updates':>7} {'p50':>7} {'p95':>7} {'p99':>7} {'max':>8} {'>8.3':>5} | {'render p95':>10} {'max':>8}")
        for r in s['runs']:
            u, v = r.get('appUpdates') or {}, r.get('associatedRenders') or {}
            f = lambda x: '-' if x is None else (f'{x:.2f}' if isinstance(x, float) else str(x))
            lines.append(f"{r['mode']:5} {r['order']:>1} {r['viewport']:9} {str(r.get('status'))[:26]:26} {f(u.get('count')):>7} {f(u.get('p50MS')):>7} {f(u.get('p95MS')):>7} {f(u.get('p99MS')):>7} {f(u.get('maxMS')):>8} {f(u.get('over8_3MS')):>5} | {f(v.get('p95MS')):>10} {f(v.get('maxMS')):>8}")
    return '\n'.join(lines)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='command', required=True)
    r = sub.add_parser('run')
    r.add_argument('--device', required=True); r.add_argument('--instruments-device', required=True)
    r.add_argument('--xctestrun', required=True, type=Path); r.add_argument('--out', required=True, type=Path)
    r.add_argument('--modes', nargs='+', choices=['Day', 'Week'], default=['Day', 'Week'])
    r.add_argument('--orientation', choices=['portrait', 'landscape'], default='portrait')
    s = sub.add_parser('summarize'); s.add_argument('dirs', nargs='+')
    a = p.parse_args()
    if a.command == 'run':
        run(a)
    else:
        summary = summarize_dirs(a.dirs)
        print(table(summary))
        print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
