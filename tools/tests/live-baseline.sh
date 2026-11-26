#!/bin/bash
# A Service deploy must contain the live revision: tools/release/live-baseline.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
git init -q -b main .
git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base
base=$(git rev-parse HEAD)
git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m live
live=$(git rev-parse HEAD)
git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m backport
git switch -q -c feature "$base"
git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m feature
. "$root/tools/release/live-baseline.sh"

fail() { echo "FAIL: $*"; exit 1; }
contains_live_revision "$live" main >/dev/null || fail "a branch built on the live revision was refused"
contains_live_revision "$live" "$live" >/dev/null || fail "the live revision itself was refused"
if why=$(contains_live_revision "$live" feature); then fail "a branch without the live revision was accepted"; fi
case "$why" in *"does not contain the live revision ${live:0:12}"*) ;; *) fail "unexpected reason: $why" ;; esac
if contains_live_revision "" main >/dev/null; then fail "an unknown live revision was accepted"; fi
if contains_live_revision 0123456789abcdef0123456789abcdef01234567 main >/dev/null; then fail "a missing live revision was accepted"; fi
echo "live-baseline: ok"
