# Gmail release verification

Checked 5 November 2026. This is a release gate, not an approval record.

The production Google project currently has verified Calendar access and no Gmail scope.
Staging is External/Testing, has `gmail.modify`, and has Gmail API enabled. These are different
projects and approval does not transfer between them. Keep actual project/client identifiers
in private deployment inventory.

Google classifies `gmail.modify` as restricted. Public use requires restricted-scope
verification unless an exception applies. Access through Banana Cloud also brings the server
security-assessment requirement into scope, including when the service only transmits data.
See Google's [scope list](https://developers.google.com/workspace/gmail/api/auth/scopes) and
[restricted-scope verification requirements](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification).
A TestFlight group or Banana feature grant does not provide Google approval.

## Evidence to prepare

- Explain each requested scope with a recording of the actual feature. Current cloud Mail
  implements reading, labels and trash; draft creation and sending are still outstanding.
- Record incremental Mail consent, denied consent preserving Calendar access, reconnect,
  account mismatch rejection and deletion on a dedicated staging test account.
- Document the existing service flow: encrypted Mail refresh grant linked to the Banana
  account and Google identity; fixed-host Gmail requests; native mailbox cache; encrypted
  mutation intent and receipts in the service operation journal.
- State current retention accurately: provider-operation rows remain until account deletion;
  there is no implemented time-based expiry. Do not claim transient processing for these rows.
- Verify account deletion cascades through grants and operation records, and document the
  separate native cache lifecycle and attachment handling.
- Review the published privacy policy against the final implemented data flow and Google's
  Limited Use requirements before applying. Include the verified domain, homepage, policy,
  scope justification and demonstration in the submission package.
- Complete the applicable Google assessment and restricted-scope review before broader release.

No verification request has been submitted by this work, and no new production Gmail scope
has been enabled. Staging testing and Calendar releases can continue independently.
