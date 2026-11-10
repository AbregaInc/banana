#!/bin/sh
# Delete build output that can be rebuilt, and say how much disk came back.
#
#   tools/clean-builds.sh              # this checkout's .build and its agent worktrees' .build
#   tools/clean-builds.sh DIR...       # also these folders (a scratchpad's derived data, say)
#   tools/clean-builds.sh --worktrees  # also every idle worktree of this repo, and Xcode's default
#                                      # DerivedData folders untouched for 3 days
#   tools/clean-builds.sh -n ...       # say what would go, delete nothing
#
# Each xcodebuild derived-data folder is 1.5–3.5 GB; a session that makes one per scheme or
# experiment fills the disk (34 GB on 11 Oct 2026). Run this before a final report.
#
# Kept:
#   - what symbolicates the builds on the author's devices: ios-prod, ios-prod-watch, dsyms and the
#     TestFlight and submitted App Store archives (including preflight candidates);
#   - any folder holding a file named .keep-build (put one in the build folder of the worktree
#     a Beta was installed from, and remove it when that Beta is replaced);
#   - any folder a running xcodebuild is using.
# A worktree is idle (for --worktrees) unless a program other than a shell has its working
# directory in it, it has an owner file (.agent-owner, the worktree pool in AGENTS.md), or its
# .build changed in the last 6 hours (BANANA_IDLE_HOURS).
# The shared compilation cache (~/Library/Caches/banana-xcode-cas) is deleted whole when it
# grows past BANANA_CACHE_LIMIT_GB (30) and no build is running; it refills on the next builds.
# Sources and worktrees are never touched, only build output.
set -eu
cd "$(dirname "$0")/.."

KEEP="ios-prod ios-prod-watch dsyms ios-testflight mac-testflight ios-appstore mac-appstore ios-appstore-check mac-appstore-check site-fonts"
free() { df -k . | awk 'NR==2 { print $4 }'; }
before=$(free)

dry=0 worktrees=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n) dry=1; shift ;;
        --worktrees) worktrees=1; shift ;;
        *) break ;;
    esac
done
verb=deleted; [ "$dry" = 1 ] && verb="would delete"

clean() {
    [ -d "$1" ] || return 0
    if [ -e "$1/.keep-build" ]; then echo "kept    $1 (.keep-build)"; return 0; fi
    full=$(cd "$1" && pwd -P)
    if pgrep -f "xcodebuild.*($1|$full)" >/dev/null 2>&1; then echo "in use  $1"; return 0; fi
    echo "$verb $1 ($(du -sh "$1" 2>/dev/null | cut -f1))"
    [ "$dry" = 1 ] || rm -rf "$1"
}

sweep() {  # sweep BUILD_DIR: everything in a .build but the symbols and marked folders
    for dir in "$1"/*; do
        [ -d "$dir" ] || continue
        case " $KEEP " in *" $(basename "$dir") "*) echo "kept    $dir"; continue ;; esac
        clean "$dir"
    done
}

sweep .build
for dir in .claude/worktrees/*/.build; do sweep "$dir"; done
for dir in "$@"; do clean "$dir"; done

if [ "$worktrees" = 1 ]; then
    here=$(pwd -P)
    # Working directories of everything running, minus shells and terminal hosts (an open but
    # idle terminal does not make a worktree busy).
    busy=$(lsof -a -d cwd -Fcn 2>/dev/null | awk '/^c/ { c = substr($0, 2) } /^n/ { if (c !~ /^-?(zsh|bash|sh|login|tmux|screen|Orca.*|orca-terminal-host)$/) print substr($0, 2) }')
    git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r tree; do
        [ "$tree" = "$here" ] && continue
        [ -d "$tree/.build" ] || continue
        if [ -e "$tree/.agent-owner" ]; then echo "busy    $tree (.agent-owner)"; continue; fi
        if printf '%s\n' "$busy" | grep -q "^$tree\(/\|$\)"; then echo "busy    $tree (a program is working in it)"; continue; fi
        if [ -n "$(find "$tree/.build" -maxdepth 2 -newermt "-${BANANA_IDLE_HOURS:-6} hours" 2>/dev/null | head -1)" ]; then
            echo "busy    $tree (built in the last ${BANANA_IDLE_HOURS:-6} hours)"; continue
        fi
        sweep "$tree/.build"
    done
    # Xcode's own DerivedData: builds without -derivedDataPath (the IDE, -showBuildSettings).
    for dir in "$HOME"/Library/Developer/Xcode/DerivedData/*-*; do
        [ -d "$dir" ] || continue
        [ -n "$(find "$dir" -maxdepth 1 -mtime -3 2>/dev/null | head -1)" ] && continue
        # Empty leftovers of test runs go without a line each.
        if [ "$(du -sk "$dir" | cut -f1)" -lt 1024 ]; then [ "$dry" = 1 ] || rm -rf "$dir"; continue; fi
        clean "$dir"
    done
fi

# The shared compilation cache, whole, when it is past its cap and nothing is building.
cas="${BANANA_XCODE_CAS:-$HOME/Library/Caches/banana-xcode-cas}"
if [ -d "$cas" ]; then
    cas_gb=$(( $(du -sk "$cas" | cut -f1) / 1048576 ))
    if [ "$cas_gb" -lt "${BANANA_CACHE_LIMIT_GB:-30}" ]; then
        echo "kept    $cas (${cas_gb} GB, cap ${BANANA_CACHE_LIMIT_GB:-30} GB)"
    elif pgrep -x xcodebuild >/dev/null 2>&1; then
        echo "in use  $cas (${cas_gb} GB, over its cap; a build is running)"
    else
        echo "$verb $cas (${cas_gb} GB, over its ${BANANA_CACHE_LIMIT_GB:-30} GB cap)"
        [ "$dry" = 1 ] || rm -rf "$cas"
    fi
fi

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
