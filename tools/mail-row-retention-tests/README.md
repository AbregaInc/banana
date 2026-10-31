# Mail row retention regression

Run `python3 tools/mail-row-retention-tests/run.py --out NEW_DIRECTORY` on Mac.
The runner compiles the actual iOS `apply` and Mac `load` methods and cache fields
with minimal adapter types. Eight disjoint 64-row scopes, an empty scope, delayed
and out-of-order completions, reinsertion, duplicate IDs and weak coordinator
lifetime are checked. Calendar-independent Mail retention CI runs this command.

Use `--reference-archive DIRECTORY` with frozen `MailListHost+iOS-before.swift`
and `MailListHost+Mac-before.swift` files for the pre-change control. The original
implementation retains 512 row/display records after the scope sequence and
fails the expected retirement checks. Preserve that failure.

`--measure` additionally retains samples for cold, warm, replacement and
return-after-eviction workloads at 2,000 rows per scope, plus peak and settled
entry counts. It refuses to measure while Xcode is active. Alternate reference/
candidate/candidate/reference on the same host. These are dictionary/cache and
adapter-completion measurements: they exclude real text formatting, UIKit/AppKit
diffing, memory-byte accounting, frame delivery and input-to-visible latency.

Relevant real-app checks are `MailTriageUITest.testTenDonesInARowUndoingTheThird`,
`testDoneInStarredKeepsTheRowAndDoneOnTheOnlyRow`, and
`ScaleStressUITests.testMailScrollAndOpen`. Run the full persistent component
suite too. Keep missing Mac/iPad/physical evidence explicit.
