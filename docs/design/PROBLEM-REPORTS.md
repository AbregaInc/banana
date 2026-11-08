# Problem reports

Approved 8 Nov 2026. When mail renders wrong, the assistant answers wrong, or a build spikes CPU,
power or memory, what is needed to fix it reaches us on its own or in one tap, and becomes a test
case. The loop:

**report → pull → case → fix → gate**

## 1. Report

### Automatic (Share usage on)

| Detector | Fires when | Signature |
|---|---|---|
| `storm` | a store publishes ≥ 2/s (`PerfWatchdog`) | the source (`occurrences↻`) |
| `cpu` | the process uses ≥ 25% of a core over a sample | the busiest counted view |
| `power` | a minute averages ≥ 30% in front, ≥ 10% behind, or the device runs hot | `cpu front`, `cpu back`, `thermal serious` |
| `memory` | footprint ≥ a quarter of the device's memory (iOS), 4 GB (Mac) | the busiest counted views |
| `hang` | the main thread is stuck ≥ 1.5 s while the app is in front (`HangDetector`) | the first non-system frame |
| `metrickit-*` | MetricKit delivers a crash, hang, CPU or disk diagnostic | MetricKit's signature |

Each carries build, channel, Stable/Beta, device model, OS, the page in front, the detector's
numbers and the last 200 lines of `playback.log`, scrubbed (`ReportScrubber`): values marked with
`PlaybackDiagnostics.personal(_:)` where they are logged (titles, names, words typed), anything
quoted, addresses, link paths, long numbers and tokens. A hang adds the main thread's stack, read
while it is stuck (`MainThreadSampler`, image + offset + UUID for `atos`); a MetricKit report adds
MetricKit's JSON. At most three of a kind a day. They wait in Application Support
`problem-reports/` (30 reports, 40 MB) and go off the main thread on launch, on coming forward and
after each new one, backing off a minute to an hour while offline. Nothing runs while nothing fires,
except the hang detector's half-second ping, and that only while the app is in front.

### Report a Problem

- iPhone and iPad: shake (not while typing, where a shake is Undo).
- "…" › Report a Problem: every page's "…" (`MoreMenu`), the mail reader's, the Mac planner's,
  the assistant's.
- Mac: Help › Report a Problem… and ⌘⇧R.
- 👍 / 👎 under each answer. 👍 is a count. 👎 opens the sheet with that answer.

The sheet: one field, then what goes with it (Screenshot, Log, and the page's own row), Send. What
the page adds:

| Page | Always | With its row on |
|---|---|---|
| Mail reader | the message ids, the preparer version | **Email**: the newest message's HTML and its prepared body. On by default in the Beta only. |
| Assistant | the answer's id, the model, how many tool calls | the prompt, the answer, the conversation up to it, the tool calls and results |
| Plan | the days in view and the ids of what is on them | |

A person's own report goes because they pressed Send, whatever Share usage says. Nothing is sent
with the account's session; mail and answers are stored in our service only and go to no one else.

### The service

`POST /v1/reports` (`Service/src/reports.js`): one report, anonymous, allow-listed (kinds,
detectors, pages, attachment names and types and sizes), whole or refused. The row is
`problem_reports` (migration 0025); the files are R2 objects `reports/<id>/<name>`. The app makes
the id, so a retry is the same report. 5,000 reports or 2 GB a day across everyone; 60 a minute per
address. The 15-minute job deletes reports and their objects after 90 days.

## 2. Pull

```sh
tools/reports/reports.py list            # new reports
tools/reports/reports.py pull            # into private/reports/<id>/ (marks them pulled)
tools/reports/reports.py spikes          # automatic reports grouped by detector and signature
```

`--env production` reads the App Store service. Everything pulled stays under `private/`, which is
ignored; the pre-push guard refuses a tracked file there.

## 3. Case

- **Mail:** `reports.py mail-case <id> [name]` makes `private/mail-render-corpus/<name>/` with
  `input.html`, what the reader drew then, the screenshot and an `expect.json` to fill in: text that
  must show (`contains`), must not (`absent`), `blocksAtMost`. When the message can be anonymised,
  `reports.py anonymise <name> <public-name>` writes `tools/reports/mail-cases/<public-name>/`:
  markup and styles kept, every word replaced by a stable stand-in, links and addresses by
  `plan.example`, then checked with `tools/private-text-check.sh`. Read it before committing.
- **Assistant:** `reports.py ai-case <id>` makes `private/ai-evals/<id>.json`: prompt, history,
  the reported answer and tool calls, and an `expected` to fill in (tool, arguments, text).
- **Spikes:** `reports.py spikes` names the signature; the pulled log and stack say where.

## 4. Fix, 5. Gate

`MailRenderCorpusTests` (BananaModelTests) runs every public case and, where `private/` has one,
every private case through `MailHTMLPreparer`, and writes what each drew to
`.build/mail-render-out/`. A fixed case stays in the corpus. AI cases join the eval run
(`tools/pi-evaluation`); spike fixes are checked against the next day's `spikes`.
