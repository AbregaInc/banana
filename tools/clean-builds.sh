#!/bin/sh
# Delete build output that can be rebuilt, and say how much disk came back.
#
#   tools/clean-builds.sh            # this checkout's .build and its agent worktrees' .build
#   tools/clean-builds.sh DIR...     # also these folders (a scratchpad's derived data, say)
#
# Each xcodebuild derived-data folder is 1.5–3.5 GB; a session that makes one per scheme or
# experiment fills the disk (34 GB on 11 Oct 2026). Run this before a final report.
#
# Kept:
#   - what symbolicates the builds on the author's devices: ios-prod, ios-prod-watch, dsyms and the
#     TestFlight archives;
#   - any folder holding a file named .keep-build (put one in the build folder of the worktree
#     a Beta was installed from, and remove it when that Beta is replaced);
#   - any folder a running xcodebuild is using.
# Sources and worktrees are never touched, only build output.
set -eu
cd "$(dirname "$0")/.."

KEEP="ios-prod ios-prod-watch dsyms ios-testflight mac-testflight site-fonts"
free() { df -k . | awk 'NR==2 { print $4 }'; }
before=$(free)

clean() {
    [ -d "$1" ] || return 0
    if [ -e "$1/.keep-build" ]; then echo "kept    $1 (.keep-build)"; return 0; fi
    full=$(cd "$1" && pwd -P)
    if pgrep -f "xcodebuild.*($1|$full)" >/dev/null 2>&1; then echo "in use  $1"; return 0; fi
    echo "deleted $1 ($(du -sh "$1" 2>/dev/null | cut -f1))"
    rm -rf "$1"
}

for dir in .build/*; do
    [ -d "$dir" ] || continue
    case " $KEEP " in *" $(basename "$dir") "*) echo "kept    $dir"; continue ;; esac
    clean "$dir"
done
for dir in .claude/worktrees/*/.build/*; do clean "$dir"; done
for dir in "$@"; do clean "$dir"; done

# Instruments writes each capture into $TMPDIR/instruments*.ktrace (1–2.5 GB for an 8-second
# trace) and leaves it there; 30 of them held 38 GB on 30 Oct 2026. profile-device.py removes
# its own; this catches the rest, unless a recorder is still running.
if pgrep -x xctrace >/dev/null 2>&1; then
    echo "in use  \$TMPDIR/instruments*.ktrace (xctrace running)"
else
    for f in "${TMPDIR:-/tmp}"/instruments*.ktrace; do
        [ -e "$f" ] || continue
        echo "deleted $f ($(du -sh "$f" | cut -f1))"
        rm -f "$f"
    done
fi

echo "freed $(( ($(free) - before) / 1048576 )) GB; $(( $(free) / 1048576 )) GB free"
