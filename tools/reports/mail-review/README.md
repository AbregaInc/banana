# Mail layout review

Run from the Banana checkout.

```sh
python3 tools/reports/mail-review/serve.py
```

Open [the local review](http://127.0.0.1:8767/). Select a newsletter and a preview width. **Jump to change** moves to the section that prompted the report. Choose **Add a note** for general feedback, or **Pin a note** and click a passage to mark it. **Show pin** restores the width and image setting used when the note was written.

The server uses embedded `MailOriginalDocument.page` exports in `private/newsletter-check/`. Pass `--snapshots DIR` to use other reviewed copies named `linked-image-card-formatted.html` and `multi-panel-digest-formatted.html`. Keep recipient information, account and tracking identifiers, live destinations and original images out of shared previews. The anonymized source fixtures are in [mail-cases](../mail-cases/).

The selected renderer uses plain paragraphs, native text links, and simple headings. Parallel headed sections become lists. When a linked layout wraps an entire section, the link goes on a short title where one is available. Neighboring image and text links in one action row are combined when they share a destination. Semantic data tables keep their headers and cell spans.

Sample artwork is optional and local. Preview frames block network requests, scripts, and form submissions. The server listens on IPv4 loopback. For a private reverse proxy such as Tailscale Serve, pass the exact client-facing origin with `--proxy-origin`. Keep the proxy restricted to the tailnet. Notes are saved to `private/mail-review/feedback.json` by case and preview revision. Historical votes and notes are retained. Use `--state PATH` for isolated review sessions.

## Automated preview audit

Run the audit against a directory of sanitized exports. Use a new output directory
under `private/` for real mail.

```sh
python3 tools/reports/mail-review/audit.py \
  --snapshots private/mail-review/real-copy \
  --out private/mail-review/audit-real-copy
```

The audit opens the same renderer at 320, 393 and 480 px with sample artwork off
and on. It compares visible link destinations and semantic table counts with the
sanitized source at each width. It checks page overflow, missing or unlabeled links,
and image consent. Duplicate links and missing numeric tokens are review signals.
It writes counts to `audit.json` and saves email-only captures for failures or
numeric warnings. Use `--screenshots` to capture the full matrix.

For a new failure, keep readable copy and redact private strings without changing
the markup. Keep a minimal reproduction and a control where the rule should leave
the markup alone. Group cases by structure (layout tables, parallel headed cells,
linked artwork, data tables, quoted replies), and reserve unseen template families
for validation. Verify the corresponding invariant in `MailRenderCorpusTests` when
porting a preview rule to `MailHTMLPreparer`. The browser audit covers this review
renderer. The app's native correctness, accessibility and performance gates run
through Banana's existing tests.

## Screen a local mail archive

`screen-archive.py` reads the local `blobs.sqlite` cache in small read-only batches.
It uses Python and `lxml`, with network access disabled in the parser. It reads the
original HTML and the matching revision of the saved native projection. The report
contains aggregate counts, approximate structure groups, up to three opaque
references per group, and controls drawn from unflagged messages. It contains no
message bodies, subjects, address strings, or URLs.

```sh
python3 tools/reports/mail-review/screen-archive.py \
  --database '/path/to/BananaMail/Cache/blobs.sqlite' \
  --out private/mail-review/archive-screen.json
```

Prioritize structural flags with a specific failure hypothesis. Large wrapper
tables and the cached formatted fallback alone are weak signals. Validate selected
examples with the current native preparer and the preview audit before generalizing.
The scanner does not resolve responsive CSS or measure native layout. A saved
projection may have been made by a previous parser version. Keep representative
passing controls as well as examples that fail.

Re-run with one or more `--pick REFERENCE` arguments and a new output directory
under `private/` to stage only those raw inputs for local native corpus work.
Generate sanitized snapshots and review redactions before sharing screenshots.

## Replay selected archive mail with the native preparer

Use the existing standalone Swift harness for a selected private batch and public
controls. It runs the app's current `MailHTMLPreparer` and exports both prepared
JSON and sanitized formatted HTML to a private results directory.

```sh
tools/agents/xcode-lock.sh python3 tools/mail-index-tests/run.py \
  --archive-input private/mail-review/archive-first-batch \
  --archive-input tools/reports/mail-cases \
  --out private/mail-review/archive-replay \
  --scratch-path .build/mail-archive-replay
```

Pass additional `--archive-input` directories for held-out cases with distinct
names. Compare the renderer choice and the ordered content and destinations
before and after a rule change. The `snapshots` directory is valid input for the
browser audit. It contains private message text and should stay local.

To compare saved native replays side by side, run
`python3 tools/reports/mail-review/archive-view.py` and open its loopback URL.
The left pane can also show the sender's plain-text part. Subject and date labels
come from the local cache when it is available. This viewer stays on loopback and
requires no access to the Gmail service.

**Flag issue** records which preview needs attention and an optional note.
**Flagged only** filters the current replay. Local and Tailscale viewers share
`private/mail-review/archive-flags.sqlite` on this Mac. Pass `--flags PATH` to use
an isolated flag database for testing.

The archive viewer groups repeat emails by sender, subject with calendar dates
removed, and the available before/after views. It starts with the newest match
in each group. Expand the group to choose another email. Search can match
individual subjects or dates, and flags stay attached to individual emails.

For follow-up on saved feedback, run the viewer with `--flagged-only`,
`--previous-after` pointing to the replay that received the flags, and `--after`
pointing to the corrected snapshots. The corrected replay only needs to cover
the flagged emails. The default comparison pairs the reported rendering with
its correction and keeps the original flags in place.

## Verify every parser layout change

1. Reproduce the flagged rendering using the real message at the reported width. Keep the
   raw input, parser versions, and screenshots under `private/`. Write down what makes the
   output hard to read in observable terms, such as a flight number wrapping within a cell.
2. Fix the structural rule. Add a sanitized regression test for the failure and a control for
   similar content that already reads correctly. Replay the exact report, previously approved
   cases, and held-out templates that use the same structure. Compare text, links, images,
   reading order, and the native versus formatted choice. Account for each intended difference.
3. Capture both rendered email bodies at matching widths with the command below. Open the
   screenshots and inspect the changed section at every width. Check word and identifier breaks,
   label-to-value grouping, and nearby content. Take additional captures for changed sections
   outside the frame. Overflow measurements support this review and can miss broken text
   within a table. Use the native app’s targeted UI tests when native-only behavior is involved.
4. Update the private review viewer after those checks pass. Keep approved cases available as
   regression controls. Report which new layouts changed, whether content was preserved, and
   where the actual screenshots can be reviewed.

Run against the loopback replay viewer with the reported and corrected snapshots loaded.
`--left before` uses the baseline for a comparison without saved feedback.

```sh
python3 tools/reports/mail-review/capture-replay.py \
  --case CASE_ID --out private/mail-review/CASE_ID-captures \
  --section 'Exact heading in both versions'
```

The defaults are 320, 393, and 586 px. Repeat `--width` to include the reported width
when it differs. Omit `--section` for full-body captures or when a heading changed.
Capture runs in its own headless browser session and leaves the review flags intact.
