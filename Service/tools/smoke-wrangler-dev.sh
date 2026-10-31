#!/usr/bin/env bash
# The data platform under `wrangler dev --local` (workerd, a local D1, the Space Durable Object, a
# local R2), for one wrangler config: `tools/smoke-wrangler-dev.sh` (the default) or
# `tools/smoke-wrangler-dev.sh beta`. Everything lives in a throwaway --persist-to folder, never in
# .wrangler, and nothing remote is touched. Prints a transcript (commands and trimmed answers) in
# Markdown; tools/smoke-wrangler-dev.md keeps the last one.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_NAME="${1:-}"
PORT="${PORT:-8799}"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/banana-smoke.XXXXXX")"
LOG="$STATE/wrangler-dev.log"
export WRANGLER_SEND_METRICS=false
if [ -n "$ENV_NAME" ]; then ENVFLAG=(--env "$ENV_NAME"); DB=banana-service-$ENV_NAME; BUCKET=banana-blobs-$ENV_NAME
else ENVFLAG=(--env=""); DB=banana-service; BUCKET=banana-blobs; fi
B="http://127.0.0.1:$PORT"
TOKEN="smoke-session-token-000000000001"
AUTH="authorization: Bearer $TOKEN"
trap 'lsof -ti "tcp:$PORT" | xargs kill 2>/dev/null || true; rm -rf "$STATE"' EXIT

