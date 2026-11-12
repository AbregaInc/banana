# Readability email evaluation

Readability is an article extractor, a useful comparison for the native email reader.
This probe runs ten unchanged anonymised mail cases and three synthetic messages
through `@mozilla/readability` 0.6.0 with jsdom 26.1.0. Install them outside the tracked
source tree, then choose a new result directory:

```sh
npm install --prefix private/readability-deps --save-exact @mozilla/readability@0.6.0 jsdom@26.1.0
node tools/mail-readability/run.cjs --deps private/readability-deps --out private/readability-run
```

No scripts or external resources are enabled. Each case records its input SHA-256,
returned text, missing safe link destinations and ten extraction timings. DOM creation
is outside the timed region; a fresh DOM is used each time. Parser diagnostics are
retained. Missing links can include intended footer removal: these are review signals,
not an automatic quality verdict. Node timings do not establish device rendering,
accessibility, memory or input performance and cannot certify a UI budget.

The November 12 comparison returned content for all 13 cases but removed safe link
destinations in five, including invitation destinations and a mail address. The short
sign-in, receipt and reply-chain cases kept their links. This does not justify applying
article extraction to every email.

## Rendering policy

- Native semantic content is the default: paragraphs, headings, links, lists, data
  tables and meaningful pictures. Ignore author font/color choices and layout wrappers.
- Apply cleanup conservatively. Hide preview padding and trackers. Fold reply history
  without discarding it. Keep actionable links, amounts, dates and table relationships.
- If a table has data semantics that the bounded native grid cannot represent, use
  sanitized formatted HTML with a native fallback. Never choose HTML just because a
  sender added an inline style or signature image.
- Original stays available. No article score or class-name blacklist may delete
  message content. Keep external images opt-in and active content blocked independently
  of extraction. Readability does not sanitize untrusted output.

Mozilla's implementation is Apache-2.0 licensed and requires a DOM. Banana already uses
SwiftSoup on its preparation worker and native rendering on iOS and macOS. Adding a
JavaScript DOM and article-ranking pass has no demonstrated quality or performance
benefit for this workload, so Readability is a comparison dependency, not an app dependency.

Sources: [Readability API/security/license](https://github.com/mozilla/readability),
[extraction implementation](https://github.com/mozilla/readability/blob/main/Readability.js).
The implementation separates data tables from layout tables and scores content using
text and link density. Those distinctions inform conservative structure handling;
its article selection is unsuitable as an unconditional email transform.
