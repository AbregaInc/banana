# Continuous podcast browsing

Build 71 replaces Previous/Next episode pages with native continuous scrolling.
Unplayed is the default. All episodes includes listening history. Both modes
completely omit episodes excluded by the show's narrator and voice settings;
changing visibility never marks an episode listened, and removing a filter
restores its matching episodes. Unknown voice classifications keep the existing
policy of remaining visible until a verdict exists.

`PodcastEpisodeQuery` prepares the filter off the main actor and excludes its IDs
in SQLite **before** counting or applying LIMIT/OFFSET. A listened prefix cannot
consume the first hundred results. The query pins an immutable episode snapshot,
so a refresh cannot mix rows from different feed versions. Preparation failures
are surfaced, rather than producing a partial filtered list.

`PodcastEpisodeBrowser` retains at most five decoded pages of 100 episodes. The
feed's existing progress metadata and query exclusion IDs are separate from that
body cache. Visible rows request their page and prefetch the next. Scrolling back
reloads evicted bodies from disk. Distant pending work is cancelled, and stale
query generations cannot publish over newer selections. Feed identity, ordering,
completion, voice verdicts and filter settings invalidate the query.

The view keeps native SwiftUI List reuse with one row per stable query position.
This follows Apple's recommendation to keep ForEach's row count constant per
element, rather than deriving a variable number of rows from listened runs.
UIKit prefetching was also considered; retaining the native List avoids a custom
cross-platform list host for this change. See Apple's
[SwiftUI performance session](https://developer.apple.com/videos/play/wwdc2023/10160/)
and [collection prefetching API](https://developer.apple.com/documentation/uikit/uicollectionviewdatasourceprefetching).

Full-feed bulk-menu calculations now run only after selecting the action, on a
background task. The next-episode prefetch selection also leaves the main actor.
These remove synchronous history work from list/menu construction; a CPU stack
proving which call caused the reported four-second hang was not recovered.

## Validation boundaries

`PodcastEpisodeBrowserTests` checks listened prefixes, both playback directions,
history access, in-memory/disk agreement, narrator and gender exclusions,
unchanged completion state, and cache eviction/reload. Its controlled comparison
selects the same first hundred unplayed episodes from a 10,000-episode feed with
9,000 already listened, using page scanning versus the filtered query. Raw
samples remain in the device-investigation logs. The initial run has noisy
tails, including a 220 ms filtered-query sample; it is not a UI acceptance pass.

`ScaleStressUITests.testPodcastScrollsAcrossPagesWithoutNextButtons` exercises
scrolling beyond the first hundred results without a page action.
The persistent regression gate currently reports an unmeasured reference
environment mismatch. Physical-device frame and input latency remain unmeasured;
correctness tests and off-main queries do not establish 120 Hz responsiveness.

On October 22 the user retested main iPhone build 71 and reported
"Responsive; hidden episodes are gone." Both main and Beta were installed on
the iPhone and iPad. The workout-summary repair had already been confirmed on
the phone in build 70. This is reproduction feedback, not instrumented latency
or frame-budget certification.
