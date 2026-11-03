# Swift MLX in-process vs Locals: 1 November 2026

Question: can Banana Pi's Mac model run in-process through Apple's MLX Swift adapter
(`MLXLanguageModel`, a `FoundationModels.LanguageModel`) instead of the bundled-Python Locals
worker, without losing speed?

Answer: **no. Swift MLX was about 8.5× slower on Banana's workload at the same quality.**

| | Locals (Python, pinned) | Swift MLX via Pi's FM bridge |
|---|---|---|
| Contracts passed | 42/44 | 43/44 |
| Warm median (2nd pass) | **0.77 s** | 6.57 s |
| 1st pass median | 0.74 s | 5.82 s |
| Slowest warm case | 3.6 s (explanation) | 11.6 s (explanation) |
| Ready (load) | 4.9 s | 10.8 s |
| GPU allocation peak | 5.8 GB | 3.6 GB |

Same checkpoint (Qwen3.5-4B-4bit @ 0e7ffd5c, every file checked against `pi-local-model.json`),
same 22 cases × 2 passes, same contract scorer (`benchmark.py`, unchanged). Thinking off on both
(the adapter forces it off when reasoning isn't declared). Both runs were on a shared, memory-tight
Mac (swap ~18 of 19 GB used) and both are marked `cleanPerformanceRun=false`, but paging during
the runs was negligible (Locals 45 page-outs, Swift 8 swap-ins), so the gap is not paging.

Swift MLX was slower on every one of the 22 cases, and the second pass was no faster than the
first: Pi starts a fresh `LanguageModelSession` per turn, so whatever prefix reuse the adapter has
inside a session never applies, and Pi's long instructions + tool schemas are prefilled every turn.
Locals keeps that unchanged prefix cached across requests. That is most of the gap.

Swift side: `swift-mlx-shim/` (an OpenAI-shaped server over a verbatim copy of
`Banana/Pi/AppleFoundationModel.swift` on `MLXLanguageModel`; `launcher.sh` stands in for
`python -m locals.server` so the runner is unchanged). Raw results:
`docs/research/pi-apple-host-results/eval-2026-11-01-qwen35-4b-{swift-mlx-fm,locals}.json`.

Decision: keep Locals as the engine; make it app-managed by bundling it in the app rather than
replacing it.
