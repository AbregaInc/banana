#!/bin/zsh
# tools/perf-gate.sh — Banana whole-app Simulator performance gate (re-runnable, comparable).
#
#   tools/perf-gate.sh run     [--label NAME] [--runs N] [--warmup W] [--settle S] [--idle I]
#                              [--launch-wait L] [--skip-build] [--only ROUTE,ROUTE] [--sequential]
#                              [--src DIR] [--dd DIR] [--out DIR] [--routes-dir DIR | --routes-file FILE]
#                              [--iphone UDID] [--ipad UDID] [--no-ipad] [--no-iphone] [--with-tests]
#   tools/perf-gate.sh compare BASE.json NEW.json [--floor-launch-ms 40] [--floor-cpu 0.5]
#                              [--floor-mem-mb 8] [--k 1.0]
#   tools/perf-gate.sh routes  [--routes-dir DIR | --routes-file FILE]
#
# See tools/perf-gate.md for how to run it, how to read `compare`, the noise floor, and what it
# cannot measure. docs/design/mail-working/perf/baseline.md is the first reference run (P0).
#
# What one `run` does (every number is written with the command that produced it):
#   1. Builds Banana for the iOS Simulator in the RELEASE configuration (-O, whole-module), with
#      the DEBUG compilation condition ADDED so the VisualAuditRoute launch flags exist. Pure
#      Release has no audit routes (BananaApp.swift: `#if DEBUG && os(iOS)` around
#      VisualAuditRoute), and a plain launch starts the production graph, which this gate must
#      never do. Build wall time is recorded. Derived data defaults to <src>/.build/mail-perf-dd.
#   2. For each simulator and each route: W warm-up + N cold launches (journal wiped before each;
#      LaunchClock ⏱ marks read back from playback.log; a launch with no root.appear is sampled),
#      then one idle run: launch, settle S s, measure process CPU over I s with `ps -o cputime`
#      deltas, read RSS, take the app's own ⚡ POWER rollup (avg/max CPU, phys footprint, wakeups,
#      busiest bodies), count 🌀 STORM / 🔥 HIGH CPU lines, `sample` the process for 2 s, screenshot
#      the Simulator (simctl io screenshot — never the whole screen), and size the data container.
#   3. Writes <out>/<timestamp>-<label>.json (machine-readable) and .tsv (flat), plus a folder per
#      run with every journal, screenshot, sample, `idle-ps.txt`, `container-sizes.txt` and the
#      exact launch command.
#
# Routes come from every *.routes file in --routes-dir (default tools/perf-routes.d): one file per
# package, so no two packages edit one table. Line format: name|devices|launch arguments.
#
# Safety: launches ONLY through VisualAuditRoute flags + --disable-icloud + -onboardingCompleted
# YES (audit routes skip wireUp(): no CloudKit, no Google sync, no write-back, no notifications).
# Never touches a physical device. Boots the simulators headless (simctl), never Simulator.app.
# Uses only the two dedicated simulators by default.
#
# Simulator numbers are for RELATIVE before/after comparison on the same Mac only.

set -u
setopt nullglob
ROOT=${0:A:h:h}                         # the repository that holds this script
BUNDLE=com.boris.banana
IPHONE_DEFAULT=E5232BE0-8F82-4E85-A03B-5CA7160571E2   # "Mail iPhone", iOS 26.5
IPAD_DEFAULT=7CE990BF-066D-4E79-BA7F-B5F285E6A66C     # "Mail iPad", iOS 26.5
COMMON_ARGS=(--disable-icloud -onboardingCompleted YES)

die() { print -u2 "perf-gate: $*"; exit 2 }
log() { print -u2 "[$(date +%H:%M:%S)] $*" }
load_line() { print -- "load=$(uptime | sed 's/.*load averages: //') xcodebuild=$(pgrep -x xcodebuild | wc -l | tr -d ' ')" }

