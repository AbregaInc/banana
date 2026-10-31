"""Component diagnostics only: fast synchronous work never proves UI acceptance."""
import math


def summarize(data):
    samples = data.get('samples', [])
    retention_samples = samples + data.get('experiments', []) + data.get('navigationExperiments', []) + data.get('foregroundExperiments', [])
    valid = (data.get('verticalScrollFound') and samples
             and max(s.get('visiblePresentations', s.get('intersectingEventViews', 0)) for s in samples) > 0)
    if data.get('candidate') in ('kvk', 'native'):
        valid = valid and all(s.get('requestedDatePresent') is True for s in samples
                              if s['phase'] in ('page', 'settledLayout'))
    if data.get('candidate') == 'native':
        valid = valid and all(s.get('visibleIDsMatch') is True and s.get('drawCoverageMatches') is True for s in samples)
        if data.get('accessibilityClient') == 'all':
            valid = valid and all(s.get('accessibilityEnumeratedIDsMatch') is True for s in retention_samples)
        if data.get('optimizations', {}).get('ablation') in ['accessibility-page-cache', 'tile-prefetch-ax-cache', 'tile-prefetch-ax-lazy', 'tile-prefetch-async-lazy', 'tile-prefetch-async-surface-cache', 'tile-prefetch-async-surface-lazy']:
            valid = valid and all(0 <= s.get('accessibilityCachedPages', -1) <= 3
                                 and 0 <= s.get('accessibilityCachedElements', -1) <= 4096
                                 for s in retention_samples)
        if data.get('optimizations', {}).get('renderer') == 'tiles':
            valid = valid and all(s.get('tileContentsPresent') is True
                                 and 0 <= s.get('tileCacheBytes', -1) <= 64 * 1024 * 1024
                                 and 0 <= s.get('tileCacheCount', -1) <= 24
                                 and 0 < s.get('activeTiles', -1) <= 8
                                 for s in retention_samples)
        if data.get('optimizations', {}).get('renderer') == 'raster':
            valid = valid and all(0 <= s.get('rasterCacheBytes', -1) <= 128 * 1024 * 1024
                                 and 0 <= s.get('rasterCachedPages', -1) <= 3
                                 for s in retention_samples)
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
    navigation = data.get('navigationExperiments', [])
    if data.get('navigationStress'):
        names = ['forwardPage', 'returnPage', 'rapidForwardPage', 'rapidReturnPage']
        valid = valid and data.get('candidate') == 'native' and {s['phase'] for s in navigation} == set(names)
        valid = valid and all(s.get('visibleIDsMatch') is True and s.get('drawCoverageMatches') is True
                             and s.get('requestedDatePresent') is True
                             and math.isfinite(s['milliseconds']) and s['milliseconds'] >= 0 for s in navigation)
        for phase in names:
            values = sorted(s['milliseconds'] for s in navigation if s['phase'] == phase)
            if len(values) != 12:
                valid = False
                continue
            phases[phase] = dict(count=len(values), **{f'p{p}MS': values[math.ceil(len(values)*p/100)-1] for p in (50,95,99)},
                                maxMS=max(values), over8_3MS=sum(v > 8.3 for v in values), over100MS=sum(v > 100 for v in values))
    elif navigation:
        valid = False
    foreground = data.get('foregroundExperiments', [])
    foreground_phases = {}
    if data.get('foregroundNavigation'):
        required_foreground = {'foregroundColdPage': 1, 'foregroundWarmPage': 12,
            'foregroundUncachedPage': 6, 'foregroundMemoryPressurePage': 1,
            'foregroundForwardPage': 12, 'foregroundReturnPage': 12,
            'foregroundRapidForwardPage': 12, 'foregroundRapidReturnPage': 12}
        workers = {'tile-prefetch-budgeted': 0, 'tile-prefetch-async-one': 1,
                   'tile-prefetch-async-two': 2, 'tile-prefetch-async-lazy': 2, 'tile-prefetch-async-layer': 2, 'tile-prefetch-async-surface': 2, 'tile-prefetch-async-surface-properties': 2, 'tile-prefetch-async-surface-cache': 2, 'tile-prefetch-async-surface-lazy': 2}.get(data.get('optimizations', {}).get('ablation'))
        valid = valid and data.get('candidate') == 'native' and workers is not None
        valid = valid and {s['phase'] for s in foreground} == set(required_foreground)
        for row in foreground:
            sections = row.get('mainSectionsMS', [])
            numeric = sections + [row.get(key, -1) for key in
                                 ('responseMS', 'measuredMainMS', 'maxMainSectionMS')]
            valid = valid and bool(sections) and all(isinstance(v, (int, float))
                and math.isfinite(v) and v >= 0 for v in numeric)
            valid = valid and all(row.get(key) is True for key in
                ('completed', 'requestedDateMatches', 'requestedDatePresent', 'visibleIDsMatch', 'drawCoverageMatches'))
            valid = valid and row.get('workers') == workers and row.get('unexpectedSyncTileBuilds') == 0
            if sections and all(isinstance(v, (int, float)) and math.isfinite(v) for v in numeric):
                valid = valid and math.isclose(sum(sections), row.get('measuredMainMS', -1), abs_tol=1e-6)
                valid = valid and math.isclose(max(sections), row.get('maxMainSectionMS', -1), abs_tol=1e-6)
        for phase, count in required_foreground.items():
            rows = [s for s in foreground if s['phase'] == phase]
            if len(rows) != count:
                valid = False
                continue
            metrics = {}
            for key in ('responseMS', 'measuredMainMS', 'maxMainSectionMS'):
                values = sorted(s.get(key, -1) for s in rows)
                metrics[key] = dict(count=len(values),
                    **{f'p{p}MS': values[math.ceil(len(values)*p/100)-1] for p in (50,95,99)},
                    maxMS=max(values), over8_3MS=sum(v > 8.3 for v in values),
                    over50MS=sum(v > 50 for v in values), over100MS=sum(v > 100 for v in values))
            foreground_phases[phase] = metrics
    elif foreground:
        valid = False
    foreground_failure = any(p['responseMS']['over100MS'] or p['maxMainSectionMS']['over8_3MS']
                             for p in foreground_phases.values())
    return dict(status='measured' if valid else 'invalid-evidence',
                acceptance='fail' if valid and (any(p['over8_3MS'] for p in phases.values()) or foreground_failure) else 'unmeasured',
                phases=phases, foregroundPhases=foreground_phases,
                foregroundComponentBudget='fail' if valid and foreground_failure else ('within-measured-limits' if valid and foreground_phases else 'unmeasured'))
