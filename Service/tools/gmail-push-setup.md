# Gmail push: Google Cloud setup

The shared cloud mailbox (docs/design/MAIL-CLOUD-SYNC.md §2a) asks Gmail to publish each mailbox's
changes to a Cloud Pub/Sub topic (`users.watch`). A push subscription delivers each notice to
`POST <PUBLIC_URL>/v1/mail/push` with an OIDC token, which the service verifies before it wakes
the mailbox. Nothing here has been run. Do it once per deployment (beta, production), in the
Google Cloud project that owns that deployment's OAuth web client: Gmail only publishes to a
topic in the same project as the client whose token calls `users.watch`.

Placeholders: `PROJECT_ID`, `TOPIC` (for example `gmail-changes`), `SUBSCRIPTION`,
`PUSH_SA` (a service account the subscription signs its tokens as), `PUBLIC_URL`
(`https://beta-api.…` or `https://api.…`), `ENV_FLAG` (`--env beta`, or nothing for production).

```sh
# 1. The topic.
gcloud pubsub topics create TOPIC --project PROJECT_ID

# 2. Gmail may publish to it (Google's own publisher account; the name is fixed).
gcloud pubsub topics add-iam-policy-binding TOPIC --project PROJECT_ID \
  --member serviceAccount:gmail-api-push@system.gserviceaccount.com --role roles/pubsub.publisher

# 3. A service account for the subscription's tokens. It needs no roles of its own.
gcloud iam service-accounts create PUSH_SA --project PROJECT_ID --display-name "Gmail push to Banana"

# 4. Pub/Sub may mint tokens as it (the project's Pub/Sub service agent).
PROJECT_NUMBER=$(gcloud projects describe PROJECT_ID --format 'value(projectNumber)')
gcloud iam service-accounts add-iam-policy-binding PUSH_SA@PROJECT_ID.iam.gserviceaccount.com --project PROJECT_ID \
  --member serviceAccount:service-$PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com \
  --role roles/iam.serviceAccountTokenCreator

# 5. The push subscription, authenticated, with the service's endpoint as the audience.
gcloud pubsub subscriptions create SUBSCRIPTION --project PROJECT_ID --topic TOPIC \
  --push-endpoint PUBLIC_URL/v1/mail/push \
  --push-auth-service-account PUSH_SA@PROJECT_ID.iam.gserviceaccount.com \
  --push-auth-token-audience PUBLIC_URL/v1/mail/push \
  --ack-deadline 10 --message-retention-duration 1h \
  --min-retry-delay 5s --max-retry-delay 60s
```

Then the service's settings (wrangler.toml `[vars]` or `[env.beta.vars]`; none is secret):

| Name | Value |
|---|---|
| `MAIL_PUSH_TOPIC` | `projects/PROJECT_ID/topics/TOPIC` |
| `MAIL_PUSH_SERVICE_ACCOUNT` | `PUSH_SA@PROJECT_ID.iam.gserviceaccount.com` |
| `MAIL_PUSH_AUDIENCE` | only if it differs from `PUBLIC_URL/v1/mail/push` |

Order: apply D1 migration `0023_mail_watch.sql` (`wrangler d1 migrations apply DB ENV_FLAG
--remote`), deploy the service with the settings, then create the subscription (step 5) so its
first deliveries find the route. Each mailbox starts its watch on its next alarm, and the
quarter-hour job renews every watch a day before Gmail ends it (7 days).

Why no label filter: `users.watch` with `labelIds: ["INBOX"]` notifies only for changes to
messages that carry `INBOX` after the change, so an archive, a label added on the web to mail
outside the Inbox, or a message sent from another client would never wake the mailbox. The
watch is unfiltered; a notice only wakes a history read (2 units), and wakes coalesce.

Checks once it runs: the service log shows `mail push:` lines only for refusals; a mailbox's
`status()` has `watchExpires` about 7 days ahead; Pub/Sub's subscription metrics show
acknowledged (204) deliveries. If the topic grant is missing, `users.watch` answers 403, the
mailbox logs `watch failed (403)`, keeps polling at the unwatched cadence, and tries again hourly.
