import json,sys,glob
for f in sys.argv[1:]:
    d=json.load(open(f)); s=d['summary']; det=d['detail']
    line=f"{d['host']:6}/{d['variant']:11} {d['scenario']:13} pass={str(d['pass']):5} deciding={s.get('decidingNumber')}"
    if d['scenario']=='prepend':
        reps=det['reps']; line+=f" shifts={[round(r.get('maxAbsShift',-1),1) for r in reps]} displacedFrames={[r.get('framesDisplaced') for r in reps]} missing={sum(r.get('framesMissing',0) for r in reps)}"
    if d['scenario']=='rebuild':
        reps=det['reps']; line+=f" firstPresentDelta={[None if r.get('firstPresentDelta') is None else round(r['firstPresentDelta'],1) for r in reps]} framesBeforeHost={[r.get('framesBeforeHost') for r in reps]} blankListFrames={[r.get('blankListFrames') for r in reps]} after={[round(r.get('maxAbsDeltaAfterPresent',0),1) for r in reps]}"
    if d['scenario']=='slide':
        line+=f" worstErr={s.get('worstError'):.1f} recentres={s.get('windowRecentres')} frames={s.get('framesTotal')} compared={s.get('framesCompared')} nyMissing={s.get('nyMissing')} syMissing={s.get('syMissing')} onSlide={s.get('jumpsOnRecentreFrames')} lateScrollFrames={s.get('framesWithScrollOneFrameLate')} realJumps={s.get('realJumpsAfterLagAllowance')} (max {s.get('realJumpMaxError')})"
    if d['scenario'].startswith('heldkey'):
        line+=f" hitches/10s={s['hitchesPer10s']:.2f} container={s['containerDelta']} update={s['updateDelta']} rows/move={s['rowBodyPerMove']:.2f} marks/move={s['markBodyPerMove']:.2f} turn p95={s['turnMsP95']:.2f}ms call p95={s['moveCallMsP95']:.3f}ms"
    if d['scenario']=='idle':
        line+=f" container={s['containerDelta']} row={s['rowBodyDelta']} mark={s['markBodyDelta']} cpu={s['cpuSecondsIn20s']:.2f}s"
    print(line)
