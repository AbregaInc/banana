# Off-the-shelf local Mail search

The [integrated Mail benchmark](mail-ranked-integration.md) measures the subsequent app implementation, sender and filename behavior, and complete result rows.

**Use fielded Tantivy as the lexical foundation for Mail.** The actual Swift package moved the intended email into the first five for 90 of 125 human-written queries, up from 30 with Banana’s chronological ordering. On Beta it recovered 15 missing targets and displaced five. The corresponding paired gains were 48 percentage points on public mail (95% bootstrap interval 39–58) and 8.3 points on Beta (1.7–15.8). Against the earlier tuned fielded prototype, the Swift policy gained nine and lost seven public targets, and gained two and lost six Beta targets. That comparison supports preserving the prototype’s personal-mail signals. [Anonymous case measurements](scale-results/mail-off-the-shelf.json)

| Retrieval method | Public target in first 5 / 125 | Beta target in first 5 / 120 | Discussion nDCG@5 | Useful purchase and account results / 100 | Beta known-item p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Banana chronological SQL | 30 | 22 | 0.180 | 3 | 91.4 ms |
| Previous fielded prototype | 88 | 36 | 0.492 | 34 | 5.8 ms |
| Swift default BM25, excerpts | 80 | 23 | 0.416 | 32 | 1.5 ms |
| Swift coverage, excerpts | 87 | 32 | 0.488 | 32 | 2.7 ms |
| Swift coverage, all eligible messages | 90 | 32 | 0.502 | 31 | 5.2 ms |
| Swift all messages + recent sender slots | 90 | 34 | 0.502 | 31 | 83.6 ms |
| Swift all messages + MiniLM L2 | 91 | 29 | 0.501 | 37 | 36.1 ms |
| Swift all messages + MiniLM L6 | 94 | 36 | 0.497 | 36 | 385.0 ms |
| Potion vector search | 29 | 7 | 0.264 | 38 | 11.2 ms |
| Previous fielded + MiniLM L2 | 89 | 37 | 0.495 | 36 | 32.2 ms |
| Previous fielded + vectors + MiniLM L6 | 91 | 38 | 0.490 | 46 | 412.0 ms |
| Previous fielded + vectors + L6, blended with original ranks | 88 | 40 | 0.505 | 37 | 412.0 ms |
| Swift excerpt BM25 + vectors + MiniLM L6 | 82 | 24 | 0.461 | 47 | 414.1 ms |

The full Swift index used **62.4 MiB** for 199,184 eligible Beta messages from 142,418 conversations. Its input contained 92,358 nonempty plain-text bodies totaling 162.5 MiB. Indexing the already exported JSONL took 6.30 s and peaked at 232 MiB resident. The warm known-item lookup median was 2.38 ms and p95 was 5.22 ms. The full search process peaked at 58 MiB. A separate 15-query fresh-process sample, with warm OS caches, had median/p95 first lookup of 7.30/133.47 ms after opening. At that sample size p95 is the slowest observation. Keep a reader alive and measure launch separately. The baseline SQL includes row projection, while the Swift path ends at ordered thread IDs. The three Swift trials per query verified identical result order. Model timings sum separately measured serial stages, excluding fusion overhead. All timings come from a shared Mac. No foreground UI or physical-device timing is inferred.

The previous fielded prototype plus MiniLM L2 gained one top-five target each on public and Beta mail. The larger model on full Swift candidates reached 94/125 on the public test, but its Beta p95 was 385 ms. The highest model-judged commerce precision, 47 useful results in 100 slots, came from excerpt BM25 plus vectors and MiniLM L6. It surfaced an answer on 15 of 20 prompts and found only 24/120 Beta known items. Blending the hybrid’s reranked list with the original fielded order reached the highest Beta known-item count, 40/120. The hybrid built from the previous fielded ranker brought commerce precision from 34 to 46 and preserved more known items. The paired increase in estimated commerce precision was 12 points (95% query bootstrap interval 1–23). The judge got 18/20 synthetic controls right, including one false positive and one false negative, and assessed 522 query/thread pairs. For `delta receipt` it found payment evidence in zero of 24 pooled conversations. A matching receipt elsewhere in the mailbox could still exist.

