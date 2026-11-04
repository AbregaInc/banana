# Google Meet creation checks

The shared event editor offers **Add Google Meet** for writable Google calendars whose
`conferenceProperties.allowedConferenceSolutionTypes` includes `hangoutsMeet`.
The selected request survives the durable event outbox. Event insertion uses a stable
client event ID and receipt; retries recover that event before checking its conference.
Only a confirmed conference failure starts a new conference request on the same event.
Pending creation is polled six times, then remains visibly retryable.

Run the Foundation-only asynchronous state checks without a simulator:

```sh
xcrun swiftc -parse-as-library Banana/Model/GoogleMeetCreation.swift \
  tools/google-meet-tests/main.swift -o /tmp/banana-meet-checks
/tmp/banana-meet-checks
```

`BananaTests/GoogleMeetCreationTests` in the `BananaModelTests` scheme (Debug
configuration, required by the bundle’s existing fixture tests) also covers
capability decoding, legacy drafts, durable request identity, conference decoding and
idempotency receipts. Run with `AssistantCalendarIdentityTests`,
`PendingCalendarWriteTests` and `PendingCalendarWriteStoreTests`.

Live-account verification still requires creating an event on a Meet-capable Google
calendar, checking its Join action on iPhone, iPad and Mac, and checking an invitation
with a consenting guest. Unit tests do not establish live Google behavior or device UI
performance.
