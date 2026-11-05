# Draft: request reconsideration of guideline 4.8

Not submitted. Prepared at the owner's request after the 5 November rejection of iOS build 83.
This draft addresses login services only; the audio, location, WeatherKit and HealthKit issues
still need their own evidence.

## Proposed App Review response

Hello App Review,

We would like to request reconsideration of the guideline 4.8 finding under the exception for
apps that act as clients for a specific third-party service and require users to sign in to
that service to access their content.

Banana connects to Google Calendar so users can view and edit their existing Google calendars
in a daily planner. Google authorization provides access to that content: it is used to list
calendars, read events and availability, and save event changes back to Google Calendar.
Sign in with Apple alone would not provide access to a user's Google calendars.

Connecting Google is optional. In onboarding, the Google Calendar step offers “Not now,” which
continues into the app. A person can connect later through Settings → Accounts & calendars.
We will include a physical-device recording showing the skip path and the Calendar connection
and editing workflow.

For clarity, the connected Google identity also identifies the person's Banana Cloud account,
which supports cross-device synchronization and calendar change notifications. We are not
claiming that Google authorization is used only on the device, or that Banana has no backend
account. Our request is that this integrated Calendar-client workflow be considered under the
specific-service client exception.

Could you please reconsider the finding on that basis, or clarify whether the Banana Cloud
account and synchronization functions mean the exception does not apply to this implementation?

Thank you.

## Evidence before submission

- Verify the “Not now” path in the exact submitted build, not only current source. The source
  implementation is in `OnboardingView.calendar`, with accessibility ID `onboarding.notNow`.
- Record real Google Calendar connection and event editing using a dedicated review account.
  Do not show personal calendars or credentials.
- Show that Google authorization requests Calendar access. The production console currently
  lists Calendar event access, calendar-list access and availability; Gmail is not configured.
- Remove or correct the current-source onboarding claim “No Banana server in between.” The
  Cloud account/notification architecture makes that statement unsuitable for this appeal.
- Attach the actual recording before replacing the draft's future-tense evidence statement.

Apple's [guideline 4.8](https://developer.apple.com/app-store/review/guidelines/#login-services)
contains the exception cited above. Optional login and a Google Calendar integration do not,
by themselves, establish that Apple will accept the exception for Banana's broader account.
No authentication architecture has been changed in response to this rejection.
