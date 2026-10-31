import json,sys,statistics,glob
arms={"p0":sorted(glob.glob(".build/perf-results/*ab-p0-*.json")),"p0p":sorted(glob.glob(".build/perf-results/*ab-p0p-*.json"))}
docs={k:[json.load(open(p)) for p in v] for k,v in arms.items()}
print("files:",{k:[p.split('/')[-1] for p in v] for k,v in arms.items()})
def vals(doc,dev,r,m):
    return doc["devices"].get(dev,{}).get("routes",{}).get(r,{}).get("launch",{}).get(m,{}).get("values",[])
def idle(doc,dev,r,k):
    return doc["devices"].get(dev,{}).get("routes",{}).get(r,{}).get("idle",{}).get(k)
routes=["shell-plan","today","notes","settings","week"]
print(f"{'route':20} {'arm':4} {'n':>2} {'body med':>8} {'done-body':>9} {'appear med':>10} {'appear/body':>11} {'idle%':>6} {'wake':>6} {'load':>6}")
summary=[]
for dev in ("iphone","ipad"):
    for r in routes:
        row={}
        for arm in ("p0","p0p"):
            body=[];gap=[];app=[];ratio=[];idl=[];wk=[];lo=[]
            for d in docs[arm]:
                b=vals(d,dev,r,"app.init.body"); a=vals(d,dev,r,"root.appear"); dn=vals(d,dev,r,"app.init.done")
                for i in range(min(len(b),len(a),len(dn))):
                    body.append(b[i]); app.append(a[i]); gap.append(dn[i]-b[i]); ratio.append(a[i]/b[i])
                if idle(d,dev,r,"cpu_pct_ps") is not None: idl.append(idle(d,dev,r,"cpu_pct_ps")); wk.append(idle(d,dev,r,"power_wakeups")); lo.append((idle(d,dev,r,"load_before") or "").split()[0].replace("load=",""))
            if body:
                row[arm]=(statistics.median(body),statistics.median(gap),statistics.median(app),statistics.median(ratio),idl,wk,lo,len(body))
                print(f"{dev+'/'+r:20} {arm:4} {len(body):2} {row[arm][0]:8.0f} {row[arm][1]:9.0f} {row[arm][2]:10.0f} {row[arm][3]:11.3f} {str(idl):>6} {str(wk):>6} {','.join(lo):>6}")
        if "p0" in row and "p0p" in row:
            summary.append((dev,r,row["p0p"][2]-row["p0"][2],row["p0p"][1]-row["p0"][1],row["p0p"][3]-row["p0"][3],row["p0p"][0]-row["p0"][0]))
print("\nP0' − P0 (same containers, interleaved):  route  Δappear_raw  Δ(done−body)  Δratio  Δbody")
for dev,r,da,dg,dr,db in summary: print(f"  {dev+'/'+r:20} {da:+6.0f} ms  {dg:+5.0f} ms  {dr:+.3f}  {db:+5.0f} ms")
if summary:
    print(f"median: Δappear {statistics.median([s[2] for s in summary]):+.0f} ms, Δ(done−body) {statistics.median([s[3] for s in summary]):+.0f} ms, Δratio {statistics.median([s[4] for s in summary]):+.3f} (≈ {statistics.median([s[4] for s in summary])*500:+.0f} ms at body=500), Δbody {statistics.median([s[5] for s in summary]):+.0f} ms")
