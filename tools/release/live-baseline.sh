# Sourced by tools/release/deploy-service.sh. Production runs a curated baseline (backports land
# on a branch made from the live revision), so a deploy must contain the live revision or it drops
# what production already serves.

# live_revision HOST: the commit HOST's /v1/source names, or nothing.
live_revision() {
  curl -fsS "$1/v1/source" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("revision",""))' 2>/dev/null
}

# contains_live_revision LIVE [REV]: succeed when REV (default HEAD) contains LIVE; otherwise say why.
contains_live_revision() {
  local live=$1 rev=${2:-HEAD}
  if [ -z "$live" ]; then echo "the live revision is unknown"; return 1; fi
  if ! git cat-file -e "$live^{commit}" 2>/dev/null; then
    echo "the live revision ${live:0:12} is not in this clone (git fetch origin)"; return 1
  fi
  if ! git merge-base --is-ancestor "$live" "$rev"; then
    echo "${rev} does not contain the live revision ${live:0:12}: branch from it and cherry-pick the change"
    return 1
  fi
}
