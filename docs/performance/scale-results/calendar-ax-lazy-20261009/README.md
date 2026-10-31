# Lazy UIKit accessibility and directional paging — October 9, 2026

Experimental `tile-prefetch-ax-lazy` uses UIKit’s native accessibility container callbacks to materialize same-event elements on demand. Count and ordering remain complete. Requested elements keep identity, activation and current frames; retired elements are inert. The preceding bounded page-cache policy is the matched control. Neither is a production default.

All 12 physical iPhone 14 Pro cases completed with valid evidence and budget failures. The original cold/warm/scroll/eviction/resize phases are unchanged. New forward, reverse and 32 ms rapid page sequences each add 12 samples. Three alternating-order trials per density use the same binary. No other build or performance test ran concurrently. These are synchronous component costs, not input-to-visible latency or compositor frame delivery.

| Density | Policy | Cold | Warm revisit | Scroll | Forward | Return | Rapid forward | Rapid return | Uncached | Recovery | Resize | RSS MiB |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | cache | 33.877 | 2.472 | 1.875 | 59.818 | 4.404 | 26.741 | 16.274 | 61.048 | 33.897 | 20.765 | 43.61 |
| 100 | lazy | 33.079 | 3.347 | 3.858 | 60.888 | 3.710 | 28.389 | 15.586 | 62.351 | 30.223 | 19.714 | 43.03 |
| 300 | cache | 55.804 | 9.714 | 7.329 | 89.465 | 8.673 | 47.681 | 45.058 | 87.718 | 43.489 | 41.314 | 50.19 |
| 300 | lazy | 64.902 | 5.224 | 5.109 | 95.517 | 5.527 | 48.044 | 43.449 | 87.853 | 43.850 | 42.531 | 48.88 |

Values are maxima in milliseconds across all three trials. Rapid/directional misses remain much slower than warm two-page revisits. Lazy object creation alone does not solve tile preparation. Accessibility-client enumeration was **not** forced in this first matrix; a separate paired matrix will charge full visible element enumeration inside each timed phase. Do not infer assistive-technology performance from the first matrix.

Offscreen iPhone Simulator API checks passed: 74,293 eager control, 75,510 page cache, 76,730 lazy checks. Lazy-specific checks verify count without allocation, first-request creation, repeated-request identity, index lookup and invalid/retired references. These are per-element correctness checks, not independent performance trials or VoiceOver navigation.

The report validator rejects incomplete navigation phases, changed requested policies, missing forced-client ID/frame evidence and cache-limit violations. Fourteen Python renderer/device-runner tests passed. No budget or baseline changed.

## Forced accessibility-client comparison

All 12 additional physical cases completed with valid evidence and budget failures. Every timed phase reads all visible accessibility labels, frames, traits and enabled state; the independent oracle confirms the complete ordered set and frames. VoiceOver itself was not running, so focus/navigation remains unmeasured. The same binary and unchanged workload were used. No competing build or performance test ran concurrently.

| Density | Policy | Cold | Revisit | Scroll | Forward | Return | Rapid forward | Rapid return | Uncached | Recovery | Resize | RSS MiB |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | cache | 37.313 | 25.263 | 4.944 | 65.847 | 6.399 | 27.871 | 15.898 | 63.318 | 29.251 | 19.776 | 45.95 |
| 100 | lazy | 33.372 | 6.006 | 4.988 | 70.458 | 6.258 | 27.279 | 15.843 | 63.787 | 32.729 | 20.233 | 45.75 |
| 300 | cache | 56.416 | 9.340 | 10.485 | 89.955 | 11.845 | 45.838 | 42.001 | 89.351 | 41.903 | 39.753 | 51.23 |
| 300 | lazy | 56.331 | 9.578 | 10.129 | 94.113 | 12.142 | 46.361 | 43.494 | 86.802 | 42.046 | 40.102 | 53.12 |

Lazy creation does not demonstrate a consistent timing improvement when all elements are requested. Keep it experimental; do not treat deferred allocation as eliminated work. The most consequential remaining misses are uncached/directional tile preparation, not merely accessibility allocation.
