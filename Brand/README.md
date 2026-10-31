# Banana brand masters

As of 27 October 2026, the owner-approved dimensional Default icon is canonical.
`BananaMascot.png` retains the approved opaque raster; `BananaAppIconMaster.png` is its
1024-pixel native/store export. `Legacy/` preserves the previous flat SVG/reference.
`Explorations/` preserves the reference sheet, generation prompt and original candidate.

Run `python3 tools/app-store/brand.py` to export native, website and cloud assets together. Native exports use correct platform masks and a distinct
Beta badge. SVG consumers receive a self-contained raster wrapper, not an invented
vector tracing of the dimensional face. Website/cloud header assets are exported at
192px, avoiding a full-resolution download for a small logo. The website retains its
cream/ink/yellow identity and existing screenshot compositions.
Public booking pages use a generated 48px inline raster for their 16px footer and
favicon. They remain self-contained, without an additional image request.

## Watch red/black and tinted faces

`BananaMonochrome.svg` is a separate transparent feature glyph: eye whites, negative-space
pupils, one raised eyebrow and a simplified rounded smile. The smile is deliberately
simplified for small one-color use. It is rasterized to a 100px template with transparent
background and pupils. Full-color complications use a separate 100px circular RGBA icon.
`BananaLogo` selects the template for accented/vibrant rendering and explicitly requests
SwiftUI template rendering. The entire icon must never be an opaque mask in tinted mode,
which would turn it into a solid disc. Red/black previews are controlled tint simulations;
physical Night Mode verification still requires the owner's Watch to be reachable.

Apple controls the watch-face accent: we preserve alpha/negative space, not a forced
red color. See Apple's [WidgetRenderingMode](https://developer.apple.com/documentation/widgetkit/widgetrenderingmode) and [accented rendering](https://developer.apple.com/documentation/widgetkit/widgetrenderingmode/accented) documentation.

App Store icons update through uploaded binaries; the app-picker/public icon may retain
the prior icon until Apple processes/releases the new version. Public submission remains
on the owner's hold. Historical screenshots must not be repainted as fake new captures.