# Trims a JSON answer to the keys named (top level), arrays shortened.
trim() { node -e '
  let t = ""; process.stdin.on("data", (d) => t += d).on("end", () => {
    let j; try { j = JSON.parse(t); } catch { return console.log(t.slice(0, 200)); }
    const keys = process.argv.slice(1);
    const out = keys.length ? Object.fromEntries(keys.filter((k) => k in j).map((k) => [k, j[k]])) : j;
    console.log(JSON.stringify(out, (k, v) => typeof v === "string" && v.length > 40 ? v.slice(0, 12) + "…" : v));
  });' "$@"; }
step() { printf '\n**%s**\n\n```\n' "$1"; }
done_() { printf '```\n'; }

echo "## \`wrangler dev --local\` ${ENV_NAME:-default}"
echo
echo "wrangler $(npx wrangler --version 2>/dev/null | tail -1), $(date -u +%Y-%m-%dT%H:%MZ), D1 \`$DB\`, R2 \`$BUCKET\`"

step "Migrations 0001–0009 on a fresh local D1"
echo "\$ wrangler d1 migrations apply $DB --local --persist-to <tmp> ${ENVFLAG[*]}"
npx wrangler d1 migrations apply "$DB" --local --persist-to "$STATE" "${ENVFLAG[@]}" 2>&1 | grep -E "✅" | sed -E 's/[│ ]+/ /g' | awk '!seen[$0]++'
done_

HASH=$(printf %s "$TOKEN" | shasum -a 256 | cut -d' ' -f1)
npx wrangler d1 execute "$DB" --local --persist-to "$STATE" "${ENVFLAG[@]}" --command "
  INSERT INTO accounts (id, created_at) VALUES ('acc-smoke', 1);
  INSERT INTO sessions (token_hash, account_id, created_at, last_used_at) VALUES ('$HASH', 'acc-smoke', 1, 9999999999999);
  INSERT INTO devices (id, account_id, platform, push_token, push_env, bundle, updated_at) VALUES ('phone-smoke1', 'acc-smoke', 'iphone', NULL, 'production', 'app.banana.Banana', 1);" >/dev/null

npx wrangler dev --local --persist-to "$STATE" "${ENVFLAG[@]}" --port "$PORT" --ip 127.0.0.1 >"$LOG" 2>&1 &
for _ in $(seq 1 60); do curl -s -o /dev/null "$B/v1/health" && break; sleep 0.5; done
step "Bindings wrangler dev reports"
grep -E "env\.(SPACES|DB|BLOBS)" "$LOG" | sed -E 's/ +/ /g'
done_

NOW=$(($(date +%s) * 1000))
sync() { curl -s -X POST "$B/v2/sync" -H "$AUTH" -H 'content-type: application/json' -d "$1"; }

step "A build-61 device registration (the body before 0009) still works"
echo "\$ PUT /v1/devices/mac-smoke001 {platform, push, pushEnv, bundle}"
curl -s -o /dev/null -w '%{http_code}\n' -X PUT "$B/v1/devices/mac-smoke001" -H "$AUTH" -H 'content-type: application/json' \
  -d '{"platform":"mac","push":null,"pushEnv":"production","bundle":"app.banana.Banana"}'
done_

step "A sync"
echo "\$ POST /v2/sync plan.extra e1"
sync '{"device":"phone-smoke1","since":0,"changes":[{"type":"plan.extra","id":"e1","set":{"title":"Swim","day":"2026-10-19"},"clocks":{"title":"'$NOW'.0000.phone","day":"'$NOW'.0000.phone"}}]}' | trim head next more applied rejected consents
done_

step "T2 refused without the Health consent; a clock an hour ahead refused"
echo "\$ POST /v2/sync food.meal m1; plan.extra e2 at now + 1 h"
sync '{"device":"phone-smoke1","since":1,"changes":[{"type":"food.meal","id":"m1","set":{"title":"Oats"},"clocks":{"title":"'$NOW'.0000.phone"}},{"type":"plan.extra","id":"e2","set":{"title":"Run"},"clocks":{"title":"'$((NOW + 3600000))'.0000.phone"}}]}' | trim head rejected consents
done_

printf 'smoke voice note' >"$STATE/note.bin"; NOTE=$(shasum -a 256 "$STATE/note.bin" | cut -d' ' -f1)
head -c 20971520 /dev/urandom >"$STATE/big.bin"; BIG=$(shasum -a 256 "$STATE/big.bin" | cut -d' ' -f1)
put() { curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" -X PUT "$B/v2/blobs/$1" -H "$AUTH" -H "x-banana-type: $2" --data-binary "@$3"; }
step "Blob PUT: wrong sha, right sha, 20 MB, and the 20 MB back"
echo "\$ PUT /v2/blobs/<zeros> (notes.voiceNote)"; put "$(printf '0%.0s' $(seq 64))" notes.voiceNote "$STATE/note.bin"
echo "\$ PUT /v2/blobs/<sha> (notes.voiceNote)"; put "$NOTE" notes.voiceNote "$STATE/note.bin"
echo "\$ PUT /v2/blobs/<sha of 20 MB> (podcast.listen)"; put "$BIG" podcast.listen "$STATE/big.bin"
echo "\$ GET /v2/blobs/<sha of 20 MB>"
curl -s "$B/v2/blobs/$BIG" -H "$AUTH" -o "$STATE/big.back" -w '%{http_code} %{size_download} bytes %{time_total}s\n'
cmp -s "$STATE/big.bin" "$STATE/big.back" && echo "byte for byte the same"
done_

printf 'smoke meal photo' >"$STATE/photo.bin"; PHOTO=$(shasum -a 256 "$STATE/photo.bin" | cut -d' ' -f1)
step "Consent, a T2 photo, then the withdrawal: the alarm moves the photo to trash/"
echo "\$ PUT /v2/consents/health"
curl -s -o /dev/null -w '%{http_code}\n' -X PUT "$B/v2/consents/health" -H "$AUTH" -H 'content-type: application/json' -d '{"version":"1","device":"phone-smoke1"}'
echo "\$ PUT /v2/blobs/<photo> (food.mealPhoto)"; put "$PHOTO" food.mealPhoto "$STATE/photo.bin"
echo "\$ POST /v2/sync food.mealPhoto p1 naming it"
sync '{"device":"phone-smoke1","since":1,"changes":[{"type":"food.mealPhoto","id":"p1","set":{"v":{"$blob":"'$PHOTO'","ext":"jpg"}},"clocks":{"v":"'$NOW'.0001.phone"}}]}' | trim head rejected consents
echo "\$ DELETE /v2/consents/health"
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE "$B/v2/consents/health" -H "$AUTH"
for i in $(seq 1 10); do c=$(curl -s -o /dev/null -w '%{http_code}' -I "$B/v2/blobs/$PHOTO" -H "$AUTH"); [ "$c" = 404 ] && { echo "HEAD /v2/blobs/<photo>: 404 after ${i} look(s)"; break; }; sleep 0.5; done
echo "R2 keys now (space id shortened):"
sqlite3 "$(ls "$STATE"/v3/r2/miniflare-R2BucketObject/*.sqlite | grep -v metadata)" "SELECT key, size FROM _mf_objects ORDER BY key" | sed -E 's#(sp_)[^/]+#\1…#; s#/([0-9a-f]{8})[0-9a-f]{56}#/\1…#'
done_

step "Export (NDJSON): what kinds of lines"
echo "\$ GET /v2/export"
curl -s "$B/v2/export" -H "$AUTH" | node -e 'let t="";process.stdin.on("data",(d)=>t+=d).on("end",()=>{const k={};for(const l of t.trim().split("\n")){const j=JSON.parse(l);const n=j.kind+(j.type?" "+j.type:"");k[n]=(k[n]??0)+1;}console.log(JSON.stringify(k));})'
done_

step "/v1/account"
echo "\$ GET /v1/account"
curl -s "$B/v1/account" -H "$AUTH" | trim
done_

step "Errors in the wrangler dev log"
grep -iE "error|exception|uncaught" "$LOG" | grep -v "push(sync)" || echo "none"
done_
