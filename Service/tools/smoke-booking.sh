#!/usr/bin/env bash
# The booking pages under `wrangler dev --local` (workerd, a local D1): `tools/smoke-booking.sh`.
# A throwaway --persist-to folder; nothing remote is touched and no Google account is used: the
# host's link has no token, and its busy snapshot is seeded (fresh) so the pages need no Google.
# The deferred event-making therefore meets "Google refused" and the booking ends as failed: that
# path is part of the smoke. Prints a Markdown transcript with TTFBs; tools/smoke-booking.md keeps
# the last one.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${PORT:-8798}"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/banana-booking-smoke.XXXXXX")"
LOG="$STATE/wrangler-dev.log"
export WRANGLER_SEND_METRICS=false
B="http://127.0.0.1:$PORT"
KEY="$(node -e 'console.log(Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64"))')"
trap 'lsof -ti "tcp:$PORT" | xargs kill 2>/dev/null || true; rm -rf "$STATE"' EXIT
step() { printf '\n**%s**\n\n```\n' "$1"; }
done_() { printf '```\n'; }
ttfb() { curl -s -o /dev/null -w '%{http_code} ttfb %{time_starttransfer}s total %{time_total}s\n' "$@"; }

echo "## \`wrangler dev --local\`: booking"
echo
echo "wrangler $(npx wrangler --version 2>/dev/null | tail -1), $(date -u +%Y-%m-%dT%H:%MZ)"

step "Migrations on a fresh local D1"
npx wrangler d1 migrations apply banana-service --local --persist-to "$STATE" --env="" 2>&1 | grep -E "✅" | sed -E 's/[│ ]+/ /g' | awk '!seen[$0]++' | tail -2
done_

NOW=$(($(date +%s) * 1000))
FRESH=$((NOW + 86400000))   # computed "tomorrow": never stale during the smoke, so nothing asks Google
TO=$((NOW + 31 * 86400000))
BUSY_S=$((NOW + 2 * 86400000)); BUSY_E=$((BUSY_S + 3600000))
HORIZON="{\"from\":$NOW,\"to\":$TO,\"busy\":[[$BUSY_S,$BUSY_E]],\"calendars\":[{\"sub\":\"sub-smoke\",\"id\":\"primary-smoke\",\"tz\":\"America/New_York\"}],\"unknown\":0,\"write\":{\"sub\":\"sub-smoke\",\"email\":\"host@example.invalid\"}}"
npx wrangler d1 execute banana-service --local --persist-to "$STATE" --env="" --command "
  INSERT INTO accounts (id, created_at, display_name, time_zone) VALUES ('acc-smoke', 1, 'Smoke Host', 'America/New_York');
  INSERT INTO google_links (sub, account_id, email, refresh_token, scopes, status, created_at, updated_at)
    VALUES ('sub-smoke', 'acc-smoke', 'host@example.invalid', NULL, 'openid email https://www.googleapis.com/auth/calendar', 'ok', 1, 1);
  INSERT INTO booking_handles (handle, account_id, time_zone, created_at, updated_at) VALUES ('smoke', 'acc-smoke', 'America/New_York', 1, 1);
  INSERT INTO busy_snapshot (account_id, horizon_json, types_json, computed_at) VALUES ('acc-smoke', '$HORIZON', NULL, $FRESH);" >/dev/null

# --local-upstream keeps the request's own host and Origin (wrangler dev otherwise rewrites them to the first route's).
npx wrangler dev --local --persist-to "$STATE" --env="" --port "$PORT" --ip 127.0.0.1 --local-upstream "127.0.0.1:$PORT" --upstream-protocol http \
  --var "BOOK_URL:$B" --var "SERVE_AS:book" --var "TOKEN_KEY:$KEY" --var "TURNSTILE_SKIP:1" >"$LOG" 2>&1 &
for _ in $(seq 1 60); do curl -s -o /dev/null "$B/" && break; sleep 0.5; done

step "Bindings"
grep -E "env\.(DB|RL_|EMAIL)" "$LOG" | sed -E 's/ +/ /g'
done_

step "GET /smoke (one type: the times, the whole horizon in the HTML), five times"
for i in 1 2 3 4 5; do ttfb "$B/smoke"; done
curl -s -D - -o "$STATE/page.html" "$B/smoke" | grep -iE "^(server-timing|content-security-policy|cache-control):" | cut -c1-160
echo "HTML $(wc -c <"$STATE/page.html" | tr -d ' ') bytes, $(gzip -c "$STATE/page.html" | wc -c | tr -d ' ') gzipped"
done_

