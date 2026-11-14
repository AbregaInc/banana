# Email feedback and AI follow-up

## Work during App Store review

Continue in the separate Beta apps while submitted App Store binaries stay under
review. Validate a common Beta source revision on phone, iPad and Mac so a report
can be matched to the code actually running. Recent feedback spans different builds;
a successful phone-only check does not validate the older Mac or iPad installation.

Use the existing report → private case → fix → regression loop. Raw messages,
screenshots, addresses and reports stay in ignored `private/`. TestFlight feedback
and in-app reports are separate sources and both are read during triage.

## First email batch

- Keep normal attachments above the body. Put inline-image download controls in a
  collapsed Images group after it, where the images are already shown in context.
  Keep executable/type-mismatch warnings and non-image files in the normal header.
- Keep short receipt labels and values together, including one-cell nested table wrappers.
  Convert table-based bullet markers into native list items without duplicate dots.
- Fold the final quoted run while leaving following signature pictures visible.
- Use the existing Google Reconnect action to upgrade enabled features' permissions
  together. A reusable prompt detects missing requirements, supports deferral/retry,
  and preserves existing access when an upgrade is declined.
- Fall back to the address when the sender name is blank.
- Live reports attach stored source HTML rather than the sanitized Original viewer
  document. Legacy private cases restore the viewer's image URLs to MIME content-ID
  sources, so replay does not silently discard inline pictures.

These changes do not close the whole formatting backlog. The remaining reports
cover richer table relationships, excessive image content and digest grouping,
post-send success/undo state, unread ordering, initial inbox
availability and sender identity/status. Verify each on the current renderer and
retain an explicit expected result before marking it resolved. Preserve useful
content and relationships while removing template decoration; do not assume every
email is an article or every layout table is disposable.

## Google Contacts

Follow [the GCP setup instructions](../development/GOOGLE-CONTACTS-SETUP.md).
The sender-photo integration and scope requests exist. Composer suggestions
currently use local correspondents. Contacts-backed suggestions still need an
implementation that keeps local suggestions responsive, rejects stale async
results, preserves To/Cc/Bcc behavior and tolerates missing Contacts permission.

## Later AI work

Requested for later, outside the current email-fix batch:

- Draft context-aware replies using the thread, prior replies and the user's style.
- Recommend reply, archive, follow-up or task actions using prior triage choices and
  correspondent behavior. Keep the evidence behind a recommendation inspectable.
- Use accepted drafts, edits, rejected suggestions and action reversals as evaluation
  feedback. Historical patterns inform suggestions; they do not authorize sending.
- Add regression cases for recipient selection, reply versus reply-all, account
  identity, tone, commitments, missing history and misleading message instructions.
- Investigate Banana as a personal-agent client of
  [Poppy / Personal Agent Protocol 1.0](https://personalagentprotocol.org/docs/introduction):
  company discovery, scoped authorization and the available API/web/company-agent
  routes. Existing tool or MCP support alone is not Poppy compatibility.

No historical-learning behavior or Poppy implementation is included in this batch.
