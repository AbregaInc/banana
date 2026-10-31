# Localized Notes search bridge

On the tested iOS 26.5 Simulator, Swift's `String.localizedCaseInsensitiveContains`
traps when searching `Café needle` for `needle\0`: the Foundation search returns a
match whose conversion through Swift UTF-16 indices traps. The original repository
reproduced the crash. Calling the native `NSString` Boolean API avoids that range
conversion while keeping localized, case-insensitive matching.

```sh
mkdir -p .build/notes-search
swiftc -O Banana/Model/LiveFilter.swift Banana/Model/VoiceNote.swift Banana/Model/NoteQueryCache.swift \
  tools/notes-search-tests/main.swift -o .build/notes-search/checks
.build/notes-search/checks .build/notes-search/bridge.json
```

The 384 checks include old/new matching parity for non-crashing mixed-text queries,
explicit trailing-NUL hit/miss behavior, the real in-memory query cache, and all four
searchable note fields. Twenty alternating timing samples per API each perform
3,600 warmed comparisons. This is an API microbenchmark, not repository/UI latency.
CI retains its report; it does not set or relax a product performance budget.

The actual disk path is covered by `NoteRepositoryTests`, including
`testTrailingIgnoredSearchCharacterDoesNotCrash`. Run the persistent component suite
and real Notes paging/opening checks on iPhone/iPad for shipping changes. Keep failed
first-use timings: fixing this crash does not automatically resolve the intermittent
Notes search tail measured during the Plan regression scenario.

The retained [first-use investigation](../../docs/performance/scale-results/notes-first-use-20261010/README.md)
separates SQL count, fetch, decoding and matching. Its FTS5 candidate is isolated;
no index/schema/migration change is installed by this correction.