The vector index added 89.7 MiB per Beta mailbox and 124.6 MiB of shared model files. The small and large rerankers required 15.7 and 22.8 MiB of shared weights and tokenizer respectively, plus the runtime. A reranker can operate on lexical candidates without a vector index. The bounded date preference left top-five counts at 90 and 32. Adding recent senders through SQLite recovered two Beta targets but raised p95 to 83.6 ms. For an app pilot, the most valuable next benchmark is a long-lived Swift reader with the existing sender and filename behavior, including update recovery and first visible result on device. The heavyweight semantic path warrants a separate human-judged purchase and travel evaluation before default use.

## What was tested

This replay runs the released Swift package on an Apple M1 Max. Its Rust library supplies tokenization, English stemming, BM25 and the inverted index. The client supplies Banana's field names and thread identity. The semantic alternatives use published model weights. Every method receives only the original typed query. All mailbox processing and judging run locally on already retained data. [Swift binding 0.3.4](https://github.com/botisan-ai/tantivy.swift/tree/0.3.4) · [Tantivy query language](https://docs.rs/tantivy/0.25.0/tantivy/query/struct.QueryParser.html)

The Beta sample has 120 predetermined target conversations. Its cues are generated from sender, subject and snippet across three age bands. The public W3C sample has 25 development and 125 test queries written by people trying to find a particular message, and 59 discussion topics with graded judgments. This public test has been used in prior Banana experiments. A separate set of 20 purchase, travel and account questions searches the Beta mailbox without a target ID. Each has a prewritten definition of a useful answer. A local Qwen judge sees the question, criterion and email excerpt with the method, rank and thread ID hidden. It grades the union of every method's first five. Precision divides the number of relevant results by five even when a search returns fewer. These labels cannot establish mailbox-wide recall. The Beta tasks span one mailbox and are not a log of what people actually typed. [NIST topics and judgments](https://trec.nist.gov/data/t14_enterprise.html) · [evaluation prompts and email extraction](../../tools/search-eval/mail-pretrained.py) · [judge and controls](../../tools/search-eval/mail-semantic-judge.py)

The chronological control replays Banana's header/body SQLite query and merge. The earlier fielded prototype uses Python bindings to Tantivy with coverage, short-query recency, filename and sender handling. The full Swift index receives exactly its five field values from every eligible message, retrieves 200 message hits, and collapses duplicates to 50 conversations. It rewards all words matching and, for short queries, matching together in the subject, sender or snippet. The compact Swift experiment indexes one excerpt per conversation, with the newest message's available body up to 1,800 characters, plus subject, sender and snippet. It tests default BM25 and the same coverage preference. The Swift package returns numeric IDs through UniFFI. The full Swift experiment omits the prototype's recency, sender slots and filename lookup. Two cheap follow-ups reuse the same Swift IDs. One applies a bounded 90-day date preference to short queries. The other reserves up to two places after the first result for the latest matching senders on single-word queries, using Banana’s existing SQLite index. The results compare retrieval policies and index designs as well as bindings.

