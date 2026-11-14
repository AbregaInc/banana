# Simulator service-profile comparison

14 November 2026. simslim 0.14.0, iOS 27.0, Xcode 27.2, arm64.
The same optimized Banana binary ran every unchanged persistent component scenario
in stock and slim modes. No app implementation, workload, budget or baseline changed.
The [normalized measurements](comparison.json) retain the outcome without device identifiers.

| Simulator-tree measurement | Stock | Conservative slim |
| --- | ---: | ---: |
| Median reported footprint | 8.22 GiB | 6.48 GiB |
| Median process count | 207 | 176 |
| Completed scenarios | 8 | 8 |
| Absolute component checks | Pass | Pass |
| Detected competing developer jobs | None | None |

The observed footprint reduction is 1.74 GiB (21%). Each mode starts a new boot,
with equal idle time after profile/feature verification and five-second waits
between three snapshots. Both footprints were
still growing during those snapshots. This is one ordered stock→slim pair, not a
steady-state distribution, a compilation benchmark or physical-device UI evidence.
No timing speedup is claimed. The unchanged comparison tolerances found no component
regressions, and correctness checksums matched.

The ordinary stock reference gate **still fails peak RSS in all eight cases**.
Simulator-tree footprint and Banana's own RSS are separate measures; this setup
does not solve or hide the existing app-memory failures. Their verdict is retained
in the normalized JSON. Raw logs, both per-mode cases, status/feature checks and
host reports remain in ignored `private/simslim/` in the testing workspace.

The [workflow and reproduction commands](../../../tools/simulators/README.md)
include an order-reversal option. Review repeated quiet-run evidence before using
these numbers to change a reference. The tool does not auto-update a baseline.

The serial slim workflow passed all 14 phone MailReader/MailSmoke UI cases,
seven workflow failure/repair checks and 16 existing performance-gate tests.
Required-service checks passed on both the phone and iPad simulators; a phone
post-UI verification confirmed the profile still matched. No iPad app UI or
physical-device acceptance is claimed.
