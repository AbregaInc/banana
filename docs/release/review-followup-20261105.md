# App Review follow-up — 5 November 2026

Verified directly in App Store Connect. Both platform submissions refer to build 83 and are
rejected. This does not describe the newer locally prepared TestFlight archives.

| Platform / issue | Verified request | Work still required |
|---|---|---|
| iOS, login services 4.8 | An equivalent qualifying login option, or explanation of an applicable exception | Decide between adding Sign in with Apple to the existing account system and an appeal. Google is currently both provider access and Banana identity. Do not claim that renaming its button changes that. |
| iOS, background audio 2.5.4 | Physical-device recording showing audible playback after returning to the Home Screen | Exercise real podcast playback and retain the recording; the sample workspace is insufficient evidence. |
| iOS, background location 2.5.4 | Physical-device recording showing the feature requiring continuous background location | Exercise actual workout recording, with consent; do not create a fake workout in the owner's Health data. |
| iOS, WeatherKit 5.2.5 | Visible Apple Weather attribution and legal source link, shown on a physical device | Inspect the forecast UI, repair missing attribution if necessary, record the actual display. |
| iOS, HealthKit 2.5.1 | Clear identification of HealthKit functionality, shown on a physical device | Settings and setup contain Apple Health labels; verify the complete path in the candidate and record it. |
| Mac, entitlement 2.4.5 | Explain the incoming-network entitlement or remove it if unused | Existing owner reply and App Review notes already explain podcast peer transfer. Source contains the matching Multipeer advertiser and encrypted session. Verify the new candidate and resubmit when ready. |

No reply was sent, submission changed, or review requested during this inspection. Recordings
and any reviewer credentials belong in private operational storage. Do not include private
calendar, mail, health, account or device details in public evidence.

The original Google-only identity decision must be revisited in light of the actual rejection.
Apple's [login-services rule](https://developer.apple.com/app-store/review/guidelines/#login-services)
contains a specific-service client exception; its application to Banana's broader account/sync
functionality is not established. An appeal is not an approval.