The vector alternative uses pretrained 512-dimensional Potion embeddings and an int8 USearch graph. The index build encodes up to 192 tokens per excerpt. Hybrid retrieval combines two top-50 lists by reciprocal rank fusion with constant 60. MiniLM L6 reranks 20 candidates. MiniLM L2 reranks eight. Both use official ARM64 quantized ONNX weights, two CPU threads and up to 128 query-plus-document tokens. They read the same excerpts from SQLite. The models run through Python and ONNX Runtime in this benchmark. Timing includes excerpt lookup and tokenization. The LLM is used solely to judge the pooled commerce results. [Potion](https://huggingface.co/minishlab/potion-retrieval-32M) · [USearch](https://github.com/unum-cloud/usearch) · [MiniLM L6](https://huggingface.co/cross-encoder/ms-marco-MiniLM-L6-v2) · [MiniLM L2](https://huggingface.co/cross-encoder/ms-marco-MiniLM-L2-v2) · [MLX judge](https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit)

## Integration

The package's MIT-licensed 0.3.4 release embeds Tantivy 0.25.0. Its XCFramework contains native macOS, iOS device and iOS Simulator slices. Checks included batch insert, commit, replacement, removal and searching an index after reopening in a new process. The constructor acquires a writer with a 100 MB budget even on the query path. Deleting a document commits and reloads before replacement can be inserted. Banana would need a single index owner and recoverable synchronization with SQLite, or an upstream read-only opener and atomic batch replacement. Foreground app latency, physical-device memory, battery and incremental mailbox sync remain unmeasured. [Release and wrapper source](https://github.com/botisan-ai/tantivy.swift/blob/0.3.4/src/lib.rs)

## Reproduce

Prepare the two previous fielded fixtures, including Beta's filename snapshot, using the [existing search replay](search-evaluation.md#reproducing-the-comparisons). The following paths are disposable and private. Set `beta`, `public`, `collection`, `blobs` and `models` to their local paths. Set `work` to the parent containing the `beta`, `public` and `models` directories. Supply the release model files before running offline. These are the repositories and revisions used.

| Local folder | Hugging Face repository and revision | Files |
| --- | --- | --- |
| potion | minishlab/potion-retrieval-32M at 6fc8051fab2a1e0ee76689cf08c853792ac285e7 | config.json, tokenizer.json, model.safetensors |
| reranker | cross-encoder/ms-marco-MiniLM-L6-v2 at 233902d25c440f23af6f7d6e94d2946bac0bee0a | tokenizer.json and onnx/model_qint8_arm64.onnx, both at folder root |
| fast | cross-encoder/ms-marco-MiniLM-L2-v2 at 1b5cd67b15209f24824c50370e0397743aa9b787 | same two files |
| judge | mlx-community/Qwen2.5-3B-Instruct-4bit at 4f83f8f146fdf28b512a06562b671d7af4fab457 | model, config and tokenizer assets |

```sh
uv venv --python 3.11 "$work/env"
py="$work/env/bin/python"
uv pip install --python "$py" tantivy==0.27.0 model2vec==0.10.0 usearch==2.26.6 onnxruntime==1.32.0 mlx-lm==0.32.2 numpy==2.4.6 tokenizers==0.23.3
export HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
study=tools/search-eval/mail-pretrained.py
for op in prepare messages; do
  "$py" "$study" "$op" --fixture "$beta" --blobs "$blobs"
  "$py" "$study" "$op" --fixture "$public" --collection "$collection"
done
tools/agents/xcode-lock.sh swift build -c release --package-path tools/search-eval/tantivy-swift --scratch-path "$work/swift-build"
bin="$work/swift-build/release/Replay"
"$bin" lifecycle "$work/lifecycle"
for f in "$beta" "$public"; do
  "$py" "$study" dense --fixture "$f" --models "$models"
  "$py" "$study" retrieve --fixture "$f" --models "$models"
  /usr/bin/time -l "$bin" build "$f/swift-index" < "$f/documents.jsonl" 2> "$f/swift-build-time"
  /usr/bin/time -l "$bin" search "$f/swift-index" "$f/queries.json" "$f/swift-results.json" 2> "$f/swift-read-time"
  "$bin" coverage "$f/swift-index" "$f/queries.json" "$f/coverage-results.json"
  /usr/bin/time -l "$bin" build-full "$f/full-index" < "$f/messages.jsonl" 2> "$f/full-build-time"
  /usr/bin/time -l "$bin" full "$f/full-index" "$f/queries.json" "$f/full-results.json" 2> "$f/full-read-time"
  "$py" "$study" recent --fixture "$f"
  "$py" "$study" compare --fixture "$f" --models "$models"
done
"$py" tools/search-eval/mail-semantic-judge.py --fixture "$beta" --judge "$models/judge"
"$py" tools/search-eval/mail-pretrained-summary.py --root "$work" --binary "$bin" --out "$work/aggregate.json"
```
