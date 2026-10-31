import json,sys
d=json.load(open(sys.argv[1]))
print({k:v for k,v in d['summary'].items() if k not in('recentreFrameIndexes',)}, 'pass=',d['pass'], d.get('scrollViewClass'))
det=d['detail']
if 'reps' in det:
    for r in det['reps']:
        print({k:v for k,v in r.items() if k!='series'})
        if '-v' in sys.argv: print('   series', r.get('series'))
if 'jumps' in det:
    for j in det['jumps'][:int(sys.argv[2]) if len(sys.argv)>2 and sys.argv[2].isdigit() else 15]: print(j)
