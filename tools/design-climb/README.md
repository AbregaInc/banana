# Design climb

A hill climb for the Pi workspace's design: photograph every state, let judges from
different model families compare the new build with the last accepted one blind, keep
the change only when they prefer it.

```sh
tools/design-climb/capture.sh r3 both          # 17 states × phone and iPad, ~4 min each
python3 tools/design-climb/sheet.py r3         # contact sheet: check every state by eye first
python3 -I tools/design-climb/judge.py pair r2 r3            # blind A/B against the last accepted run
python3 -I tools/design-climb/judge.py pair r2 r3 --device pad
python3 -I tools/design-climb/judge.py score r3              # scorecard + ranked fixes for the next round
```

Runs land in `design-climb/runs/<label>/` (gitignored): pictures, contact sheets, the
judges' raw replies and their parsed verdicts.

## The loop

1. `score` the last accepted run. Take the fixes the judges agree on; they are ranked
   MUST/SHOULD/COULD and tagged UX, AX or DX.
2. Build them. One round is a coherent batch, not one pixel.
3. `capture`, then look at the contact sheet. A state that shows the wrong screen makes
   every verdict on it worthless.
4. `pair` needs complete ballots from at least two judges and a majority of those requested.
   Missing states invalidate that judge; insufficient coverage exits with status 2 and no win rate.
   `pair` against the last accepted run. Keep the round when the judges prefer it
   (after-win rate well above 0.5 and no MUST-level regression). Otherwise revert the
   parts the regressions name and run again.
5. Commit the accepted round with its tally.

## What the judges see

- `BRIEF.md`: the product, the three readers (UX, AX, DX) and the nine categories.
  It tells them to look for structure, not corner radii.
- `OWNER-CALLS.md`: <redacted>'s standing decisions. Judges may not propose breaking them.
  When a verdict pushes against one, the owner call wins.
- `states.json`: what each picture shows and how the walk reached it.

Pair mode shuffles which side is new per state, so no judge knows. Scores drift between
calls (one judge moved a reference app from 8.5 to 9.6 on the same pictures), so the
decision rests on pairwise preference, not on the 0–10 numbers.

## Judges and the gateway

`judge.py` calls Cloudflare AI Gateway (`default` gateway on the Abrega account) with
the wrangler login, which carries `ai:write`; the gateway holds the provider keys. Each
provider gets its own request shape: Anthropic's Messages body through `/ai/v1/responses`,
OpenAI's Responses body through `/ai/v1/responses`, Google and xAI through
`/ai/v1/chat/completions`. Judges: `opus` (claude-opus-5.5), `sol` (gpt-6.1-sol),
`argon` (gemini-4-argon), `grok` (grok-4.5).

## The walk

`BananaUITests/PiDesignTourUITest.swift`, in the `BananaAgentUITests` target, runs only
when `TEST_RUNNER_DESIGN_SHOTS` names a folder. It uses the fixture model
(`--assistant-test-navigation`) so every run shows the same states with the same words, and
`--design-capture` keeps test-only counters off screen. It fails naming any state it
could not reach. Add a state there and in `states.json` together.
