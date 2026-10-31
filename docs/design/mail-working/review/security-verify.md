# Mail: verification of the revised engine design against the security and privacy audit

Checked 5 Oct 2026, read-only, against `docs/design/MAIL-ENGINE.md` as rewritten (5,516 lines),
`docs/design/MAIL-UX.md` as it stands on disk (3,459 lines, **unchanged** since the audit — see
N-1), and `docs/design/mail-working/review/reuse.md`. Line numbers are the revised engine's
unless marked UX.

**Summary of verdicts:** 13 CLOSED · 2 PARTLY · 0 NOT CLOSED · 1 DECLINED (accepted with a
minimum). New findings: 1 MAJOR, 10 MINOR. Safe to start P20a, P20b and P26: **yes**, with two
lines added to P20a's package text first (N-6) and the UX document brought into line before U7
(N-1).

## 1. The blockers and majors

| Id | Verdict | Where it is closed, or what remains |
|---|---|---|
| **P-1** remote pictures | **PARTLY** | Engine: closed. §10.6 l.2877–2910 (ask first; trackers `.refuse` always; `presentation: .warming → .placeholder`; "this sender" is the `Authentication-Results` domain from Gmail's own header, l.2905–2910); §10.2 l.2619 and invariant 30; §5.6 l.1611–1613 fetches `Authentication-Results` at header level; D2 l.5021–5029 states the residual leak; P20b tests l.4715–4717 (zero fetch decisions by default, 58 waiting, 3 removed; `.warming` never fetches; unauthenticated sender never "always"); P23c l.4726. **Remains:** `MAIL-UX.md` on disk still says the opposite — §6.2.5 UX l.1259–1264 "by default they are fetched by the engine when the conversation is opened", D6 UX l.3438 recommends fetch-on-open, the Settings footnote UX l.1789–1790 still claims "Banana never fetches the ones that exist only to track you". §10.6's sentence "the same in MAIL-UX" is not true of the file. See N-1. |
| **P-2** URL pass-through, handler scope, outgoing mail | **CLOSED** | §10.4 l.2726–2739: resolution after decoding and control stripping, `URLComponents` required, relative and scheme-relative removed, `banana-mail` and `banana` removed, `banana-mail:` write-only with a test over every fixture (P20a l.4681); `cid:` only when in `context.inlineParts` "for THIS message only" (l.2671, 2731). §10.5 #12 l.2835–2836 dead base host per load; #17 l.2845–2851 handler scoped to the assigned message's key, inline parts and `remoteSources`, 404 otherwise, `no-store`, `nosniff`, placeholder off-screen. Outgoing: §7.2 l.2059–2062 the builder fails if the bytes contain `banana-mail:`; l.2063–2066 what a quote carries; P16 test l.4665–4666; P23c l.4726 "a resource for another message's key is nil". |
| **P-3** parser, serialisation, limits, differential test | **CLOSED** | §10.3 l.2623–2658: SwiftSoup behind `MailHTMLSource`, output serialised never spliced (l.2647–2650), `MailHTMLLimits` (2 MB before parse, depth 256, 100k elements, 64 attributes, 4 KB values, 32 KB style), crash marking `prep_state`. §10.4: allow-list adopted whole (l.2694–2724), SVG/MathML dropped with content (l.2703), `noscript` unwrapped (l.2707), CSS Syntax 3 tokenizer and property list (l.2741–2760), `<style>` blocks dropped whole in release one. MIME limits P03b l.4690–4696 (depth 20, 1,000 parts). Differential test §10.5 #22 l.2867–2868, P20a l.4679–4683. Two residuals are N-6 (recursion and the depth-255 edge) and N-4 (stale versions). |
| **P-4** native path, one link path, forbidden APIs | **CLOSED** | §10.4 l.2772–2782: `MailText` from the tree; linkifier makes `https?`, `mailto`, `www.` only, shown text equals URL; `NSDataDetector` not used; forbidden tokens (`NSAttributedString(html`, `.documentType`, `AttributedString(markdown`, `NSDataDetector`, `NSWorkspace.shared.open(`, `UIApplication.shared.open(`) grepped over four folders by `MailForbiddenAPITests` (P20a l.4678). §10.7 l.2927–2929: the reader installs `MailLinkRules` as the environment's `openURL`. §10.8 l.2965–2967 cleans direction and invisible controls at store time. §7.1 l.2003–2007: the composer has no HTML editor and no HTML-to-attributed-string conversion. |
| **P-5** link rules | **CLOSED** | §10.7 l.2938–2949: refuse list (schemes, userinfo, IP/loopback/`.local`/link-local/private, > 2,048 bytes); warn by dot-boundary suffix comparison, `xn--` from `URLComponents.encodedHost`, always for picture links; `mailto:` → To and Subject only; `tel:` not a link. P20b tests l.4713–4715 cover my table. The suffix rule is sound for "does what it says" (`paypal.com.evil.example` is neither equal to, a subdomain of, nor a parent of `paypal.com`). One mechanical gap is N-7 (how the web view supplies `shownText`). |
| **P-6** unsubscribe | **CLOSED** | §10.9 l.2984–2992: one-click only with `List-Unsubscribe-Post`, `https`, `List-Id`, host equal to or under the authenticated domain; confirmation naming the host, never from a notification, a multi-selection or a bare key; own ephemeral session, redirects refused, body fixed, "Asked *host*" wording. §22.1 row 35 l.5220: `unsubscribe` only for a confirmed one-click offer. Four fixtures in P20b l.4717. Built later (D20). |
| **P-7** `banana://` | **CLOSED** | §13.9 l.3959–3962: not registered in the first release; when it is, navigate only, cached only, connected account only, never fetch/compose/act, asks when it arrives from outside. §3.3 item 4 l.333–335: `.onOpenURL` dispatches by scheme, everything but the Google scheme ignored. |
| **P-8** attachments | **CLOSED**; the partial decline is accepted (§3 below) | §11.2 l.3048–3065: sniffed type decides extension, icon and preview (`.bin` on mismatch); `MailFileName.safe` (§10.8 l.2971–2973); per-file quarantine with a read-back test (P21a l.4738); Quick Look only, enforced by the same grep; `.noindex` directories (§4.1 l.475–476); pictures served only when they sniff as raster (l.3062); executable forwards ask once. `attachment` rows carry `declared_mime` and `sniffed_mime` (§4.7 l.1000). Image bombs and decompressed-byte counting §10.6 l.2915–2917. |
| **P-9** credential blast radius, Disconnect, password coupling | **CLOSED** | §3.2 option C recommended (l.199–229, table l.209–218); `MailCredentialStore` is a separate, non-synchronizable item, `AfterFirstUnlockThisDeviceOnly` (l.294–298); the engine never sees a refresh token (l.236–237); `googleConsent` stores nothing in the calendar and signs the SDK out locally (l.318–328, 342); §3.6 l.437–444 says what Disconnect does not revoke, with the button to Google's page; D15 l.5077–5083, D16 l.5085–5090, R16 l.4947 and probe W6. Mail's minter uses its own ephemeral session (l.299–301); the Gmail session sets TLS 1.2 and refuses redirects (l.1288–1292). Residual: the privacy marker set omits tokens — N-9. |
| **P-10** ATS off; TLS floor; redirects | **PARTLY**; the decline is accepted | Closed for mail's own sessions: §5.1 l.1288–1295 (ephemeral, TLS 1.2 floor, every redirect refused, `https://gmail.googleapis.com/` asserted by a test), §10.6 l.2912–2917 (loader: `https` only, TLS 1.2, three redirects each `https` and not loopback/link-local/private), §10.9 (POST: redirects refused), §10.6 l.2919–2920 states no pinning and the installed-root risk. **Remains:** the loader's redirect rules have no test in any package: P21a's list (l.4735–4738) has none, P20b's (l.4713–4719) has none; the only redirect test is `GmailHTTP`'s (l.4863). `MailRemoteImageLoader` lives in `A/` (l.4732) outside the pure folder — it needs a fake `send` closure like `GmailHTTP`'s so that `302 → http://`, `302 → https://10.0.0.1/`, a fourth hop, and a gzip body past 10 MB are each refused in a unit test. Also N-8 (the undefined "generic" User-Agent). |
| **P-11** the Mac store | **DECLINED — accepted** as D17 | §4.1 l.520–523 states it plainly; D17 l.5092–5096 puts it to him. Minimum still required: the sentence has to reach Settings — D17 says "say it in Settings" but `MAIL-UX.md` §6.8 has no such line (N-1) — and D17 must be decided before order 6 (the first real mailbox on a Mac), because after that the store exists. |
| **P-12** diagnostics | **CLOSED** | §16 l.4050–4079: a typed journal — closed event enum, fields that cannot carry a string, `MailJournalCode` adopted only by closed enums, salted ids with the salt in `intent.sqlite` `meta` (l.1036); l.4101–4103 the UI's folders under the same grep; l.4114–4119 the marker test now includes label names, file names, queries, account addresses and error text, and P24 asserts over the real `playback.log` and `events.ndjson`. Invariant 21 l.168–171 names tokens and Google's error text. §22.1 row 31: events carry ids and closed enums only. |
| **P-13** identity on screen, chips, poisoning, Reply-To, header injection | **CLOSED** | §10.8 l.2963–2970 (`displayName` nil when the name contains `@`, `<`, `>`, a URL or mixed scripts; cleaning at store time; `xn--`; `isKnown`); §13.2 l.3335–3340 `MailPerson.name` nil when the address must be shown; §9.5 l.2574–2578 (names into `correspondent` only from sent mail or authenticated senders; never-written-to entries below, by address, marked `fromTheirMail`; a name colliding with a written-to correspondent at another address not offered); §7.2 l.2054–2058 (typed header values, control characters removed, `isValid`, RFC 2047); l.2080 identity by exact address against verified aliases; P16 tests l.4663–4668 (`header-injection-reply`, reply-all never copies `Bcc`). The `reply-to-elsewhere` fixture is listed (l.4275); the composer's "Replying to *x*, not the address this came from" line is UI copy and is not in `MAIL-UX.md` — part of N-1. |
| **P-14** the model seam | **CLOSED** | §10.11 l.3005–3009: no tools; output is text nothing parses; one conversation, own text only; device only unless a separate setting; never automatic; events, reminders, requests and sends from deterministic rules only. §13.9 l.3963–3964. |
| **P-15** local-network seeding | **CLOSED** | §5.10 l.1705–1713: not built; the floor — not the podcast protocol, which is named "unauthenticated and replayable"; mutual authentication with a key only the synced keychain holds; TLS-PSK or Noise; a fresh challenge per session; only accounts the receiver was granted; nothing from `intent.sqlite`; its own review. D12 l.5067–5068. |
| **P-16** replies, forwards, drafts, device name | **CLOSED** | §7.2 l.2059–2066: no `X-Banana-*` on `.final`; `X-Banana-Send-Owner` is a UUID only; the quote drops trackers and hidden elements and keeps remote pictures as plain `https`; a reply drops inline pictures, a forward re-attaches them. §7.3 l.2094–2099 and D21 l.5120–5124: upload on close, background and send, not on a timer. §7.1 l.2003–2011: no HTML editor; the signature and quote are fragments placed after the body. §11.2 l.3064–3065: executable forwards ask. P16 `quoted-reply-with-trackers` l.4668. |

**The minors, for completeness:** P-17 closed (§4.1 l.513–519; but see N-3 on how the class is
applied). P-18 closed (§12.3 l.3197–3205). P-19 closed (§10.4 CSS list; §10.5 #19). P-20 closed
(§13.8 l.3947–3949; §9.2 l.2522). P-21 closed (§10.5 #11, #14, #15, #17). P-22 closed (§10.10
l.2996–3001: no `.ics` parser, lookup by UID through the calendar, 256 KB, no recurrence).
P-23 closed (§19.2 l.4963–4965; D1 l.5018–5019). P-24 closed (§4.1 l.524–525). P-25 closed
(§10.6 l.2915; §10.5 #10).

## 2. The three non-negotiables

1. **The rewriter is total; the internal scheme serves only the current message's recorded
   parts; outgoing mail is tested to contain none of it.** Met. §10.4 l.2726–2739 (total, with
   `banana-mail` itself removed and write-only); §10.5 #17 l.2845–2851 (scope by assigned
   message, inline parts and `remoteSources`); §7.2 l.2060–2061 and P16 l.4665–4666 (the final
   bytes contain no `banana-mail:`, or the send fails `.internal`); P20a l.4681 (no generated
   URL the run did not make).
2. **A real parser with canonical re-serialisation, the allow-list, hard input limits and a
   differential test.** Met. §10.3 l.2623–2658; §10.4 l.2694–2760; §10.5 #22; P20a l.4679–4683;
   P03b l.4690–4696. Two things the package text must add before P20a is cut (N-6): the walk is
   iterative and tested on a 512 KB-stack thread, and SwiftSoup's own serialisers and `Cleaner`
   are forbidden tokens.
3. **One link path, with the system's HTML-to-attributed-string conversion forbidden by a static
   test.** Met. §10.7 l.2927–2929 (`openURL` environment); §10.4 l.2776–2782 and P20a l.4678
   (`MailForbiddenAPITests`). The channel that carries a tapped link's shown text out of the web
   view is unspecified (N-7); it does not weaken the path, it leaves the mismatch warning
   unreachable from web bodies until specified.

## 3. The three declines, on their merits

- **P-11 (encrypting the Mac store) — accept.** The reasoning is fair: the proposal halves the
  exposure, and the decision is the owner's. Minimum: the statement must appear where he will read
  it (Settings › Mail, `MAIL-UX.md` §6.8 — absent today, N-1), and D17 must be answered before
  order 6 creates the store.
- **P-8 (app-wide `LSFileQuarantineEnabled`) — accept.** Per-file `quarantineProperties` is
  equivalent for files mail writes, and the objection (every podcast and export quarantined) is
  real. Minimum for the alternative to be equivalent: (a) the properties carry
  `kLSQuarantineTypeKey = kLSQuarantineTypeEmailAttachment`, `kLSQuarantineAgentBundleIdentifierKey`
  and `kLSQuarantineOriginURLKey` (a `mailto:` of the sender), so Gatekeeper classifies it as a
  mail attachment; (b) the attribute is applied to the cache copy **at the atomic move**
  (§11.1 l.3034–3035), before any Save, Share or drag can reach the file, not only to copies —
  Finder preserves the xattr on the copy; (c) the read-back test asserts the attribute's flags
  field marks the file unassessed (the first field of `com.apple.quarantine` is not `0000` and
  the type is email-attachment), not merely that the attribute exists; (d) the static grep adds
  `FileManager.default.copyItem`, `moveItem`, `createFile` and `Data.write(to:` outside
  `MailAttachmentStore` and `MailFirstPaint`, so a later export path cannot write an
  unquarantined file.
- **P-10 (narrowing the ATS exception) — accept.** It is the podcast code's change and is listed
  for the owner. Minimum: the loader's redirect and size rules get unit tests (table above), and
  the exception's existence stays in §5.1 and D-text so nobody later reads "https only" as
  platform-enforced.

## 4. New findings introduced by the revision

### N-1 · MAJOR · `MAIL-UX.md` was not revised: it still prescribes fetch-on-open and lacks every copy change the engine now relies on

- **Where:** `MAIL-UX.md` §6.2.5 l.1259–1264; D6 l.3438; §6.8.1 l.1776 ("When opened · Ask
  first") and l.1789–1790 (the footnote); §6.8.2 l.1825–1828 (Disconnect copy says nothing of
  revocation); §7.10 l.2117 (notification shows the snippet); §6.3.3 l.1374 (`MailDraft.reply`
  on the UI side, which §22.1 row 22 says goes); no D17 sentence; no "Replying to *x*" line.
  `MAIL-ENGINE.md` §10.6 l.2877 claims "the same in MAIL-UX"; §22 is titled "What MAIL-UX
  conforms to".
- **Weakness:** The U-packages build from the UX document ("with this file … and nothing else",
  UX l.7–9). U7 would build the pictures line to the old default; U14 would ship the false
  footnote and a Disconnect card that implies revocation; U9 would compute reply addressing in the
  UI. The engine's closures of P-1, P-9, P-11, P-13, P-18 are not closed for the person building
  the screens.
- **Required change:** Either revise `MAIL-UX.md` (the eight places above, with the engine's
  wording), or add to both documents' headers a precedence rule — "where the two differ, the
  engine's §10, §12.3, §13 and the decisions in §20 govern" — together with the explicit list of
  superseded UX lines, and remove "the same in MAIL-UX" from §10.6 until it is. Test: a doc test
  (`MailDesignConsistencyTests`, order 0) greps `MAIL-UX.md` for "fetched by the engine when the
  conversation is opened" and "never fetches the ones" and fails while they are present.

### N-2 · MINOR · Tracker classification is frozen at prepare time; the vendored list has no version, no update path and an unverified licence notice

- **Where:** §10.2 l.2607–2618; §10.4 l.2762–2765; `PrepareContext.trackers` l.2672;
  `MailPicture.isTracker` l.2680; §10.6 l.2896; D19 l.5110–5113; `reuse.md` B-14 l.660–671, 746.
- **Weakness:** `isTracker` is computed once and stored in `prepared`. A later list update changes
  nothing for mail already prepared unless `MailHTMLPreparer.version` is bumped (days on a
  phone, §10.2 l.2616–2618), so a newly listed host is fetched when he taps *Show pictures* on
  an older message. No package creates the extraction script the reuse review asked for, and
  nothing records the source commit; "its licence text ships with it" is a bundle file, while
  BSD-3-Clause requires the notice in the materials of a binary distribution — an acknowledgements
  screen. The reuse review names the repository as `apparition47/MailTrackerBlocker`; the engine
  says "MailTrackerBlocker project, BSD-3" without the owner; the licence has to be read from the
  vendored file at vendoring time, not assumed.
- **Required change:** `RemoteImageRules.decision` also consults the *current* `MailTrackerList`
  by the host of `remoteSources[key]` (both must say "not a tracker"); `prepared` stores
  `tracker_list_version`; `tools/update-tracker-list.sh` writes `MailTrackers.json` with the
  source commit and date in the file; the licence appears in Settings › About › Acknowledgements.
  Test: a picture prepared with list v1, decided with list v2 that lists its host → `.refuse`.

### N-3 · MINOR · Protection classes under GRDB: atomic writes and SQLite's side files do not inherit the class the design names

- **Where:** §4 l.461–462 ("set on the directories and on each file after it is created");
  §4.1 l.513–519; §11.1 l.3034–3035 (temp file, then atomic move); §4.11 first-page.json written
  "atomically"; P02 tests l.4427–4435 (no protection read-back).
- **Weakness:** A file written to the temporary directory and moved keeps the class it was created
  with (the default, C), not the destination directory's `.complete`. `-wal`/`-shm` are created by
  SQLite on first write; they inherit the directory's class only if the attribute was on the
  directory before the first open. Nothing reads any class back.
- **Required change:** `MailDirectories` sets the directory classes before any store opens;
  `MailAttachmentStore` and `MailFirstPaint` set `.complete` on the final file **after** the move;
  P02's test reads `FileProtectionType` back from `index.sqlite-wal`, a stored attachment and
  `first-page.json` on the Simulator.

### N-4 · MINOR · A prepared row with an older `prep_version` may be shown before it is re-prepared

- **Where:** §10.2 l.2615–2618 ("re-prepares lazily: on open, and by the paced queue"); §4.9
  l.1112; P23c l.4725 ("`body` of a prepared message performs no parse").
- **Weakness:** A sanitiser fix (a version bump) must take effect at the moment of opening, or the
  old fragment — the one the fix was for — reaches the web view. "On open" does not say whether
  the stale fragment is shown while the new one is made.
- **Required change:** Rule: a `prepared` row whose `prep_version` is older than the code is
  treated exactly like an unprepared message on open (prepared ahead of the queue behind a
  placeholder) and is never handed to `MailDocument` or the native reader. Test: `body` of a row
  stored at version 1 under code version 2 performs one parse (the counting parser) and returns
  version 2.

### N-5 · MINOR · Picture boxes come from sender-declared sizes with no cap on count or area

- **Where:** §10.4 l.2716–2717 (`width`, `height` up to 10,000 or percentages); §10.5 #2
  l.2805–2806 (every `img` carries its declared box); §13.2 `MailPictureBox` l.3395–3397.
- **Weakness:** 100,000 elements may each be an `img` of 10,000 × 10,000; the frame is clamped to
  50,000 pt but WebKit lays out the whole document, and the native card height estimate uses the
  boxes. A percentage width of 1,000 % is accepted as written.
- **Required change:** A box is emitted only when both dimensions are declared, each ≤ 2,000 px;
  otherwise the image is `auto` with `max-width: 100%`. Percentages are clamped to 100 %. At most
  500 pictures per message; the rest are dropped with `truncated`. Fixture
  `pictures-10000x10000-x1000`: prepared under the time budget, boxes absent, count 500.

### N-6 · MAJOR · SwiftSoup's tree is built before the depth limit applies; a recursive walk over it overflows a secondary thread's stack, and the crash marker turns that into one crash per hostile message

- **Where:** §10.3 l.2641–2658 (`maxDepth = 256`, "beyond depth 256 the rest is flattened";
  the crash marker); P20a l.4682 (`nested-100k-divs` is flattened at 256); `reuse.md` l.303
  (both parsers survive 100,000 nested `div`s — the *parse*); §10.5 #23.
- **Weakness:** The limit is applied by the visitor, after SwiftSoup has built a 100,000-deep
  tree. A recursive visitor or a recursive serialiser at that depth overflows the 512 KB stack
  Swift gives a non-main thread long before 100,000 frames; the prepare queue runs on such a
  thread, including inside the background refresh task. `prep_state` makes it happen once per
  message — which is still a crash of the whole app, in the background, for every new such
  message a sender cares to send. Separately, libxml2 (the differential test's second opinion)
  stops at depth 255 while the sanitiser flattens at 256: the test's parser gives up one level
  before the output's deepest legal node. And the reuse review notes SwiftSoup's own `Cleaner`
  leaves `<`/`>` unescaped in attribute values (l.306): nothing in the design forbids an
  implementer from reaching for `Element.outerHtml()` or `Cleaner` instead of the visitor.
- **Required change (two lines in P20a's package text):**
  1. The walk and the serialiser are iterative (an explicit stack); the visitor refuses to descend
     past `maxDepth` by returning `false` from `open`; `nested-100k-divs` and a
     `nested-100k-inline` (spans, which the adoption agency treats differently) run on a thread
     created with a 512 KB stack in `MailHTMLPreparerTests` and complete. `maxDepth` becomes 200
     so libxml2's 255 is never reached, and the libxml2 source sets `HTML_PARSE_HUGE`.
  2. `MailForbiddenAPITests` adds `.outerHtml(`, `.html()`, `Cleaner(`, `Whitelist`, `Safelist`
     for every mail folder; `MailHTMLSwiftSoup.swift` may call `SwiftSoup.parse` and traverse,
     nothing else.

### N-7 · MINOR · How a tapped link's shown text reaches `MailLinkRules` from the web view is unspecified

- **Where:** §10.5 #10 l.2826–2829 (the only script channel accepts a `Double`), #13 l.2837–2838
  (a link activation is handed to `decide`); §10.7 l.2933.
- **Weakness:** `WKNavigationAction` carries the URL, not the anchor's text or whether it was an
  image. Without that, every web-body link is decided with an empty `shownText`, and the mismatch
  warning — the control that P-5 is about — never fires for designed mail.
- **Required change:** Preparation records `links: [String: MailLinkFacts]` keyed by the rewritten
  `href` (shown text and `isImage`; for a duplicate `href` the entry that would warn wins) in
  `PreparedBody`; the navigation delegate looks the URL up there. P26 test: `link-mismatch` tapped
  in the web view produces the warning sheet.

### N-8 · MINOR · The picture loader's and the unsubscribe POST's `User-Agent` is "generic" and nothing more

- **Where:** §10.6 l.2913; §10.9 l.2989–2991.
- **Weakness:** The default `URLSession` string is `Banana/<build> CFNetwork/<v> Darwin/<v>` — a
  user agent one person on earth sends, which identifies him across every sender's logs more
  surely than a cookie would.
- **Required change:** One constant, equal to Apple Mail's WebKit user agent on that OS, set on
  both sessions and asserted by their tests.

### N-9 · MINOR · The privacy marker set omits tokens, and the token-interpolation grep is absent

- **Where:** §16 l.4114–4116; invariant 21 l.168–171 names tokens; P01b l.4874 tests.
- **Required change:** The fake's refresh and access tokens contain the marker; a static test
  asserts no mail file interpolates `accessToken`, `refreshToken`, `value` of `MailAccessToken`,
  `allHTTPHeaderFields` or a `URLRequest` into a string.

### N-10 · MINOR · The background task prepares bodies whose inline pictures it cannot store

- **Where:** §12.2 l.3160–3163 ("fetch new inbox mail, at most 30 messages, and prepare those");
  §11.1 l.3027 (inline pictures ≤ 2 MB fetched when the body is, on any network); §4.1 l.517–519
  (`Attachments.noindex` is `.complete`, "treated as absent" while locked).
- **Weakness:** Inside a `BGTask` on a locked phone the inline-picture write fails; "absent" says
  what the reader sees, not whether the fetch is retried, and the fetch itself was wasted quota.
- **Required change:** §11.1 gains "never inside a background task"; `cid` parts are fetched when
  the message is on screen (already §10.6 l.2922–2923). Test: the background-task scenario makes
  no attachment request.

### N-11 · MINOR · `inlineParts` lookup by Content-ID is unnormalised

- **Where:** §10.4 l.2671, l.2731.
- **Required change:** Match after stripping `<`/`>`, surrounding whitespace, case-folding the
  `cid:` value, and percent-decoding once; a miss removes the image (already the safe direction).

## 5. The web-view contract, ticked against the revised §10.5

| My item | Revised §10.5 | |
|---|---|---|
| 1 content JavaScript off | #3 | ✓ |
| 2 preferences (no auto windows, no fullscreen, selection on) | #4 | ✓ |
| 3 non-persistent store, unshared | #5 | ✓ |
| 4 scheme handler the only network object | #6 | ✓ |
| 5 rule list JSON; failure means no web view | #7 | ✓ |
| 6 media off | #8 | ✓ |
| 7 app-bound domains left false | — | n/a (implicit) |
| 8 mail's own process pool | #9 | ✓ |
| 9 measuring script isolated, `Double` only | #10 | ✓ |
| 10 no link preview, no gestures, no detectors, not inspectable | #11 | ✓ |
| 11 `loadHTMLString` with a dead base only | #12 | ✓ |
| 12 navigation and response policy, downloads cancelled | #13 | ✓ (`canShowMIMEType` not named; covered by "not `banana-mail:` or `data:`") |
| 13 UI delegate: no windows, silent alerts, replaced context menu | #14 | ✓ |
| 14 drops refused | #15 | ✓ |
| 15 no scrolling, frame clamp | #16 | ✓ |
| 16 handler: sniffed type, `no-store`, `nosniff`, scoped, off-screen placeholder | #17 | ✓ |
| 17 assignment, emptying, destruction | #18 | ✓ (one web view per open designed message, six at most) |
| 18 no Banana control inside the card | #19 | ✓ |
| 19 document head, CSP, viewport, referrer, `dir=auto` | #1 | ✓ |
| 20 document is a value, never edited | §10.5 intro, #1 | ✓ |
| 21 handler log only this message; zero fetches by default | #20 | ✓ |
| 22 canary, meta refresh, form, link tap | #21 | ✓ |
| 23 budget fixtures; differential test | #22, #23 | ✓ |
| — shown text for a tapped link | — | ✗ (N-7) |

## 6. Device-local versus synced credential: a recommendation he can act on

**Choose C — a mail credential per device, not synced** (D15's recommendation). What it costs
him in daily use:

- **Consents.** One Google sheet per account per device, once: with four accounts on three
  devices, twelve sheets over the first days, each about twenty seconds including the "unverified
  app" interstitial (D1). The "Turn on Mail" screen (UX §6.9) already loops the accounts, so a
  device is done in a few minutes. A new or restored device repeats it; a reinstall does not
  (the keychain item survives).
- **A Google password change** signs mail out on each device separately — three re-consents —
  and, as far as can be told before probe W6, leaves the calendar alone. Under A it signs the
  calendar out on every device at once as well.
- **What leaves the device.** Under C the grant that can read and send his mail is on the devices
  where he allowed Mail and nowhere else: not in iCloud Keychain, not in keychain escrow, not on
  a Mac that never ran Mail. Under A it is on every device signed into his Apple ID.
- **Daily behaviour is otherwise identical**: mail, calendar and sync work the same; "Forget Mail
  access on this device" becomes a local, reversible act; Beta already works this way (it never
  shared the item).
- **The one convenience A buys** — allow once, every device has mail — is a few minutes on three
  devices, once. It is not worth copying a Gmail grant into the cloud.

If he prefers A anyway: accept it with D16's copy on the account card, knowing that Disconnect
revokes nothing and that a password change signs the calendar out everywhere; the engine is
unchanged (§3.3 l.358–364).

## 7. Safe to start building?

**Yes** — P20a, P20b and P26 can be built from the revised §10 and §11, provided two lines are
added to P20a's package text before it is cut (N-6: an iterative walk tested on a 512 KB stack
with `maxDepth = 200`, and SwiftSoup's serialisers and `Cleaner` as forbidden tokens), and
`MAIL-UX.md` is brought into line or formally subordinated before U7 begins (N-1). Nothing else
found here needs to change before the HTML-preparation and web-view packages start; the
remaining minors are package-text additions on the path of the packages that own them.
