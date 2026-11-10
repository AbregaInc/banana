# App Privacy answers (App Store Connect › App Privacy)

The answers to click through, one app record for iPhone, iPad, Mac and Watch. They match
`Banana/PrivacyInfo.xcprivacy`; `Service/test/catalog-privacy.test.js` fails when the data
catalog (`Shared/DataCatalog.json`) needs a category the manifest lacks, or when this page
leaves out one the manifest declares. Source cross-check updated 23 October 2026. These answers were saved and read back in the live Connect draft on 23 October 2026;
all 19 categories are configured. With explicit owner approval, they were published on 24 October 2026; Apple displays the publication confirmation. They cover the main binary and its enabled optional modules;
the separate development Beta Gmail preview is excluded from that binary.

## The first questions

- Do you or your third-party partners collect data from this app? **Yes.**
- Tracking (for every type below): **No.** Banana has no ads or ad SDKs and does not combine
  data with third-party data for advertising or send it to data brokers. Approved guest access
  and service providers are described separately in the privacy policy.

## Each data type

"Linked" means kept against the Banana account. Purposes: tick only those listed.

| Category | Type | Collected | Linked | Tracking | Purposes | Why |
|---|---|---|---|---|---|---|
| Contact Info | **Name** | yes | yes | no | App Functionality | Google profile name retained for the connected account and invitation display |
| Contact Info | **Phone Number** | yes | yes | no | App Functionality | host number entered in native Booking settings when guests should call the host |
| Contact Info | **Physical Address** | yes | yes | no | App Functionality | in-person address entered in native Booking settings and synced in the booking type |
| Contact Info | **Email Address** | yes | yes | no | App Functionality | the Google accounts that make the Banana account |
| Health & Fitness | **Health** | yes | yes | no | App Functionality | with the person's yes: what Banana reads from Apple Health, meals, supplements, medication and doses, kept so the iPad and Mac show them |
| Health & Fitness | **Fitness** | yes | yes | no | App Functionality | with the same yes: workouts with their samples, workout plans |
| Location | **Precise Location** | yes | yes | no | App Functionality | workout routes, where an episode was listened to (if turned on), saved places |
| Contacts | **Contacts** | yes | yes | no | App Functionality | guest picks: a name the person typed and the other person's address they chose |
| User Content | **Photos or Videos** | yes | yes | no | App Functionality | meal photos |
| User Content | **Audio Data** | yes | yes | no | App Functionality | voice notes' recordings |
| User Content | **Other User Content** | yes | yes | no | App Functionality | routines, alarms, a day's changes, reminders' timing, podcasts and listening, note text, event alert titles |
| Search History | **Search History** | yes | yes | no | App Functionality | food search picks: the words searched and the food chosen |
| Identifiers | **User ID** | yes | yes | no | App Functionality | the Banana account id |
| Identifiers | **Device ID** | yes | yes | no | App Functionality | a random id per device and its push address |
| Usage Data | **Product Interaction** | yes | yes | no | App Functionality, Analytics | playback progress/listening history synced across devices; optional usage counts per account when signed in |
| Diagnostics | **Crash Data** | yes | **no** | no | Analytics | MetricKit crash reports, no account (DIAGNOSTICS.md) |
| Diagnostics | **Performance Data** | yes | **no** | no | Analytics | MetricKit daily metrics, no account |
| Diagnostics | **Other Diagnostic Data** | yes | yes | no | Analytics | what failed, in the usage counts |
| Other Data | **Other Data Types** | yes | yes | no | App Functionality, Analytics | settings, which modules are on, calendar ids watched; the setup counts |

Not collected by the main app (leave unticked): Other User Contact Info,
Payment Info, Credit Info, Other Financial Info, Sensitive Info, Coarse Location, Emails or Text
Messages, Gameplay Content, Customer Support, Browsing History, Purchase History, Advertising
Data, Other Usage Data.

Notes for the answers:
- **Search History** is ticked because the picks are kept on the service. A search itself goes to
  Open Food Facts or the NIH, or Apple's podcast directory, and is answered there; that alone is
  not collection.
- **Coarse Location** stays unticked: the service gets the time zone, not a place. Weather and
  travel go to Apple, not to us.
- **Health and Fitness are not used for Analytics.** The change stream counts a health change only
  as type and operation, with no account and no day (DATA-PLATFORM.md §9).
- Without a Banana account, or without the Health yes, the data stays on the device. Apple's
  labels describe what the app can collect, so these are ticked regardless.

## What changed from the current answers

The current answers are taken to be the manifest before this change. Check them against what
App Store Connect actually shows before editing.

- **23 October correction:** Name is collected by native Google identity sign-in outside the
  data catalogue. Phone Number and Physical Address are collected by the native booking-type
  fields. All three are linked, App Functionality, no tracking; do not leave them unticked.
- **Added:** Health, Fitness, Precise Location, Contacts, Photos or Videos, Audio Data, Search
  History. All linked, App Functionality, no tracking.
- **Other User Content** now also covers notes, podcasts and listening, and plans kept on the
  service (before: only what the account and event alerts held).
- **Unchanged:** Email Address, User ID, Device ID, Product Interaction, Other Diagnostic Data,
  Other Data Types, Crash Data, Performance Data.
- The privacy policy URL (bananatheapp.com/privacy) carries the 23 October 2026 disclosure for
  account/service sync, approved guest sharing and the separate Beta-only Gmail preview.
- Share usage is on by default from build 110 (8 Nov 2026); Settings turns it off. The answers
  above already declare what it sends (Product Interaction, Other Diagnostic Data and Other Data
  Types for Analytics, linked; Crash and Performance Data, not linked), so the default changes
  no answer. Apple's optional-disclosure exemption never applied: collection is ongoing, not
  a per-submission choice.
- Source checks and the embedded manifest do not update the live App Privacy questionnaire.
  Follow [Apple’s App Privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)
  when reconciling the final answers.

Playback progress and listening history also meet Apple’s Product Interaction definition. The
functional sync purpose is separate from optional analytics and is included in the candidate
manifest. Verify both purposes in the live Connect form.

## Sender images (10 November 2026; Beta Mail only)

Mail, and with it sender images, is compiled out of the App Store binary, so the published answers
do not change. For the Beta and for any later release that carries Mail: the service reads the
owner's Google contacts (addresses and photos) only to show sender pictures, keeps a SHA-256 of each
address and the photo's link (linked to the account, App Functionality, no tracking), and deletes
them with email access, the Google account or the Banana account. That falls under **Contacts**,
already declared. Public pictures (BIMI logos, Gravatar, site icons, profile photos) are fetched by
the service by address hash or domain, not from the device, and are not data about the user.
