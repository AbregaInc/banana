# Gmail push and the Beta 107 service: setup and deploy

The shared cloud mailbox (docs/design/MAIL-CLOUD-SYNC.md §2a) asks Gmail to publish each mailbox's
changes to a Cloud Pub/Sub topic (`users.watch`). A push subscription delivers each notice to
`POST <PUBLIC_URL>/v1/mail/push` with an OIDC token, which the service verifies before it wakes
the mailbox. Do this once per deployment, in the Google Cloud project that owns that deployment's
OAuth web client: Gmail only publishes to a topic in the same project as the client whose token
calls `users.watch`.

Placeholders (the tree is public; the real values are in the deploy notes, not here):

| Placeholder | Meaning |
|---|---|
| `PROJECT_ID` | the deployment's Google Cloud project id |
| `TOPIC` | the Pub/Sub topic Gmail publishes to |
| `PUSH_SA` | the short name of the push subscription's service account |
| `SUBSCRIPTION` | the push subscription's name |
| `PUBLIC_URL` | the service's address (`[vars] PUBLIC_URL` of the environment) |
| `DB` | the environment's D1 database name (`database_name` in wrangler.toml) |
| `ENV_FLAG` | `--env beta` for Beta, nothing for Stable |
| `REVISION` | the full 40-character commit being deployed |

## 1. Google Cloud (once per project)

Already done if they exist: the topic, and Gmail's publisher grant on it.

```sh
gcloud pubsub topics create TOPIC --project PROJECT_ID
gcloud pubsub topics add-iam-policy-binding TOPIC --project PROJECT_ID \
  --member serviceAccount:gmail-api-push@system.gserviceaccount.com --role roles/pubsub.publisher
```

The push subscription's service account. It needs no roles of its own; Pub/Sub mints its tokens,
and whoever creates the subscription must be allowed to act as it.

```sh
gcloud iam service-accounts create PUSH_SA --project PROJECT_ID --display-name "Gmail push to Banana"

PROJECT_NUMBER=$(gcloud projects describe PROJECT_ID --format 'value(projectNumber)')
# Pub/Sub may mint OIDC tokens as it (needed for projects made before April 2021; harmless after).
gcloud iam service-accounts add-iam-policy-binding PUSH_SA@PROJECT_ID.iam.gserviceaccount.com --project PROJECT_ID \
  --member serviceAccount:service-$PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com \
  --role roles/iam.serviceAccountTokenCreator
# You may attach it to a subscription.
gcloud iam service-accounts add-iam-policy-binding PUSH_SA@PROJECT_ID.iam.gserviceaccount.com --project PROJECT_ID \
  --member user:"$(gcloud config get-value account)" --role roles/iam.serviceAccountUser
```

## 2. The service's settings

Neither value is a secret, but both are kept out of the public wrangler.toml and must survive
every later deploy, so they are set as Worker secrets (the service reads them like any variable;
the Mailbox Durable Object sees them too):

```sh
cd Service
printf '%s' 'projects/PROJECT_ID/topics/TOPIC' | npx wrangler secret put MAIL_PUSH_TOPIC ENV_FLAG
printf '%s' 'PUSH_SA@PROJECT_ID.iam.gserviceaccount.com' | npx wrangler secret put MAIL_PUSH_SERVICE_ACCOUNT ENV_FLAG
```

`MAIL_PUSH_AUDIENCE` is only needed if the subscription's audience is not exactly
`PUBLIC_URL/v1/mail/push`. `MAIL_FILL_DAYS` (default 183) is optional. The service already has
`APNS_KEY`, `APNS_KEY_ID` and `APNS_TEAM_ID`, which the mail push uses.

## 3. Database, then code

Migrations first (the new code writes `mail_mailboxes.watch_expires_at`, 0023, and `wake_at`, 0024):

```sh
cd Service
npx wrangler d1 migrations list DB --remote ENV_FLAG      # expect 0023_mail_watch.sql and 0024_mail_snooze_wake.sql pending
npx wrangler d1 migrations apply DB --remote ENV_FLAG
```

Then the Worker, from a clean checkout of the reviewed commit (tests first):

```sh
npm ci && npm test
python3 ../tools/publication/source-offer-env.py --repository https://github.com/OWNER/REPO   # prints the two source values
npx wrangler deploy ENV_FLAG --var SOURCE_REVISION:REVISION --var SOURCE_ARCHIVE_URL:https://github.com/OWNER/REPO/archive/REVISION.tar.gz
curl -s PUBLIC_URL/v1/source                                # names REVISION
```

## 4. The push subscription (after the deploy, so its first deliveries find the route)

```sh
gcloud pubsub subscriptions create SUBSCRIPTION --project PROJECT_ID --topic TOPIC \
  --push-endpoint PUBLIC_URL/v1/mail/push \
  --push-auth-service-account PUSH_SA@PROJECT_ID.iam.gserviceaccount.com \
  --push-auth-token-audience PUBLIC_URL/v1/mail/push \
  --ack-deadline 10 --message-retention-duration 1h \
  --min-retry-delay 5s --max-retry-delay 60s
```

Each mailbox starts its watch on its next alarm (within minutes of a device reading the feed),
and the quarter-hour job renews every watch a day before Gmail ends it (7 days).

## Why no label filter

`users.watch` with `labelIds: ["INBOX"]` notifies only for changes to messages that carry `INBOX`
after the change, so an archive, a label added on the web to mail outside the Inbox, or a message
sent from another client would never wake the mailbox. The watch is unfiltered; a notice only
wakes a history read (2 units), and wakes coalesce.

## Checks once it runs

- `wrangler tail ENV_FLAG`: `mail push: refused (…)` appears only for bad tokens; `push(mail): N
  device(s)` after new mail.
- `mail_mailboxes.watch_expires_at` is about 7 days ahead for each mailbox:
  `npx wrangler d1 execute DB --remote ENV_FLAG --command "SELECT COUNT(*), MIN(watch_expires_at) FROM mail_mailboxes"`.
- Pub/Sub's subscription metrics show acknowledged (204) deliveries.
- If the topic grant is missing, `users.watch` answers 403, the mailbox logs `watch failed (403)`,
  keeps polling at the unwatched cadence, and tries again hourly.

Rolling back the push only: delete the subscription and the two secrets; mailboxes fall back to
polling, and their watches end within 7 days.
