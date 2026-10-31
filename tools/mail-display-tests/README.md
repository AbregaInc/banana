# Mail display preparation probe

Run on an idle Mac, without an Xcode build/test in progress:

```sh
python3 tools/mail-display-tests/run.py --out .build/mail-display/NEW_RUN
```

Compiles the actual `MailContract`, `MailRowDisplay`, `MailScheduleCopy`, toast
value and subject cleaner with Swift optimization. Uses real rows and display
formatting, including same-day, yesterday, weekday, month and previous-year dates.
Reports ten raw samples for 100 and 2,000 rows in cold-working-set, warm-cache and
eviction-return phases. Row construction and explicit eviction are outside the
timed region; this probe isolates display preparation, not total cache lifecycle.
The first sample includes formatter first use; later empty-cache samples are not
fresh-process launches. Locale/timezone are pinned to en_US/UTC for reproducibility.

This supplements the actual-host cache-membership probe. It does not include
UIKit/AppKit snapshot application, scrolling, text rasterization, or physical
input-to-visible latency. It has no acceptance baseline and cannot certify a UI
budget. Preserve slow samples and investigate them; do not present this output
as an integrated performance pass. The runner retains exact source copies and
hashes, compile logs, and raw measurements. Exit 2 means Xcode contention prevented
measurement; use a fresh output path once the host is free.

Potential follow-up, after measuring the current path: compare Foundation's
`Date.FormatStyle`, whose identical instances are cached by Foundation according
to [Apple's FormatStyle documentation](https://developer.apple.com/documentation/foundation/formatstyle).
This may avoid a custom formatter cache. Adoption requires exact localized output
comparisons across locales, calendars, timezones, midnight/year boundaries and
relative dates; the existing template output must not silently change. No such
replacement is implemented by this probe.
