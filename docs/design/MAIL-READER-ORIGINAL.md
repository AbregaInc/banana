# Mail reader and original layout

The native reader previously drew underlined text without attaching URLs. Safe
HTTP, HTTPS and mailto destinations now use SwiftUI's attributed-link handling.
The original sender HTML remains in the existing blob store; it is not reconstructed
from the snippet or simplified text.

Original opens one WebKit view on demand on iOS, iPadOS and macOS. The existing
pinned SwiftSoup parser/cleaner preserves tables, inline styles and style sheets
while removing active markup. Parsing and blob decompression remain off the main
actor. WebKit is Apple's native cross-platform HTML layout engine; a new custom
HTML renderer or third-party wrapper would add no needed capability here.

The view uses an ephemeral store, disables content JavaScript, and applies a CSP
that blocks scripts, frames, forms and remote resources. Load images explicitly
allows HTTPS images for this presentation only. Stylesheets/fonts remain local;
inline CID attachments are not yet resolved in this view. Safe tapped links open
through the system URL action, including links that requested a new window.

Account and sync details live in an Accounts menu instead of a permanent rollout
notice and horizontally scrolling account strip. Failed deliveries, removal review
and draft notices remain actionable.

A message card becoming visible now requests a missing body at interactive priority.
Local cache reads remain read-only. Each reader requests a visible message once;
explicit Retry loading remains available, and writer notifications replace the
snippet when the prepared body arrives. This does not claim every indexed header
has already been downloaded for offline use or introduce shared cloud body caching.

References: [Apple attributed Text](https://developer.apple.com/documentation/swiftui/text/init(_:)),
[WebKit script policy](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript).
Functional tests and native builds are separate from physical UI/frame acceptance.

## Build 101 validation

Source `73756fff`: nine reader/link tests passed, including visibility before a cache
read completes, one automatic request per missing body, explicit retries and safe
link attributes. Twelve original-layout/body-store/loader checks passed. Original
view UI journeys passed on phone and iPad simulators; both screenshots were inspected.
Evidence: `private/cloud-rollout/mail-reader-101-cache-race`, `mail-original-101`,
`mail-reader-101-evidence`, and the matching phone/pad UI logs. The first reader
harness attempts exposed stale conditional-compilation extraction and a missing
SwiftUI link dependency; those runner issues were fixed and failed logs retained.

Beta 1.0.4 (101) installed and launched successfully on both physical devices, and
their installed versions were queried afterward. Remote physical screenshot capture
remains unavailable. The Mac archive compiled successfully; no visible Mac UI or
physical input/frame acceptance is claimed.

The build-101 component run was superseded by the subsequently reported encoded
snippet bug; its output and interruption reason remain in
`private/cloud-rollout/mail-reader-101-performance/superseded.json`. It is not
a passing gate. The final component run targets the snippet correction too.

Gmail preview entities are decoded once with the pinned SwiftSoup entity decoder
at the bounded index/conversation read boundary, off the UI thread. Stored snippets
remain provider-encoded. This fixes old cached previews without a migration or
re-download, covers search through the shared row decoder, and leaves subjects and
literal HTML-looking text intact.
