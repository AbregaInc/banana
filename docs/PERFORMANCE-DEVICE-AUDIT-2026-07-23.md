# Spare-phone performance audit — 2026-07-23

This audit was derived from the shipping source and controlled runs on an iPhone 14 Pro running
iOS 26.5.2. Existing performance documents were not treated as evidence.

All runs were silent, tethered over USB, and explicitly read-only. Tethering makes CPU, wakeup,
syscall, context-switch, timing, and footprint comparisons useful, but it does **not** produce a
valid battery-drain percentage. No playback scenario, alarm, notification, calendar write,
reminder write, or audio-session activation was used.

## Kept changes

### Stop iPhone peer-cache advertising in background

Raw-code inspection found that any non-empty podcast download index started a
`MCNearbyServiceAdvertiser` two seconds after launch and never stopped it. The same-binary A/B
isolated that advertiser:

| 60-second run | Peer on | Peer off | Change |
|---|---:|---:|---:|
| Interrupt wakeups | 2,087 | 23 | -98.9% |
| CPU seconds | 0.126 | 0.077 | -38.6% |
| Syscalls | 3,898 | 1,802 | -53.8% |
| Context switches | 2,792 | 667 | -76.1% |

The iPhone now starts peer serving only while Banana has an active foreground scene and stops
advertising on background. A resource transfer that already started is not disconnected. The Mac
remains the preferred always-available cache source. A background URLSession cold launch defaults
peer serving closed, so it cannot briefly re-enable Bonjour before any scene appears.

Evidence:

- Peer on: `PerformanceRuns/2026-07-23-spare/F72FE681-0CBA-4340-B7E4-7CAE8CA284F1/run/result.json`
- Peer off: `PerformanceRuns/2026-07-23-spare/8FD9C52A-A481-4D08-A4FD-FBCD529494A1/run/result.json`

### Decode podcast art to its actual display class

The old cache kept one original file per URL on disk, which was good, but decoded every image to
1,000 px in memory. A 34–58 pt list row therefore paid almost the same CPU and decoded-memory cost
as the 280 pt Now Playing screen. A deterministic 60-image device comparison measured:

| Decode run | 1,000 px | 256 px list bucket | Change |
|---|---:|---:|---:|
| Wall time | 1,146 ms | 321 ms | -72.0% |
| CPU seconds | 0.967 | 0.202 | -79.2% |
| Decoded RGBA bytes | 240 MB | 15.7 MB | -93.4% |
| Maximum process footprint | 24.4 MB | 18.3 MB | -6.0 MB |

Disk behavior remains one original per URL. Memory uses bounded 128/256/512/1,000 px variants, all
charged to the existing 40 MB `NSCache` limit. Concurrent requests for two sizes share one
URL-level original-byte/network task, so this does not duplicate downloads.

Evidence:

- 1,000 px control: `PerformanceRuns/2026-07-23-spare/91FAB85D-11A5-4B1D-88B9-0744AE5F7989/run/result.json`
- 256 px candidate: `PerformanceRuns/2026-07-23-spare/6F7BBC19-9E87-428B-BE3E-D912043D3E18/run/result.json`

## Rejected change

Combining the separate Today/Tomorrow EventKit reads into one wider predicate looked cheaper in
source but was slower on the device. With the same 65 resulting occurrences, the current version
completed in 135 ms; the combined version took 157–161 ms. The candidate was reverted.

Evidence:

- Current implementation: `PerformanceRuns/2026-07-23-spare/6D06C744-6B16-4CDE-BDAA-4C38F19BCDCE/run/result.json`
- Rejected candidate: `PerformanceRuns/2026-07-23-spare/0A11BD1F-030A-440C-8C7B-FF63F3901FDF/run/result.json`
- Rejected candidate repeat: `PerformanceRuns/2026-07-23-spare/E7FA020E-508D-4899-8A7F-D4F9C6574695/run/result.json`

## Deterministic regression coverage

`planner.refresh` continues to exercise real EventKit I/O. The spare phone's dataset contained 65 routine
occurrences but zero agenda events/reminders, so a new `planner.dense` scenario covers a fixed
14-day executive-scale materialization without personal data:

- 168 meetings
- 240 source reminders, including recurring reminders
- 952 materialized occurrences
- 414,454 encoded timeline bytes
- 36.2 ms wall / 0.0336 CPU-seconds on the spare phone

Evidence:

- `PerformanceRuns/2026-07-23-spare/AFB53FDE-E1DF-490D-A04C-741203322176/run/result.json`

The harness now also supports explicit tethered variants, persistent DerivedData, a legacy bundle
identity for preserving device data/TCC, explicit peer-on/peer-off A/B arguments, and a global
performance-build invariant that suppresses calendar write-back, alarm arming, and other external
writes even if EventKit queues a normal recompute during the run.

The exact final installed binary passed a 5-second silent idle control with 0.0129 CPU-seconds,
10 interrupt wakeups, 0 timer wakeups, and 13.94 MB end footprint:

- `PerformanceRuns/2026-07-23-spare/AC716EC4-E0B3-41C0-B5DB-ECD3A87217C8/run/result.json`
