#!/bin/bash
# Plays every script in tools/mac-key-scripts offscreen (see mac-mail-keydriver.sh) and says which passed.
#   tools/mac-mail-keydriver-all.sh <output-dir> [--no-build]
set -u
out="${1:?usage: mac-mail-keydriver-all.sh <output-dir> [--no-build]}"
build="${2:-}"
cd "$(dirname "$0")/.."
mkdir -p "$out"
failed=0
first=1
for script in tools/mac-key-scripts/[1-9]*.keys; do
  name="$(basename "$script" .keys)"
  flag="--no-build"
  if [ "$first" = 1 ] && [ "$build" != "--no-build" ]; then flag=""; fi
  first=0
  if tools/mac-mail-keydriver.sh "$script" "$out/$name" $flag > "$out/$name.console.txt" 2>&1; then
    echo "PASS  $name"
  else
    echo "FAIL  $name   ($(grep -c '^  - ' "$out/$name.console.txt") failures)"
    failed=$((failed + 1))
  fi
done
echo "$failed script(s) with failures; logs and pictures in $out/<script>/"
exit $failed