load_routes() {   # routes_dir routes_file → prints the merged table (comments and blanks dropped)
  local dir=$1 file=$2
  if [[ -n $file ]]; then
    sed 's/[[:space:]]*$//' "$file" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
  else
    [[ -d $dir ]] || die "no routes directory $dir"
    local f
    for f in "$dir"/*.routes; do
      sed 's/[[:space:]]*$//' "$f" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
    done
  fi
}

# ---------------------------------------------------------------------------------------------
cmd=${1:-}; [[ -n $cmd ]] || die "usage: perf-gate.sh run|compare|routes ..."
shift

if [[ $cmd == routes ]]; then
  routes_dir=$ROOT/tools/perf-routes.d; routes_file=""
  while (( $# )); do case $1 in
    --routes-dir) routes_dir=$2; shift 2;;
    --routes-file) routes_file=$2; shift 2;;
    *) die "unknown routes option $1";; esac; done
  load_routes "$routes_dir" "$routes_file"
  exit 0
fi

if [[ $cmd == compare ]]; then
  base=${1:-}; new=${2:-}; [[ -f $base && -f $new ]] || die "compare BASE.json NEW.json"
  shift 2
  floor_launch=40; floor_cpu=0.5; floor_mem=8; k=1.0
  while (( $# )); do case $1 in
    --floor-launch-ms) floor_launch=$2; shift 2;;
    --floor-cpu) floor_cpu=$2; shift 2;;
    --floor-mem-mb) floor_mem=$2; shift 2;;
    --k) k=$2; shift 2;;
    *) die "unknown compare option $1";; esac; done
  python3 - "$base" "$new" "$floor_launch" "$floor_cpu" "$floor_mem" "$k" <<'PY'
import json, sys
base, new = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
fl, fc, fm, k = float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6])
ANCHOR = "app.init.body"   # earliest mark common to every route: dyld + static init + first store ctors
# Host contention scales every mark by a common factor (measured 2026-10-05: a load swing 8->412
# moved fitness.init/app.init.body by +80..120 ms and every later mark proportionally; ratios of
# marks stayed within ~2 %). So when the anchor itself moved beyond the floor, launch marks are
# compared NORMALISED by the anchor (mark/anchor, rescaled to the base run) and labelled so.
IDLE = (("cpu_pct_ps", "%", fc), ("power_mem_mb", "MB", fm), ("storms", "n", 0), ("high_cpu", "n", 0))
# Printed in the JSON but never flagged: the ⚡ avg/max include the launch burst; Simulator RSS is noisy.
def rows(doc):
    out = {}
    for dev, d in doc.get("devices", {}).items():
        for route, r in d.get("routes", {}).items():
            la = r.get("launch", {}); anc = la.get(ANCHOR)
            for mark, m in la.items():
                # *.loaded marks are async decode completions (measured run-to-run |delta| median 68 ms
                # on the same binary); they get a 100 ms floor, every other mark the --floor-launch-ms.
                out[(dev, route, "launch."+mark)] = {"med": m["median"], "spread": m["max"]-m["min"],
                                                    "floor": max(fl, 100.0) if mark.endswith(".loaded") else fl,
                                                    "anchor": anc["median"] if anc else None}
            idle = r.get("idle", {})
            for key, unit, floor in IDLE:
                if idle.get(key) is not None:
                    out[(dev, route, "idle."+key)] = {"med": float(idle[key]), "spread": 0.0, "floor": floor, "anchor": None}
    return out
b, n = rows(base), rows(new)
print(f"base: {base['meta'].get('label')} @ {base['meta'].get('commit')}  ({base['meta'].get('date')})")
print(f"new : {new['meta'].get('label')} @ {new['meta'].get('commit')}  ({new['meta'].get('date')})")
print(f"rule: regression if new-base > max(floor, k*max(spread_base, spread_new)), k={k}; launch marks normalised by {ANCHOR} where it moved > {fl:.0f} ms (host load); STORM/HIGH CPU > 0 fails\n")
print(f"{'device':7} {'route':16} {'metric':30} {'base':>9} {'new':>9} {'delta':>9} {'noise':>8}  verdict")
regress = improve = 0; normalised = set()
for key in sorted(set(b) & set(n)):
    B, N = b[key], n[key]
    m0, m1, s0, s1 = B["med"], N["med"], B["spread"], N["spread"]
    tag = ""
    if key[2].startswith("launch.") and B["anchor"] and N["anchor"] and abs(N["anchor"] - B["anchor"]) > fl:
        m1 = m1 / N["anchor"] * B["anchor"]      # express the new mark at the base run's anchor
        normalised.add((key[0], key[1])); tag = " (normalised)"
    d = m1 - m0; noise = max(B["floor"], k * max(s0, s1))
    verdict = ""
    if key[2] in ("idle.storms", "idle.high_cpu"):
        if m1 > 0: verdict = "FAIL (nonzero)"; regress += 1
    elif d > noise: verdict = "REGRESSION" + tag; regress += 1
    elif -d > noise: verdict = "improved" + tag; improve += 1
    if verdict:
        print(f"{key[0]:7} {key[1]:16} {key[2]:30} {m0:9.1f} {m1:9.1f} {d:+9.1f} {noise:8.1f}  {verdict}")
only_new = sorted(set(n) - set(b)); only_base = sorted(set(b) - set(n))
if only_new: print(f"\n{len(only_new)} metric(s) only in new (new routes/marks): " + ", ".join(f"{k[0]}/{k[1]}/{k[2]}" for k in only_new[:12]) + (" …" if len(only_new) > 12 else ""))
if only_base: print(f"{len(only_base)} metric(s) only in base: " + ", ".join(f"{k[0]}/{k[1]}/{k[2]}" for k in only_base[:12]) + (" …" if len(only_base) > 12 else ""))
if normalised:
    print(f"\nhost-load shift on {len(normalised)} route(s) ({ANCHOR} moved > {fl:.0f} ms): their launch marks were compared normalised by {ANCHOR}")
print(f"\n{regress} regression(s), {improve} improvement(s) beyond noise; metrics compared: {len(set(b)&set(n))}")
sys.exit(1 if regress else 0)
PY
  exit $?
fi

[[ $cmd == run ]] || die "unknown command $cmd"

# ---------------------------------------------------------------------------------------------
label=run; runs=5; warmup=1; settle=15; idle=65; launch_wait=6; skip_build=0; only=""
src=$ROOT; dd=""; out=$ROOT/.build/perf-results; routes_dir=$ROOT/tools/perf-routes.d; routes_file=""
iphone=$IPHONE_DEFAULT; ipad=$IPAD_DEFAULT; use_iphone=1; use_ipad=1; with_tests=0; parallel=1
while (( $# )); do case $1 in
  --label) label=$2; shift 2;;
  --runs) runs=$2; shift 2;;
  --warmup) warmup=$2; shift 2;;
  --settle) settle=$2; shift 2;;
  --idle) idle=$2; shift 2;;
  --launch-wait) launch_wait=$2; shift 2;;
  --sequential) parallel=0; shift;;
  --skip-build) skip_build=1; shift;;
  --only) only=$2; shift 2;;
  --src) src=${2:A}; shift 2;;
  --dd) dd=${2:A}; shift 2;;
  --out) out=${2:A}; shift 2;;
  --routes-dir) routes_dir=$2; shift 2;;
  --routes-file) routes_file=$2; shift 2;;
  --iphone) iphone=$2; shift 2;;
  --ipad) ipad=$2; shift 2;;
  --no-ipad) use_ipad=0; shift;;
  --no-iphone) use_iphone=0; shift;;
  --with-tests) with_tests=1; shift;;
  *) die "unknown run option $1";; esac; done
[[ -n $dd ]] || dd=$src/.build/mail-perf-dd
[[ -d $src && -f $src/project.yml ]] || die "no source tree at $src (needs project.yml; run xcodegen generate there)"
[[ -d $src/Banana.xcodeproj ]] || die "no Banana.xcodeproj in $src — run 'xcodegen generate' there first"

stamp=$(date +%Y%m%d-%H%M%S)
run_dir=$out/$stamp-$label
mkdir -p "$run_dir"
commit=$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo unknown)
dirty=$(git -C "$src" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
print -- "$(date)  src=$src commit=$commit dirty=$dirty  $(load_line)" > "$run_dir/meta.txt"
print -- "xcode: $(xcodebuild -version | tr '\n' ' ')  macOS: $(sw_vers -productVersion)  host: $(sysctl -n hw.model)  dd=$dd" >> "$run_dir/meta.txt"

# --- 1. build ---------------------------------------------------------------------------------
app=$dd/Build/Products/Release-iphonesimulator/Banana.app
build_seconds=null
if (( ! skip_build )); then
  if (( $(pgrep -x xcodebuild | wc -l) > 0 )); then
    print -u2 "perf-gate: another xcodebuild is running (one at a time); waiting up to 20 min"
    local_n=0
    while (( $(pgrep -x xcodebuild | wc -l) > 0 && local_n < 120 )); do sleep 10; local_n=$((local_n+1)); done
  fi
  log "building Release(+DEBUG routes) for the iOS Simulator from $src → $dd  [$(load_line)]"
  t0=$(date +%s)
  ( cd "$src" && xcodebuild -project Banana.xcodeproj -scheme Banana -configuration Release \
      -destination "platform=iOS Simulator,id=$iphone" -derivedDataPath "$dd" \
      SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG' ONLY_ACTIVE_ARCH=YES build ) \
    > "$run_dir/build.log" 2>&1
  rc=$?
  t1=$(date +%s); build_seconds=$((t1 - t0))
  grep -q "BUILD SUCCEEDED" "$run_dir/build.log" || die "build failed (rc=$rc): see $run_dir/build.log"
  log "build ok in ${build_seconds}s"
fi
[[ -d $app ]] || die "no app at $app (build first)"
app_bytes=$(du -sk "$app" | cut -f1)
exe_bytes=$(stat -f %z "$app/Banana")
print -- "app_kb=$app_bytes exe_bytes=$exe_bytes arch=$(lipo -archs "$app/Banana" 2>/dev/null)" >> "$run_dir/meta.txt"

# --- 2. routes --------------------------------------------------------------------------------
routes=$(load_routes "$routes_dir" "$routes_file")
[[ -n $routes ]] || die "no routes loaded"
print -- "$routes" > "$run_dir/routes.txt"

journal_path() { print -- "$(xcrun simctl get_app_container "$1" $BUNDLE data)/Library/Application Support/playback.log" }
container() { xcrun simctl get_app_container "$1" $BUNDLE data }
cputime_s() {   # pid → seconds (float) of user+system CPU, from ps cputime [[dd-]hh:]mm:ss.ss
  ps -p "$1" -o cputime= 2>/dev/null | python3 -c '
import sys; t=sys.stdin.read().strip()
if not t: print("nan"); sys.exit()
d=0
if "-" in t: dd,t=t.split("-"); d=int(dd)
p=[float(x) for x in t.split(":")]
while len(p)<3: p.insert(0,0.0)
print(d*86400+p[0]*3600+p[1]*60+p[2])'
}

launch_once() {   # udid, outfile(journal copy), wait_s, args...  → prints pid
  local udid=$1 outfile=$2 wait_s=$3; shift 3
  xcrun simctl terminate "$udid" $BUNDLE >/dev/null 2>&1
  rm -f "$(journal_path "$udid")"
  local line pid
  line=$(xcrun simctl launch "$udid" $BUNDLE "$@" 2>&1) || { print -u2 "launch failed: $line"; print -- ""; return 1 }
  pid=${line##*: }
  sleep "$wait_s"
  cp "$(journal_path "$udid")" "$outfile" 2>/dev/null || print -- "(no journal)" > "$outfile"
  print -- "$pid"
}

measure_device() {   # devname udid
  local dev=$1 udid=$2
  local ddir=$run_dir/$dev; mkdir -p "$ddir"
  local rdir tag pid c0 c1 rss c i name devices args
  local -a largs
  log "[$dev] boot + install"
  xcrun simctl boot "$udid" >/dev/null 2>&1          # headless; never Simulator.app
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
  xcrun simctl install "$udid" "$app" || die "install failed on $dev"
  xcrun simctl terminate "$udid" $BUNDLE >/dev/null 2>&1
  # OnboardingStore.init (OnboardingStore.swift:35) does a SYNCHRONOUS XPC to locationd during the
  # first render pass. A Simulator whose locationd is idle/wedged never answers and the app sits
  # blank at `history.init` forever. Seeding a simulated location and the TCC grant made it answer.
  # (The iPad simulator still shows the location prompt; it costs no measurable idle CPU.)
  xcrun simctl location "$udid" set 40.7484,-73.9857 >/dev/null 2>&1
  xcrun simctl privacy "$udid" grant location $BUNDLE >/dev/null 2>&1
  print -- "$routes" | while IFS='|' read -r name devices args; do
    [[ ",$devices," == *",$dev,"* ]] || continue
    if [[ -n $only && ",$only," != *",$name,"* ]]; then continue; fi
    rdir=$ddir/$name; mkdir -p "$rdir"
    largs=(${=args} $COMMON_ARGS)
    print -- "xcrun simctl launch $udid $BUNDLE ${largs[*]}" > "$rdir/command.txt"
    load_line > "$rdir/load-before.txt"
    # cold launches: warm-ups discarded, then N measured
    for (( i=1; i<=warmup+runs; i++ )); do
      if (( i<=warmup )); then tag=warm$i; else tag=run$((i-warmup)); fi
      pid=$(launch_once "$udid" "$rdir/launch-$tag.log" "$launch_wait" "${largs[@]}")
      # The TCC grant only sticks once locationd has seen the client: re-grant after the first launch.
      if (( i==1 )); then xcrun simctl privacy "$udid" grant location $BUNDLE >/dev/null 2>&1; fi
      if ! grep -q "root.appear" "$rdir/launch-$tag.log" 2>/dev/null; then
        # No first frame within the wait: sample the main thread so a stall is evidence, not a gap.
        sample "$pid" 1 -file "$rdir/launch-$tag.stall-sample.txt" >/dev/null 2>&1
        print -- "STALL: no root.appear within ${launch_wait}s" >> "$rdir/launch-$tag.log"
      fi
      xcrun simctl terminate "$udid" $BUNDLE >/dev/null 2>&1
      sleep 1.5
    done
    # idle run
    log "[$dev] $name idle ${settle}s+${idle}s"
    pid=$(launch_once "$udid" "$rdir/idle-launch.log" "$settle" "${largs[@]}")
    c0=$(cputime_s "$pid")
    sleep "$idle"
    c1=$(cputime_s "$pid")
    rss=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
    # Evidence for any non-zero idle: a 2 s sample of the live process, after the CPU reading.
    sample "$pid" 2 -file "$rdir/idle-sample.txt" >/dev/null 2>&1
    print -- "pid=$pid cpu0=$c0 cpu1=$c1 idle_s=$idle rss_kb=${rss:-nan} alive=$(ps -p "$pid" >/dev/null 2>&1 && echo yes || echo no)" > "$rdir/idle-ps.txt"
    xcrun simctl io "$udid" screenshot "$rdir/idle.png" >/dev/null 2>&1
    cp "$(journal_path "$udid")" "$rdir/idle-journal.log" 2>/dev/null
    c=$(container "$udid")
    { du -sk "$c/Library/Application Support" "$c/Documents" "$c/Library/Caches" "$c/Library/Preferences" "$c/tmp" 2>/dev/null;
      print -- "---files"; find "$c" -type f -size +0 -exec stat -f '%z %N' {} + 2>/dev/null | sort -rn | head -40 | sed "s#$c/##"; } > "$rdir/container-sizes.txt"
    xcrun simctl terminate "$udid" $BUNDLE >/dev/null 2>&1
    load_line > "$rdir/load-after.txt"
    sleep 1
  done
}

if (( parallel )) && (( use_iphone )) && (( use_ipad )); then
  # Two simulators at once halves wall time; each app's CPU is measured per-process (cputime), so
  # the other simulator only adds host contention, which the recorded load lines make visible.
  measure_device iphone "$iphone" &
  measure_device ipad "$ipad" &
  wait
else
  (( use_iphone )) && measure_device iphone "$iphone"
  (( use_ipad ))   && measure_device ipad "$ipad"
fi

# --- 3. unit tests (optional; Debug config per the scheme) ------------------------------------
tests_seconds=null; tests_summary=""
if (( with_tests )); then
  log "unit tests (BananaTests) on the iPhone simulator  [$(load_line)]"
  t0=$(date +%s)
  ( cd "$src" && xcodebuild test -project Banana.xcodeproj -scheme Banana -only-testing:BananaTests \
      -destination "platform=iOS Simulator,id=$iphone" -derivedDataPath "$dd" ) \
    > "$run_dir/tests.log" 2>&1
  t1=$(date +%s); tests_seconds=$((t1 - t0))
  tests_summary=$(grep -E "Executed [0-9]+ tests" "$run_dir/tests.log" | tail -1)
  print -- "tests_seconds=$tests_seconds  $tests_summary" >> "$run_dir/meta.txt"
fi

# --- 4. aggregate -----------------------------------------------------------------------------
python3 - "$run_dir" "$label" "$commit" "$build_seconds" "$app_bytes" "$exe_bytes" "$tests_seconds" "$tests_summary" "$runs" "$settle" "$idle" <<'PY'
import json, os, re, statistics, sys, datetime
run_dir, label, commit, build_s, app_kb, exe_b, tests_s, tests_sum, runs, settle, idle = sys.argv[1:12]
mark_re = re.compile(r"⏱ (\S+)\s+\+(\d+)ms")
power_re = re.compile(r"⚡ POWER (\d+)s\s+cpu=([\d.]+)% avg/([\d.]+)% max mem=(\d+)MB wakeups=(\d+) syscalls=(\d+) csw=(\d+).*activity=(.*)$")
doc = {"meta": {"label": label, "commit": commit, "date": datetime.datetime.now().isoformat(timespec="seconds"),
                "build_config": "Release -O wholemodule + SWIFT_ACTIVE_COMPILATION_CONDITIONS DEBUG (audit routes) ONLY_ACTIVE_ARCH=YES",
                "build_seconds": None if build_s == "null" else int(build_s),
                "app_kb": int(app_kb), "exe_bytes": int(exe_b),
                "tests_seconds": None if tests_s == "null" else int(tests_s), "tests_summary": tests_sum,
                "runs": int(runs), "settle_s": int(settle), "idle_s": int(idle),
                "meta_txt": open(os.path.join(run_dir, "meta.txt")).read().strip()},
       "devices": {}}
tsv = ["device\troute\tmetric\tvalue\tunit\tn\tmin\tmax"]
for dev in ("iphone", "ipad"):
    ddir = os.path.join(run_dir, dev)
    if not os.path.isdir(ddir): continue
    routes = {}
    for name in sorted(os.listdir(ddir)):
        rdir = os.path.join(ddir, name)
        if not os.path.isdir(rdir): continue
        marks = {}
        for f in sorted(os.listdir(rdir)):
            m = re.match(r"launch-run(\d+)\.log", f)
            if not m: continue
            for line in open(os.path.join(rdir, f), errors="replace"):
                mm = mark_re.search(line)
                if mm: marks.setdefault(mm.group(1), []).append(int(mm.group(2)))
        launch = {k: {"median": statistics.median(v), "min": min(v), "max": max(v), "n": len(v), "values": v}
                  for k, v in marks.items()}
        stalls = sum(1 for f in os.listdir(rdir) if f.startswith("launch-run") and f.endswith(".log")
                     and "STALL" in open(os.path.join(rdir, f), errors="replace").read())
        if stalls: launch["_stalled_launches"] = {"median": stalls, "min": stalls, "max": stalls, "n": 1, "values": [stalls]}
        for k, v in launch.items():
            tsv.append(f"{dev}\t{name}\tlaunch.{k}\t{v['median']}\tms\t{v['n']}\t{v['min']}\t{v['max']}")
        idle_d = {"cpu_pct_ps": None, "rss_mb": None, "power_cpu_avg": None, "power_cpu_max": None,
                  "power_mem_mb": None, "power_wakeups": None, "power_syscalls": None, "power_activity": None,
                  "storms": 0, "high_cpu": 0, "power_lines": 0, "alive_at_end": None, "store_sizes_kb": {},
                  "load_before": None}
        psf = os.path.join(rdir, "idle-ps.txt")
        if os.path.exists(psf):
            kv = dict(x.split("=", 1) for x in open(psf).read().split())
            try:
                c0, c1, s = float(kv["cpu0"]), float(kv["cpu1"]), float(kv["idle_s"])
                idle_d["cpu_pct_ps"] = round((c1 - c0) / s * 100, 2)
            except Exception: pass
            try: idle_d["rss_mb"] = round(int(kv["rss_kb"]) / 1024, 1)
            except Exception: pass
            idle_d["alive_at_end"] = kv.get("alive")
        lf = os.path.join(rdir, "load-before.txt")
        if os.path.exists(lf): idle_d["load_before"] = open(lf).read().strip()
        jf = os.path.join(rdir, "idle-journal.log")
        if os.path.exists(jf):
            for line in open(jf, errors="replace"):
                if "🌀 STORM" in line: idle_d["storms"] += 1
                if "🔥 HIGH CPU" in line: idle_d["high_cpu"] += 1
                pm = power_re.search(line)
                if pm:
                    idle_d["power_lines"] += 1
                    idle_d["power_cpu_avg"] = float(pm.group(2)); idle_d["power_cpu_max"] = float(pm.group(3))
                    idle_d["power_mem_mb"] = int(pm.group(4)); idle_d["power_wakeups"] = int(pm.group(5))
                    idle_d["power_syscalls"] = int(pm.group(6)); idle_d["power_activity"] = pm.group(8).strip()
        sf = os.path.join(rdir, "container-sizes.txt")
        if os.path.exists(sf):
            for line in open(sf):
                if line.startswith("---"): break
                parts = line.strip().split("\t")
                if len(parts) == 2: idle_d["store_sizes_kb"][os.path.basename(parts[1])] = int(parts[0])
        for k in ("cpu_pct_ps", "rss_mb", "power_cpu_avg", "power_cpu_max", "power_mem_mb", "power_wakeups", "power_syscalls", "storms", "high_cpu"):
            if idle_d[k] is not None: tsv.append(f"{dev}\t{name}\tidle.{k}\t{idle_d[k]}\t\t1\t\t")
        routes[name] = {"command": open(os.path.join(rdir, "command.txt")).read().strip() if os.path.exists(os.path.join(rdir, "command.txt")) else "",
                        "launch": launch, "idle": idle_d}
    doc["devices"][dev] = {"routes": routes}
json.dump(doc, open(run_dir + ".json", "w"), indent=1, ensure_ascii=False)
open(run_dir + ".tsv", "w").write("\n".join(tsv) + "\n")
print(run_dir + ".json")
PY
log "done → $run_dir.json"
