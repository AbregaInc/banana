# Calendar renderer article: source and publication notes

Article: `LandingPage/content/posts/building-a-measurable-calendar-renderer.md`.
Published as an engineering account, replacing the product how-to in the blog archive.
The original guide is preserved, unpublished, in `LandingPage/content/guides/`.
Its old generated page is removed, and it is absent from RSS/sitemap. No misleading redirect
from a calendar-sharing how-to to an unrelated engineering article was added.

## Claim provenance

| Article claim | Source checked |
| --- | --- |
| 8.3 ms / direct input p95 <10 ms, max20 / other local max100 targets | `docs/performance/ui-performance-contract.md` |
| Multi-tier workload and redraw probe | `docs/performance/regression-testing.md` |
| Descriptor and deferred content closure; clipping and day namespacing | `Banana/Views/CalendarDayCollectionView.swift` |
| UIKit hosting and viewport rectangle query | `Banana/Views/CalendarDayCollectionView.swift`, Apple UIHostingConfiguration/custom-layout docs linked in article |
| AppKit implementation is separate | `Banana/Views/CalendarMacCollectionView.swift` |
| Paint does not own provider/store/write operations | `Banana/Views/CalendarEventArtwork.swift` |
| Prepared artwork enabled for separate Beta, distinct from viewport adoption | `Banana/Views/CalendarPreparedArtwork.swift` (`enabled`) |
| Week reference/native/native/reference memory table | `docs/performance/scale-results/calendar-native-week-20261010/README.md`, Measured comparison |
| Memory rounding | Original kB values 239290.864 / 198461.912 / 198134.232 / 239503.856 rounded to integer kB; average reduction ~41.1 MB /17.2%, reported approximately41MB/17% |
| No measured scrolling speedup, fixture boundary limitation | Same Week report; not reframed as physical or seven-full-day evidence |
| Day raster count, aggregate work, consumer image bytes | `docs/performance/scale-results/calendar-native-day-20261010/README.md`, Prepared-artwork work reduction |
| Aggregate work is not a stall; individual maxima did not improve | Same Day report; first/warm/eviction and physical gaps retained |
| Event61 anchor outside column; test previously opened another event | Week report, Retained failure and coverage correction |
| iPad59 descriptors all visible; zoom needed to test reuse | Week report, Correctness and remaining acceptance |
| Day/Week native default and rejected-move/relaunch checks | `docs/performance/scale-results/calendar-week-default-20261010/README.md` |
| GitHub performance runs paused | Commit93b66544, disabled workflows and manual-only source triggers; unchanged by this article |

These are historical repository reports, not a fresh benchmark campaign. Raw experimental
build folders may have been cleaned under repository policy; the article does not promise
publicly downloadable raw results, open-source access or independent reproducibility from
this post alone. Published numbers are attributed to the dated experiments, with their
limitations. No baseline, benchmark policy, app rendering code or Apple state changes here.

## Page acceptance

The archive/RSS titles now describe engineering and product development. The technical article
has its own canonical URL, description, organizational byline, publication date, BlogPosting
and breadcrumb data, and HTML content without JavaScript. Benchmark tables keep native table
semantics within focusable horizontal-scroll regions so they remain usable on narrow screens.
The headless check covers375/768/1440 widths and JavaScript-disabled article content; results
and screenshots are in `evidence/`. All previous SEO evidence remains under `docs/seo/evidence/`.

The publishing tests use a self-contained Markdown fixture instead of depending on whichever
article happens to be published. Existing draft/future/unpublish/security/date checks remain.
