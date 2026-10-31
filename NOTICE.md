# Third-party code, models and data

Banana's native clients and shared code are under GPL-3.0-only (`LICENSE`). The cloud
service and browser app are under AGPL-3.0-only (`Service/LICENSE`). `LICENSING.md` defines
the scope. Third-party code, models, data and artwork keep their own licences:

## Swift packages

| Package | Licence |
|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache 2.0 |
| [GoogleSignIn-iOS](https://github.com/google/GoogleSignIn-iOS) | Apache 2.0 |
| [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) | Apache 2.0 |
| [GTMAppAuth](https://github.com/google/GTMAppAuth) | Apache 2.0 |
| [gtm-session-fetcher](https://github.com/google/gtm-session-fetcher) | Apache 2.0 |
| [GoogleUtilities](https://github.com/google/GoogleUtilities) | Apache 2.0 |
| [app-check](https://github.com/google/app-check) | Apache 2.0 |
| [interop-ios-for-google-sdks](https://github.com/google/interop-ios-for-google-sdks) | Apache 2.0 |
| [promises](https://github.com/google/promises) | Apache 2.0 |

## Models

| Model | Where | Licence |
|---|---|---|
| [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), NVIDIA | downloaded on first use, through FluidAudio | CC BY 4.0 |
| [voice-gender-classifier](https://huggingface.co/JaesungHuh/voice-gender-classifier), Jaesung Huh | `Banana/Resources/NarratorVoiceModel.mlpackage`, converted to Core ML | MIT |

## Bundled data

| Data | Where | Licence |
|---|---|---|
| [USDA FoodData Central](https://fdc.nal.usda.gov/download-datasets/) | `Foods.sqlite`, `BarcodeProducts.sqlite`, `GenericFoods.json` | public domain |
| [RxNorm](https://www.nlm.nih.gov/research/umls/rxnorm/), NLM, and the [Dietary Supplement Label Database](https://dsld.od.nih.gov), NIH | `TakenVocabulary.json` | public domain |
| [OurAirports](https://ourairports.com/data/) | `Airports.tsv` | public domain |
| [mwgg/Airports](https://github.com/mwgg/Airports) (time zones) | `Airports.tsv` | MIT |

## Services asked while the app runs

| Service | For | Licence of what comes back |
|---|---|---|
| [Open Food Facts](https://openfoodfacts.org) | barcodes and food search | Open Database License; the contents under the Database Contents License |
| [Dietary Supplement Label Database](https://dsld.od.nih.gov), NIH | supplement barcodes | public domain |
| Apple Weather | weather | [data sources](https://developer.apple.com/weatherkit/data-source-attribution/) |

## Synthetic sample covers

The six JPEGs in `Banana/PreviewArtwork/` are original synthetic test artwork under
GPL-3.0-only, not the real covers of the shows named in the debug catalogue. Their
editable SVG sources are in `tools/publication/fixture-artwork/`; regenerate them
with `tools/publication/fixture-artwork.mjs`. The previous third-party cover files
are retained only in the private evidence archive and older private Git history.
Names and metadata referring to shows do not grant rights to their real artwork
or audio. No show artwork or audio is relicensed by this notice.

Test fixtures under `BananaTests` hold a few Open Food Facts records, under the same licence.

The cloud web app includes the LZFSE/LZVN decoder from @chrispeoples/aea 0.1.0 (MIT),
ported from Apple's LZFSE reference implementation (BSD-3-Clause). Licenses, source attribution
and modifications are in Service/public/app/assets/vendor/.

The full licence texts for all eleven resolved Swift packages are bundled in
`Banana/Resources/ThirdPartyLicenses.txt`; their observed revisions are in
`Config/Package.resolved` and `docs/publication/swift-dependencies.json`.

## Website, booking and App Store tooling fonts

IBM Plex Mono, Instrument Serif and Nunito are distributed under SIL Open Font
License 1.1. Their full notices are beside the font files in
`LandingPage/site/assets/fonts/`; the booking fonts have their own copy in
`Service/public/book/fonts/`, and App Store tooling fonts in `tools/app-store/fonts/`.
These font files do not become GPL or AGPL under the source-code path defaults.

## Service dependencies

The locked runtime dependencies Hono, @hono/node-server and @date-fns/tz are MIT
licensed. Full installed-package copyright and licence texts for the current
locked versions are retained in `Service/THIRD_PARTY_NOTICES.md`. The browser
LZFSE decoder's MIT/BSD notices remain in `Service/public/app/assets/vendor/`.
Calendar benchmark packages and the nonshipping Skia experiment also retain
their upstream terms; consult their pinned dependencies and local notices.

The bundled converted voice classifier retains its upstream MIT notice in
`Banana/Resources/NarratorVoiceModel-LICENSE.txt`. Model-card/licence sources and
unchanged artifact hashes are recorded in `docs/publication/voice-model-provenance.json`.
The original weights/conversion revision is not inferred from the current licence source.

The mwgg/Airports MIT copyright and permission notice is also retained in
`Banana/Resources/ThirdPartyLicenses.txt` for the derived airport time-zone/city data.
NVIDIA’s Parakeet model attribution is NVIDIA, parakeet-tdt-0.6b-v3,
https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3, licensed under
https://creativecommons.org/licenses/by/4.0/. FluidAudio supplies the converted
on-device model; the bundled app source does not relicense those model weights.
