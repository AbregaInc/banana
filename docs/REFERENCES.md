# References — inspiration and data sources

Outside work worth borrowing from, with enough detail to judge it without opening the link.
Licence is recorded because "MIT" on a repo often covers the code and not the media inside it.

## Fitness

### hasaneyldrm/exercises-dataset
<https://github.com/hasaneyldrm/exercises-dataset>

A packaged exercise catalogue: **1,324 exercises** with category, body part, equipment and target
muscles, plus 180×180 thumbnails and animation GIFs, and step-by-step instructions in **10
languages** (en, es, it, tr, ru, zh, hi, pl, ko, fr). Ships `data/exercises.json` with a formal
`data/exercises.schema.json` (JSON Schema draft 2020-12), so it can be validated rather than
trusted. About a quarter of the exercises need no equipment.

*Why it's interesting here:* our Watch workout types are a hand-curated list of ten
(`WatchWorkoutType.all`) chosen for what the Watch can record. This is the other half of the
problem — naming and describing individual movements — which is what a strength session needs and
we currently have nothing for.

**Licence, carefully:** code and data are MIT, but the **media is © Gym visual**, redistributed at
reduced resolution with attribution and requiring a separate licence for commercial use. So the
JSON is usable; the GIFs and thumbnails are not, not in a shipping app, without going to Gym
visual first. Worth taking the schema and the taxonomy and sourcing our own art.

### hasaneyldrm/logpress-public
<https://github.com/hasaneyldrm/logpress-public>

The sanitized public source of LogPress AI, an AI workout-planning and logging app for iOS and
Android. React Native 0.80 + TypeScript, Redux Toolkit, React Navigation 7, Supabase for auth and
persistence, OpenAI for fitness scoring, Adapty for subscriptions, Firebase for analytics,
i18next for localisation. No keys or Firebase config committed — you supply your own. MIT.

*Why it's interesting here:* two things rather than the stack, which is nothing like ours.
First, it's the consumer of the dataset above, so the two together show a working
schema-to-product path. Second, it ships a **demo mode that makes zero network requests** — the
same problem our App Store screenshot pipeline solves with `--ui-audit` fixtures, solved a
different way. Worth reading before we extend our own fixture seeding.

*Not a template:* it's React Native and cloud-backed by default; Banana is native SwiftUI and
on-device first. Borrow the data model and the demo-mode idea, not the architecture.
