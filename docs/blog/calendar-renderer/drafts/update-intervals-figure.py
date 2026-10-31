#!/usr/bin/env python3
"""Figure for the article: cumulative share of app-update intervals, old host versus new, on the
spare iPhone 14 Pro. Reads the retained traces; writes one SVG with a Week panel and a Day panel.

    python3 docs/blog/calendar-renderer/drafts/update-intervals-figure.py RUN_DIR OUT.svg
"""
import json, math, sys
from pathlib import Path

run = Path(sys.argv[1]); out = Path(sys.argv[2])
INK, DIM, RULE = '#221d38', '#625a78', '#e6dccb'
OLD, NEW = '#d95926', '#2a78d6'   # validated against the cream surface (dataviz validator, 29 Oct 2026)
W, H = 960, 520
panels = [('Week', 'week'), ('Day', 'day')]
xmin, xmax = 0.5, 200.0          # ms, log axis
def samples(name):
    a = json.load(open(run / name / 'trace' / 'analysis.json'))
    return sorted(x['durationMS'] for x in a['timings']['appUpdates']['samples'])

def lx(v, x0, x1):
    return x0 + (math.log10(max(v, xmin)) - math.log10(xmin)) / (math.log10(xmax) - math.log10(xmin)) * (x1 - x0)

svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t d">',
       '<title id="t">Share of app updates finishing within a given time, old host versus new, iPhone 14 Pro</title>',
       '<desc id="d">Two panels, Week and Day. In Week the old host\'s updates mostly take 11 to 100 ms while the new host\'s mostly finish under 8.3 ms. In Day both hosts finish most updates under 8.3 ms, the old host slightly faster.</desc>',
       '<style>text{font-family:"IBM Plex Mono",ui-monospace,Menlo,monospace;fill:#221d38}.dim{fill:#625a78}.s{font-size:12px}.l{font-size:14px;font-weight:700}.ax{font-size:12px;fill:#625a78}</style>']
svg.append(f'<text class="l" x="24" y="30">Share of app updates finishing within a given time</text>')
svg.append(f'<text class="s dim" x="24" y="50">iPhone 14 Pro · 36,500 events · 16 swipe pairs · two runs per host, drawn as two lines</text>')
pw = (W - 24 - 24 - 40) / 2
for i, (label, key) in enumerate(panels):
    x0 = 24 + i * (pw + 40) + 44; x1 = 24 + i * (pw + 40) + pw; y0, y1 = 90, 440
    svg.append(f'<text class="l" x="{x0}" y="{y0-14}">{label}</text>')
    # grid: 8.3 and 16.7 ms frame marks, plus decades
    for v, name in [(1, '1'), (10, '10'), (100, '100')]:
        x = lx(v, x0, x1); svg.append(f'<line x1="{x:.1f}" y1="{y0}" x2="{x:.1f}" y2="{y1}" stroke="{RULE}" stroke-width="1"/>')
        svg.append(f'<text class="ax" x="{x:.1f}" y="{y1+18}" text-anchor="middle">{name} ms</text>')
    for v, name in [(8.3, '8.3 ms = one 120 Hz frame'), (16.7, '16.7 ms')]:
        x = lx(v, x0, x1); svg.append(f'<line x1="{x:.1f}" y1="{y0}" x2="{x:.1f}" y2="{y1}" stroke="{INK}" stroke-width="1" stroke-dasharray="3 4"/>')
        if v == 8.3: svg.append(f'<text class="ax" x="{x:.1f}" y="{y1+32}" text-anchor="middle">{name}</text>')
    for frac in (0, 0.5, 1.0):
        y = y1 - frac * (y1 - y0)
        svg.append(f'<line x1="{x0}" y1="{y:.1f}" x2="{x1}" y2="{y:.1f}" stroke="{RULE}" stroke-width="1"/>')
        svg.append(f'<text class="ax" x="{x0-6}" y="{y+4:.1f}" text-anchor="end">{int(frac*100)}%</text>')
    for runname, color, series in [(f'{key}-1-reference', OLD, 'old'), (f'{key}-4-reference', OLD, 'old'),
                                   (f'{key}-2-native', NEW, 'new'), (f'{key}-3-native', NEW, 'new')]:
        s = samples(runname); n = len(s)
        pts = [(lx(v, x0, x1), y1 - (j + 1) / n * (y1 - y0)) for j, v in enumerate(s)]
        d = 'M' + ' L'.join(f'{x:.1f},{y:.1f}' for x, y in pts)
        svg.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round"/>')
    # direct labels at the 50% point of the first run of each host
    for runname, color, text, anchor, off, dy in [(f'{key}-1-reference', OLD, 'old UIScrollView host', 'start', 10, 24),
                                                   (f'{key}-2-native', NEW, 'new UICollectionView', 'end', -10, -14)]:
        s = samples(runname); med = s[len(s)//2]; x = lx(med, x0, x1); y = y1 - 0.5 * (y1 - y0)
        if anchor == 'end' and x - 160 < x0: anchor, off = 'start', 10   # keep the label inside the panel
        svg.append(f'<text class="s" x="{x+off:.1f}" y="{y+dy:.1f}" text-anchor="{anchor}" fill="{INK}"><tspan fill="{color}">●</tspan> {text}</text>')
svg.append(f'<text class="s dim" x="24" y="{H-24}">x: how long an app update took, log scale. y: share of updates at or under that time.</text>')
svg.append(f'<text class="s dim" x="24" y="{H-8}">App-attributed update intervals from Animation Hitches; not input-to-visible latency.</text>')
svg.append('</svg>')
out.write_text('\n'.join(svg) + '\n'); print(out, len('\n'.join(svg)), 'bytes')
