# Nonstreaming cancellation responsiveness: 25 October 2026

This is a serving-provider probe, not a Pi/app acceptance claim. All requests are synthetic text, no tools are offered or executed, checkpoints are hash verified, and only the probe-owned backend/client are stopped.

| Configuration | Long baseline (512-token cap), ms | Next reply after client close, ms | Trigger reached? | Backend released? |
|---|---:|---:|---|---|
| Native MLX HTTP frontend | 4629.8 | 115960.0 | True | True |
| Locals frontend / MLX compute | 19396.5 | 2092.8 | True | True |
| Current Qwen4B / Locals custom | 388.0 | Model did not establish a long generation; cancellation probe inconclusive | False | True |

Both completed frontend probes use the same pinned Ministral 3B serving view (`ministral3-3b-serving-manifest.json`), MLX-LM 0.32.2 and Locals 0.2.1. Each raw report retains its checkpoint hashes and exact launch command. Both following replies were manually checked to contain `ready`.

## Protocol and interpretation

A baseline request with a 512-token cap must actually generate at least 400 tokens to establish a long workload. The probe then sends the same workload with a 2,048-token cap, waits until backend processing is observable, closes the client socket, and immediately requests the short word `ready`. The metric includes waiting for the complete following reply, not just headers. A completed probe means the measurement finished; it does not itself mean cancellation is acceptable.

Standalone MLX does not expose Locals active-request statistics, so its trigger is a new generation-progress log marker. Locals uses its active-request list. The original header-based native probe timed out before cancellation was reached because headers were buffered; it is retained with an explicit inconclusive qualification and is not counted as a cancellation failure.

In the corrected native run, the next request took 115,960 ms after the socket was closed. The backend later logged a broken pipe while writing the abandoned response, and only then processed the following request. This is a concrete blocker for using that pinned standalone frontend unchanged with the app's current buffered/nonstreaming transport. It is not a verdict on MLX compute kernels or every possible streaming/server implementation.

The Qwen4B probe is inconclusive: the model answered the long-array request with `[]` (one token), so the workload guard stopped it before any cancellation attempt. This is not a cancellation failure. The actual app uses a different long-form prompt and must be tested independently.

Native MLX development-contract scores alone therefore do not establish app readiness. Use a frontend/transport with verified abort semantics and rerun the real Pi app cancellation, continuation, history and lifecycle gates. Keep Pi's scheduler, journal and capability boundary intact; no new agent loop is introduced by this probe.

The shared host is not a dedicated benchmark machine. These are individual responsiveness observations, not production p95 or a causally isolated hardware comparison. The integer-array workload is not an app task. Raw replies, launch commands, server logs and probe source hashes are retained alongside the reports.

The installed app subsequently passed its own real-model cancellation/next-input regression with current Qwen4B/Locals (3,152 ms cancellation). See `docs/research/pi-apple-host-results/mac-selection-baseline-app.json`. This is separate functional evidence using the app’s long-form prompt, not a conversion of the inconclusive integer-array probe into a pass.
