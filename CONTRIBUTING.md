# Contributing

Banana is developed in the open. Pull requests are accepted only for issues a maintainer
has approved, and only from contributors who have signed the CLA.

## The process

1. **Open an issue.** A bug report or a change proposal, using the issue forms. Use
   sample data; remove account identifiers, health information, event details and
   credentials from logs and screenshots. Security reports follow [SECURITY.md](SECURITY.md).
2. **Wait for approval.** A maintainer who agrees with the change adds the `approved`
   label and assigns the issue to you. Issues without that label are not ready for code.
3. **Open the pull request** with `Closes #<issue>` in its description. A pull request
   that does not close an approved issue assigned to its author is closed automatically.
4. **Sign the CLA** when the bot asks, by posting the comment it names. The agreement is
   [CLA.md](CLA.md); it lets Abrega ship your change in the official App Store builds,
   which the GPL and AGPL alone do not permit for code Abrega does not own.
5. **Review.** Every change needs a maintainer's review before it merges. Write tests for
   changed behaviour. Performance work names the workload and measurement scope, keeps
   failures, and never equates simulator component timings with device frame delivery.

## Licences

Native-client and shared code is GPL-3.0-only; service code, including the browser app,
is AGPL-3.0-only. [LICENSING.md](LICENSING.md) defines the scope. Do not add code, data
or artwork without preserving its provenance and licence notices.

## Local development

See [README.md](README.md), [Service/README.md](Service/README.md) and the tooling READMEs.
