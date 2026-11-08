#!/bin/bash
# Deploy the Banana service (Service/) to Beta or production, from a pushed, clean commit.
#
#   tools/release/deploy-service.sh beta
#   tools/release/deploy-service.sh prod --yes-prod
#   tools/release/deploy-service.sh beta --dry-run      # the checks that touch nothing, and the plan
#
# Steps:
#   1. clean tree, HEAD pushed, and the commit's public source archive downloadable (the service
#      links to it: Service/README.md, "Versioned source offer");
#   2. npm test;
#   3. the pending D1 migrations, each checked additive (tools/release/migration-additive.py), then
#      applied: before the Worker, which may read their columns;
#   4. wrangler deploy with SOURCE_REVISION and SOURCE_ARCHIVE_URL for this commit;
#   5. smoke test: /v1/health, /v2/sync answers signed_out, /v1/source names this commit.
# `prod` refuses to run without --yes-prod. A dry run checks the migrations changed since the last
# release tag instead of asking D1 which are pending.
set -uo pipefail
cd "$(dirname "$0")/../.."
. tools/release/lib.sh

target=${1:-}; shift || true
yes_prod=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes-prod) yes_prod=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done
case "$target" in
  beta) env_args=(--env beta); db=banana-service-beta; host=https://beta-api.bananatheapp.com ;;
  prod) env_args=(--env=""); db=banana-service; host=https://api.bananatheapp.com
        [ "$yes_prod" = 1 ] || die "production deploys need --yes-prod" ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac
WRANGLER=(npx --yes "wrangler@${WRANGLER_VERSION:-4.158.0}")
rev=$(git rev-parse HEAD)
archive="https://github.com/$REPO_SLUG/archive/$rev.tar.gz"
if [ "$DRY_RUN" = 1 ]; then OUT=$(mktemp -d "${TMPDIR:-/tmp}/deploy-service-$target.XXXXXX"); else OUT=private/releases/service-$target-$(date +%Y%m%d-%H%M%S); fi
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd -P)
trap 'summary' EXIT
say "Deploy service to $target ($host) from ${rev:0:12}$([ "$DRY_RUN" = 1 ] && echo ', dry run')"

step source
if [ "$DRY_RUN" = 1 ]; then
  require_clean_tree || say "  (a real deploy refuses this tree)"
else
  require_clean_tree || die "commit first: the deployed revision must be a public commit"
  git fetch origin --quiet
  git branch -r --contains "$rev" | grep -q . || die "push ${rev:0:12} first: the source offer must be downloadable"
  curl -fsIL -o /dev/null "$archive" || die "the source archive is not downloadable: $archive"
fi
say "  SOURCE_ARCHIVE_URL=$archive"
step_done

step tests
run npm --prefix Service ci --no-audit --no-fund || die "npm ci failed"
run npm --prefix Service test || die "service tests failed"
step_done

step migrations
if [ "$DRY_RUN" = 1 ]; then
  tag=$(last_release_tag)
  pending=$(git diff --name-only --diff-filter=A "${tag:-HEAD}" HEAD -- Service/migrations/ | sed 's|^Service/migrations/||')
  say "  added since ${tag:-?}: ${pending:-none} (a real deploy asks D1 which are pending)"
else
  (cd Service && "${WRANGLER[@]}" d1 migrations list "$db" --remote "${env_args[@]}") > "$OUT/migrations-list.txt" 2>&1 ||
    { cat "$OUT/migrations-list.txt"; die "could not list pending migrations"; }
  pending=$(grep -oE '[0-9]{4}_[A-Za-z0-9_]+\.sql' "$OUT/migrations-list.txt" | sort -u)
  say "  pending: ${pending:-none}"
fi
if [ -n "$pending" ]; then
  files=(); for f in $pending; do files+=("Service/migrations/$f"); done
  python3 tools/release/migration-additive.py "${files[@]}" || die "a pending migration is not additive: apply it as its own reviewed step"
  (cd Service && run "${WRANGLER[@]}" d1 migrations apply "$db" --remote "${env_args[@]}") || die "migrations failed"
fi
step_done

step deploy
(cd Service && run "${WRANGLER[@]}" deploy "${env_args[@]}" --var "SOURCE_REVISION:$rev" --var "SOURCE_ARCHIVE_URL:$archive") ||
  die "deploy failed"
step_done

step smoke
if [ "$DRY_RUN" = 1 ]; then
  say "  would check $host/v1/health, POST $host/v2/sync (401 signed_out), $host/v1/source (revision ${rev:0:12})"
else
  [ "$(curl -fsS "$host/v1/health")" = ok ] || die "health check failed"
  code=$(curl -s -o "$OUT/sync.json" -w '%{http_code}' -X POST "$host/v2/sync" -H 'content-type: application/json' -d '{}')
  [ "$code" = 401 ] || die "/v2/sync answered $code, not 401"
  curl -fsS "$host/v1/source" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=sys.argv[1]; sys.exit(0 if r in json.dumps(d) else "the source offer names another revision")' "$rev" ||
    die "/v1/source does not name ${rev:0:12}"
  say "  health ok, sync 401, source ${rev:0:12}"
fi
step_done
if [ "$DRY_RUN" = 1 ]; then say "Dry run complete: nothing was deployed."; else say "Service $target is at ${rev:0:12}."; fi
