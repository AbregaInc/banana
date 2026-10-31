"""Component diagnostics only: fast synchronous work never proves UI acceptance."""
import math


def summarize(data):
    samples = data.get('samples', [])
    valid = (data.get('verticalScrollFound') and samples
             and max(s.get('visiblePresentations', s.get('intersectingEventViews', 0)) for s in samples) > 0)
    if data.get('candidate') in ('kvk', 'native'):
        valid = valid and all(s.get('requestedDatePresent') is True for s in samples
                              if s['phase'] in ('page', 'settledLayout'))
    if data.get('candidate') == 'native':
        valid = valid and all(s.get('visibleIDsMatch') is True and s.get('drawCoverageMatches') is True for s in samples)
        if data.get('optimizations', {}).get('ablation') in ['accessibility-page-cache', 'tile-prefetch-ax-cache']:
            valid = valid and all(0 <= s.get('accessibilityCachedPages', -1) <= 3
                                 and 0 <= s.get('accessibilityCachedElements', -1) <= 4096
                                 for s in samples + data.get('experiments', []))
        if data.get('optimizations', {}).get('renderer') == 'tiles':
            valid = valid and all(s.get('tileContentsPresent') is True
                                 and 0 <= s.get('tileCacheBytes', -1) <= 64 * 1024 * 1024
                                 and 0 <= s.get('tileCacheCount', -1) <= 24
                                 and 0 < s.get('activeTiles', -1) <= 8
                                 for s in samples + data.get('experiments', []))
        if data.get('optimizations', {}).get('renderer') == 'raster':
            valid = valid and all(0 <= s.get('rasterCacheBytes', -1) <= 128 * 1024 * 1024
                                 and 0 <= s.get('rasterCachedPages', -1) <= 3
                                 for s in samples + data.get('experiments', []))
    required = {'coldMount': 1, 'page': 12, 'settledLayout': 13, 'scrollOffset': 120}
    valid = valid and {s['phase'] for s in samples} == set(required)
    phases = {}
    for phase, expected in required.items():
        rows = [s for s in samples if s['phase'] == phase]
        values = sorted(s['milliseconds'] for s in rows)
        if len(values) != expected or any(not math.isfinite(v) or v < 0 for v in values):
            valid = False
            continue
        phases[phase] = dict(count=len(values),
            **{f'p{p}MS': values[math.ceil(len(values)*p/100)-1] for p in (50, 95, 99)},
            maxMS=max(values), over8_3MS=sum(v > 8.3 for v in values),
            over100MS=sum(v > 100 for v in values),
            maxAttachedEvents=max(s['attachedEventViews'] for s in rows),
            maxIntersectingEvents=max(s['intersectingEventViews'] for s in rows))
    experiments = data.get('experiments', [])
    if data.get('candidate') == 'native':
        expected = {'uncachedPage': 6, 'memoryPressurePage': 1, 'resize': 3}
        valid = valid and {s['phase'] for s in experiments} == set(expected)
        valid = valid and all(sum(s['phase'] == name for s in experiments) == count for name, count in expected.items())
        valid = valid and all(s.get('visibleIDsMatch') is True and s.get('drawCoverageMatches') is True and s.get('requestedDatePresent') is True
                              and math.isfinite(s['milliseconds']) and s['milliseconds'] >= 0 for s in experiments)
        for phase in expected:
            rows = [s['milliseconds'] for s in experiments if s['phase'] == phase]
            if rows:
                values = sorted(rows)
                phases[phase] = dict(count=len(values), **{f'p{p}MS': values[math.ceil(len(values)*p/100)-1] for p in (50,95,99)},
                    maxMS=max(values), over8_3MS=sum(v > 8.3 for v in values), over100MS=sum(v > 100 for v in values))
    return dict(status='measured' if valid else 'invalid-evidence',
                acceptance='fail' if valid and any(p['over8_3MS'] for p in phases.values()) else 'unmeasured',
                phases=phases)
