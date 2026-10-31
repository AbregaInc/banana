# Calendar move recovery checks

The Foundation-only journal preserves absolute move intent and the exact resolved
provider target/version before dispatch. The recovery store is connected to occurrence/series moves; provider and UI acceptance are tracked separately.
No network calls or real calendars are involved in these tests.

```sh
mkdir -p .build/calendar-move-check
swiftc -O -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  Banana/Model/CalendarMoveJournal.swift tools/calendar-move-tests/main.swift \
  -o .build/calendar-move-check/tests
.build/calendar-move-check/tests .build/calendar-move-check/result.json
```

Checks enqueue/relaunch/acknowledgement, duplicate IDs, concurrent callers,
corrupt/mismatched record preservation, inaccessible storage, immutable prepared
requests, lost-response reconciliation and remote version conflicts. Temporary
fixtures are removed after the test. All timed write samples are retained; these
are component costs, not UI/input-to-visible latency or crash-at-every-instruction
fault injection. Atomic replacement does not claim power-loss durability.


Recovery-store lifecycle tests inject a provider without accounts/network access:

```sh
swiftc -O -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  Banana/Model/CalendarMoveJournal.swift Banana/Model/CalendarMoveRecoveryStore.swift \
  tools/calendar-move-tests/recovery.swift -o .build/calendar-move-check/recovery
.build/calendar-move-check/recovery .build/calendar-move-check/recovery-result.json
```
