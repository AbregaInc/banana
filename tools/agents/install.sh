#!/bin/sh
# Install the shared agent tools into ~/.config/banana-agents/ (or $BANANA_LOCK_DIR).
#
#   tools/agents/install.sh          # copy xcode-lock.sh there
#   tools/agents/install.sh --check  # exit 1 when the installed copy differs from this checkout's
#
# A copy, not a symlink: a link into one worktree breaks when that worktree changes branch or is
# removed, and every agent's lock would go with it. Scripts in this repo call
# tools/agents/xcode-lock.sh directly; the installed copy serves callers outside a checkout and
# older scripts that name ~/.config/banana-agents/xcode-lock.sh.
set -eu
cd "$(dirname "$0")"
dest="${BANANA_LOCK_DIR:-$HOME/.config/banana-agents}"
if [ "${1:-}" = --check ]; then
  cmp -s xcode-lock.sh "$dest/xcode-lock.sh" && { echo "xcode-lock.sh is current"; exit 0; }
  echo "xcode-lock.sh in $dest differs from this checkout's; run tools/agents/install.sh"
  exit 1
fi
mkdir -p "$dest"
# Replace atomically: a running agent may be reading the old copy.
cp xcode-lock.sh "$dest/.xcode-lock.sh.new"
chmod 755 "$dest/.xcode-lock.sh.new"
mv -f "$dest/.xcode-lock.sh.new" "$dest/xcode-lock.sh"
echo "installed $dest/xcode-lock.sh"
