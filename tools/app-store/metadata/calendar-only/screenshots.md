# Calendar-only App Store screenshots

Captured from a Debug simulator build with exactly the App Store app's modules (none:
`tools/app-store/flavours/calendar-only.xcconfig` gives it `BANANA_APP_STORE_MODULES`, and the
generator refuses a build that carries any other set). Sample data only: the store-capture week
and Noor Haddad's booking link. No Apple Watch set: this app has no Watch app. Scenes, captions
and crops are in `tools/app-store/flavours/calendar-only.json`.

| # | iPhone 6.9" | iPad 13" (landscape) | Mac | Headline |
|---|---|---|---|---|
| 1 | Plan, Day | Plan, Week | Plan, 5-day week | Every calendar in one day. / Many calendars. One you. |
| 2 | Plan, Week | Plan, Day with the event beside it | Forecast over the week | Your week at a glance. / Every detail, beside your day. |
| 3 | New event, "Lunch with Sam Friday at 1" | New event over the day | Routines | Add it the way you'd say it. |
| 4 | Routines | Routines | | Make room for your routines. |
| 5 | Forecast, scrolled to Apple Weather's mark | Forecast over the week | | The weather for your plans. |
| 6 | Settings › Booking | | | Let people book you. |

Notes
- The forecast always opens on the week and Apple Weather's mark and legal link
  (`--scroll-bottom`), guideline 5.2.5; `StoreListingTests` holds every set to it.
- The phone's forecast is the standalone `--weather-detail` route: at the 6.3" capture width
  Plan's top row gives the forecast chip up for room. On iPad and Mac it opens from the chip
  (`--open-weather`), as a tap does.
- Booking is not in the iPad set: alone in landscape it is a narrow form on an empty screen.
- Generate: `python3 -u tools/app-store/generate.py --flavour calendar-only --platform iphone
  --ios-udid <phone>` (then `--platform ipad --keep-output --ios-udid <pad>`). Output:
  `AppStore/Generated/calendar-only/`, copied to `LandingPage/assets/screenshots/calendar-only/`.
- The Mac set opens real windows, so it waits for a slot the owner picks:
  `python3 -u tools/app-store/generate.py --flavour calendar-only --platform mac --keep-output`.
