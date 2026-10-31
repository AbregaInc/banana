#!/usr/bin/env python3
"""Find main-thread stall windows in an exported Time Profiler table and say what ran in them.

    python3 tools/physical-stress-tests/cpu-stalls.py TRACE_DIR/time-profile.xml [--window-ms 50] [--stall-ms 100]

Prints the main-thread CPU time per bucket, the contiguous windows whose main-thread time is
at least --stall-ms, and for those windows the heaviest frames (inclusive weight) compared with
the rest of the recording. Inclusive weights overlap; they are not frame timings.
"""
import argparse, collections, re, sys
import xml.etree.ElementTree as ET


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('xml'); p.add_argument('--window-ms', type=float, default=50); p.add_argument('--stall-ms', type=float, default=100)
    p.add_argument('--top', type=int, default=18)
    p.add_argument('--distinct', action='store_true', help='rank stall frames by share inside minus share elsewhere')
    p.add_argument('--app', default=r'(Banana|WeekView|Planner|Occurrence|Calendar|Stress|Reminder|Routine|Weather|Shell|Today|Agenda|Lane|Artwork|Event|Scale)',
                   help='regex naming app frames to list separately')
    a = p.parse_args()
    root = ET.parse(a.xml).getroot()
    by_id = {}
    def resolve(el):
        if el is None: return None
        if el.get('ref'): return by_id.get(el.get('ref'))
        if el.get('id'): by_id[el.get('id')] = el
        return el
    samples = []
    for row in root.iter('row'):
        t = resolve(row.find('sample-time')); th = resolve(row.find('thread')); w = resolve(row.find('weight')); st = resolve(row.find('tagged-backtrace') if row.find('tagged-backtrace') is not None else row.find('backtrace'))
        if t is None or th is None or w is None: continue
        main = 'Main Thread' in (th.get('fmt') or '')
        frames = []
        if st is not None:
            for f in st.iter('frame'):
                f = resolve(f)
                if f is not None: frames.append(f.get('name') or f.get('fmt') or '?')
        samples.append((int(t.text) / 1e6, main, int(w.text) / 1e6, frames))
    if not samples: sys.exit('no samples')
    t0 = min(s[0] for s in samples); dur = max(s[0] for s in samples) - t0
    nb = int(dur // a.window_ms) + 1
    buckets = [0.0] * nb
    for t, main, w, _ in samples:
        if main: buckets[int((t - t0) // a.window_ms)] += w
    print(f'recording {dur/1000:.1f} s, {len(samples)} samples, main-thread CPU {sum(buckets):.0f} ms; per {a.window_ms:.0f} ms bucket (ms):')
    print(' '.join(f'{int(b):3d}' for b in buckets))
    # stall windows: contiguous buckets with >= 60% busy, total >= stall-ms
    windows, i = [], 0
    while i < nb:
        if buckets[i] >= 0.6 * a.window_ms:
            j = i
            while j < nb and buckets[j] >= 0.6 * a.window_ms: j += 1
            total = sum(buckets[i:j])
            if total >= a.stall_ms: windows.append((i * a.window_ms, j * a.window_ms, total))
            i = j
        else: i += 1
    print(f'\nstall windows (>= {a.stall_ms:.0f} ms of main-thread CPU, contiguous):')
    for s, e, tot in windows: print(f'  +{s/1000:.2f}s .. +{e/1000:.2f}s  main CPU {tot:.0f} ms')
    def inside(t): return any(s <= (t - t0) < e for s, e, _ in windows)
    def aggregate(pred):
        inc = collections.Counter(); total = 0.0
        for t, main, w, frames in samples:
            if not main or not pred(t): continue
            total += w
            for name in set(frames): inc[name] += w
        return inc, total
    stall, stall_total = aggregate(inside); rest, rest_total = aggregate(lambda t: not inside(t))
    def show(title, inc, total, other, other_total):
        print(f'\n{title}: {total:.0f} ms main-thread CPU; heaviest frames (inclusive ms, share) and share in the other windows')
        shown = 0
        for name, w in inc.most_common(200):
            if re.search(r'^(start|_?main|UIApplicationMain|CFRunLoop|__CFRUNLOOP|-\[UIApplication|GSEventRun|_dispatch_main|__CFRunLoop|RunLoop|_dispatch_root)', name): continue
            o = other.get(name, 0) / other_total * 100 if other_total else 0
            print(f'  {w:7.0f} ms {w/total*100:5.1f}%  (elsewhere {o:5.1f}%)  {name[:110]}')
            shown += 1
            if shown >= a.top: break
    show('INSIDE stalls', stall, stall_total, rest, rest_total)
    show('OUTSIDE stalls', rest, rest_total, stall, stall_total)
    if a.distinct:
        print('\nframes most specific to the stalls (share inside - share elsewhere):')
        ranked = sorted(stall.items(), key=lambda kv: -(kv[1] / stall_total - rest.get(kv[0], 0) / rest_total))
        for name, w in ranked[:a.top]:
            print(f'  {w:7.0f} ms {w/stall_total*100:5.1f}%  (elsewhere {rest.get(name,0)/rest_total*100:5.1f}%)  {name[:120]}')
    app = re.compile(a.app)
    print('\napp frames inside the stalls (inclusive ms):')
    for name, w in stall.most_common():
        if app.search(name) and not name.startswith('0x'):
            print(f'  {w:7.0f} ms {w/stall_total*100:5.1f}%  (elsewhere {rest.get(name,0)/rest_total*100:5.1f}%)  {name[:140]}')
    unsym = sum(1 for _, m, _, fr in samples if m and fr and all(re.fullmatch(r'0x[0-9a-f]+', f) for f in fr[:3]))
    print(f'\nmain-thread samples whose top frames are unsymbolicated addresses: {unsym}')


if __name__ == '__main__':
    main()
