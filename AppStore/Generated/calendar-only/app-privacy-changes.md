# App Privacy: what changes for the calendar-only App Store app

The calendar-only build carries no modules (`BANANA_APP_STORE_MODULES` is empty): no Workouts and
sleep, Food, Notes, Podcasts or Email, no Apple Watch app, no HealthKit, camera, microphone,
photos or speech access, and no trip learning (Always location and Motion). Starting from the published answers in `tools/app-store/app-privacy.md`,
these are the changes to make in App Store Connect › App Privacy. Nothing here has been entered.

## Untick (no longer collected)

| Category | Type | Why it goes |
|---|---|---|
| Health & Fitness | **Health** | No Apple Health reading, meals, supplements, medication or doses. The wake plan still syncs (`core.wakePlan`), but in this build it is worked out from the calendar alone, with no sleep or recovery input. |
| Health & Fitness | **Fitness** | No workouts, samples or workout plans. |
| User Content | **Photos or Videos** | No meal photos. |
| User Content | **Audio Data** | No voice notes. |
| Search History | **Search History** | No food search picks. |

## Keep, with a narrower reason

| Category | Type | Now covers |
|---|---|---|
| Location | **Precise Location** | Saved places' coordinates (Settings › Travel). No workout routes, listening places or learned trips: this build has no "Learn from my trips" and asks for location only while in use. Linked, App Functionality. |
| User Content | **Other User Content** | Routines, alarms, a day's changes, reminders' timing, event alert titles. No podcasts, listening or note text. |
| Usage Data | **Product Interaction** | Optional usage counts, Analytics only: untick **App Functionality**, which was for synced playback progress and listening history. |

## Unchanged

Name, Phone Number, Physical Address (Booking), Email Address, Contacts (guest picks), User ID,
Device ID, Crash Data, Performance Data, Other Diagnostic Data, Other Data Types. Tracking stays
**No** for every type.

## Also in App Store Connect

- Secondary category: Health & Fitness no longer describes this app; Business, or none, does.
- The labels belong to the app record, not a build. When a later version brings a module back,
  tick its types again before that version goes out (`app-privacy.md` has them).

## The build's privacy manifest

The App Store build bundles `Config/Generated/AppStore-PrivacyInfo.xcprivacy`, which
`tools/modules/modules.py generate` derives from `Banana/PrivacyInfo.xcprivacy` with only the data
types its modules collect (`Config/Modules.json`, "privacy"): no Health, Fitness, Photos or
Videos, Audio Data or Search History, and Product Interaction for Analytics only, the same as the
labels above. `tools/local-feature-resources.sh` puts it in the AppStore configuration's bundle
and `tools/check-release.sh` refuses an archive whose manifest declares a left-out module's data.
