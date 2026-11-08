#!/bin/zsh
# Named locks for Xcode work shared by the agents on this Mac.
#
#   xcode-lock.sh <command> [args...]                  # the build lock, held for the whole command
#   xcode-lock.sh -l sim-phone <command> [args...]     # another named lock
#   xcode-lock.sh -l build -d .build/sim <command>     # several at once; -d guards a derived-data folder
#   xcode-lock.sh --status                             # who holds what
#
# Locks:
#   build       one compile at a time: a build already uses every core (BUILD_JOBS)
#   sim-phone   one test run on the phone simulator; sim-pad likewise for the iPad
#   -d DIR      one xcodebuild per derived-data folder: two writing the same folder corrupt it
#
# Re-entrant: a command already running under a lock (named in BANANA_LOCKS_HELD, or owned by an
# ancestor process, as when an older wrapper runs a script that locks for itself) passes straight
# through. All the locks a call names are taken together or not at all, so two callers never hold
# one each and wait for the other's. A lock whose owner and command have both exited is stale and
# is removed. Lives in the repo at tools/agents/xcode-lock.sh; tools/agents/install.sh copies it to
# ~/.config/banana-agents/, where older scripts call it.
emulate -L zsh
root="${BANANA_LOCK_DIR:-$HOME/.config/banana-agents}"
mkdir -p "$root"

lock_dir() {  # name -> folder; "build" keeps the original path so old and new callers share it
  case "$1" in
    build) print -r -- "$root/xcode.lock" ;;
    *) print -r -- "$root/$1.lock" ;;
  esac
}

started() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' }

alive() {  # pid [recorded start]: running, and the same process that was recorded
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
  [ -z "${2:-}" ] || [ "$(started "$1")" = "$2" ]
}

ancestor() {  # is pid $1 this process or one of its parents?
  local p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$p" = "$1" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

stale() {  # lock folder whose owner and command have both gone
  local dir=$1 pid start child cstart
  pid=$(cut -d' ' -f1 "$dir/owner" 2>/dev/null)
  start=$(cat "$dir/start" 2>/dev/null)
  { read -r child cstart < "$dir/child"; } 2>/dev/null
  [ -n "$pid" ] || { [ -n "$(find "$dir" -maxdepth 0 -mmin +1 2>/dev/null)" ]; return; }
  alive "$pid" "$start" && return 1
  [ -n "$child" ] && alive "$child" "$cstart" && return 1
  return 0
}

if [ "${1:-}" = --status ]; then
  for dir in "$root"/*.lock(N); do
    n=${dir:t:r}; [ "$n" = xcode ] && n=build
    printf '%-28s %s\n' "$n" "$(cat "$dir/owner" 2>/dev/null)"
    [ -f "$dir/path" ] && printf '%-28s   %s\n' '' "$(cat "$dir/path")"
  done
  exit 0
fi

names=(); dirs=()
while [ $# -gt 0 ]; do
  case "$1" in
    -l) names+=("$2"); shift 2 ;;
    -d) dirs+=("$2"); shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { print -u2 "usage: ${0:t} [-l NAME]... [-d DERIVED_DATA]... command [args...]"; exit 2; }
[ ${#names} -gt 0 ] || [ ${#dirs} -gt 0 ] || names=(build)

# Derived-data guards are keyed by the folder's real path, so .build/sim and its absolute spelling
# are one lock, and a different worktree's .build/sim is another.
wanted=(); paths=()
for d in "${dirs[@]}"; do
  mkdir -p "$d" 2>/dev/null
  real=$(cd "$d" 2>/dev/null && pwd -P) || real="${d:A}"
  wanted+=("dd-$(print -rn -- "$real" | md5 -q | cut -c1-12)"); paths+=("$real")
done
for n in "${names[@]}"; do wanted+=("$n"); paths+=(""); done

held=":${BANANA_LOCKS_HELD:-}:"
mine=()
release() { for n in "${mine[@]}"; do rm -rf "$(lock_dir "$n")"; done; mine=() }

said=""
while :; do
  blocked=""
  for i in {1..${#wanted}}; do
    n=${wanted[$i]}; dir=$(lock_dir "$n")
    [[ "$held" == *":$n:"* ]] && continue
    if mkdir "$dir" 2>/dev/null; then
      print -r -- "$$ $(date '+%H:%M') $*" > "$dir/owner"
      started $$ > "$dir/start"
      [ -n "${paths[$i]}" ] && print -r -- "${paths[$i]}" > "$dir/path"
      mine+=("$n")
      continue
    fi
    owner=$(cut -d' ' -f1 "$dir/owner" 2>/dev/null)
    if [ -n "$owner" ] && ancestor "$owner"; then held="$held$n:"; continue; fi
    if stale "$dir"; then rm -rf "$dir"; blocked=retry; break; fi
    blocked="$n ($(cat "$dir/owner" 2>/dev/null))"
    break
  done
  [ -z "$blocked" ] && break
  release
  [ "$blocked" = retry ] && continue
  if [ "$blocked" != "$said" ]; then print -u2 "xcode-lock: waiting for $blocked"; said=$blocked; fi
  sleep "${BANANA_LOCK_POLL:-5}"
done

for n in "${mine[@]}"; do held="$held$n:"; done
held=${held#:}; held=${held%:}; held=${held#:}
export BANANA_LOCKS_HELD="$held"

# Run the command as a child so a signal to this script stops it before the locks go.
child=""
trap 'release; exit 130' INT
trap 'release; exit 143' TERM HUP
"$@" <&0 &
child=$!
for n in "${mine[@]}"; do print -r -- "$child $(started $child)" > "$(lock_dir "$n")/child"; done
trap '[ -n "$child" ] && kill -TERM $child 2>/dev/null' INT TERM HUP
rc=0
while :; do
  wait $child; rc=$?
  kill -0 $child 2>/dev/null || break
done
release
exit $rc