step "GET /smoke/meeting/slots"
curl -s "$B/smoke/meeting/slots" | node -e 'let t="";process.stdin.on("data",(d)=>t+=d).on("end",()=>{const j=JSON.parse(t);console.log(`${j.slots.length} slots, first ${j.slots[0].start}, busy ${j.busy}`);})'
ttfb "$B/smoke/meeting/slots"
done_

FIRST=$(curl -s "$B/smoke/meeting/slots" | node -e 'let t="";process.stdin.on("data",(d)=>t+=d).on("end",()=>console.log(JSON.parse(t).slots[3].start))')
SECOND=$(curl -s "$B/smoke/meeting/slots" | node -e 'let t="";process.stdin.on("data",(d)=>t+=d).on("end",()=>console.log(JSON.parse(t).slots[5].start))')
post() { curl -s -X POST "$B$1" -H "origin: $B" -H 'content-type: application/json' -d "$2" -w '\n%{http_code} ttfb %{time_starttransfer}s\n'; }

step "POST without our Origin"
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$B/smoke/meeting/book" -H 'content-type: application/json' -d '{}'
done_

step "POST /smoke/meeting/book (the reservation's answer)"
ANSWER=$(post /smoke/meeting/book "{\"key\":\"smoke-key-000001\",\"start\":\"$FIRST\",\"name\":\"Sam Smoke\",\"email\":\"sam@example.invalid\",\"zone\":\"Europe/London\"}")
echo "$ANSWER" | head -1 | cut -c1-220; echo "$ANSWER" | tail -1
REF=$(echo "$ANSWER" | head -1 | node -e 'let t="";process.stdin.on("data",(d)=>t+=d).on("end",()=>console.log(JSON.parse(t).booking.manageUrl.split("/").pop()))')
echo "the same post again:"
post /smoke/meeting/book "{\"key\":\"smoke-key-000001\",\"start\":\"$FIRST\",\"name\":\"Sam Smoke\",\"email\":\"sam@example.invalid\",\"zone\":\"Europe/London\"}" | tail -1
done_

step "A time that isn't offered: refused, with the nearest three"
post /smoke/meeting/book "{\"key\":\"smoke-key-000002\",\"start\":\"${FIRST%:00.000Z}:10.000Z\",\"name\":\"Kim\",\"email\":\"kim@example.invalid\",\"zone\":\"UTC\"}" | head -1 | cut -c1-200
done_

sleep 2
step "The follow-up: the host's link has no token, so Google is refused and the booking fails"
curl -s "$B/m/$REF/state" | node -e 'let t="";process.stdin.on("data",(d)=>t+=d).on("end",()=>{const b=JSON.parse(t).booking;console.log(JSON.stringify({status:b.status,invite:b.invite,nearest:(b.nearest||[]).length}));})'
done_

step "A second booking and its Undo (it has already failed here, as above, so Undo is too late: 409)"
UNDO=$(post /smoke/meeting/book "{\"key\":\"smoke-key-000003\",\"start\":\"$SECOND\",\"name\":\"Ola\",\"email\":\"ola@example.invalid\",\"zone\":\"Asia/Kolkata\"}" | head -1)
REF2=$(echo "$UNDO" | node -e 'let t="";process.stdin.on("data",(d)=>t+=d).on("end",()=>console.log(JSON.parse(t).booking.manageUrl.split("/").pop()))')
post /b/undo "{\"manage\":\"$REF2\"}" | tail -1
done_

step "The calendar file, a forged manage link, and the code (404 here: no email provider under wrangler dev)"
curl -s "$B/b/${REF2%%.*}.ics?sig=${REF2#*.}" | grep -E "^(UID|DTSTART|STATUS)" | sed -E 's/UID:.{8}/UID:…/'
curl -s -o /dev/null -w 'forged: %{http_code}\n' "$B/m/${REF2%?}A"
post /b/code '{"email":"sam@example.invalid"}' | tail -1
done_

step "What the Worker logged (booking lines)"
grep -E "booking|email:|turnstile|push\(" "$LOG" | sed -E 's/\x1b\[[0-9;]*m//g' | sort | uniq -c | head -20
done_

step "Errors in the wrangler dev log"
grep -iE "error|exception|uncaught" "$LOG" | grep -v "booking: try" || echo "none"
done_
