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
