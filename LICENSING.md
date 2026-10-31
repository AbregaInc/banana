# Licensing

Banana uses two source-code licences. The scope below applies to original Banana
material, not to third-party material with its own notices. The SPDX identifiers
mean version 3 only; they do not grant an automatic upgrade to later versions.

| Paths | Licence |
| --- | --- |
| `Banana/`, `BananaMac/`, `BananaWatch/`, `BananaWidget/`, `BananaWatchWidget/` | GPL-3.0-only |
| `Shared/`, native tests, `PerformanceInfrastructure/`, `Mockups/`, `tools/` | GPL-3.0-only |
| `Service/`, including `src/`, `public/`, migrations, tests and service tooling | AGPL-3.0-only |
| Original website code in `LandingPage/`, documentation and other original files without a more specific notice | GPL-3.0-only |
| Original synthetic sample covers in `Banana/PreviewArtwork/` and their SVG sources | GPL-3.0-only |
| Third-party code, fonts, datasets, models and media | Their existing terms; see `NOTICE.md` and local notices |
| Banana name, logos, mascot, app icons and original promotional artwork | Reserved; see `TRADEMARKS.md` |

The complete GPLv3 text is in [LICENSE](LICENSE); the complete AGPLv3 text is in
[Service/LICENSE](Service/LICENSE). Existing third-party copyright notices and
licence texts take precedence over the path defaults above. A third-party file
without an adequate licence record must be reviewed before redistribution; its
presence in the repository does not establish permission.

## Shared code and separate programs

`Shared/` remains GPL-3.0-only when used by a native client. GPLv3 and AGPLv3
section 13 permit combining GPLv3 shared material with the AGPLv3 service; their
terms describe the resulting combination and its network-source obligations.
Calling the service's HTTP API does not by itself relicense a separate client.
Do not copy AGPL-only service implementation into a GPL-only client without
reviewing the resulting combined work and updating its notices.

## Corresponding source

Release source must match the version distributed or deployed. Include the
required shared files, source-generation inputs, migrations, dependency versions,
and build/install scripts. Secrets, signing keys and users' data are not source
and must never be included. Provide example configuration instead.

Public service deployments must offer their remote users a prominent way to
obtain the corresponding source for their deployed version, consistent with the
AGPL. Track deployment revisions and keep the offered source available. A licence
link alone, or a link to an unrelated/latest revision, is not a versioned source
offer. See [publication readiness](docs/publication/readiness.md).

## Official Apple distribution

GPL publication does not by itself resolve App Store distribution terms. No Apple
distribution exception is granted by this document. Before publication, establish
the rights needed for official App Store/TestFlight distribution, including all
contributors' and dependencies' terms, and document any separate permission or
dual-licensing arrangement. An exception can cover only rights its grantors hold.

The proposed scope and the unresolved rights questions are recorded in
[the distribution review](docs/publication/apple-distribution.md). This does not
change an upstream licence or promise that all present assets can be redistributed.
