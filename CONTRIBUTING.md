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

## What we're looking for

Bug fixes and performance fixes are the contributions we want most. They make the app
work better without changing what it decides to do. Once the underlying issue is
approved, a PR for one of these needs no further design sign-off: just tests (for bugs)
or the workload/measurement writeup (for performance work, per the UI performance
contract below).

UI and UX changes are different. Design and product decisions are made by maintainers,
in the issue, before any code exists, not worked out in a diff. Don't open a PR with a
visual or interaction change on spec; propose it first and wait for approval. A PR that
changes layout, copy, or behaviour without an approved proposal behind it gets closed,
even if the code itself is fine.

The UX proposals most likely to get approved remove something: a button, a setting, a
screen, a step. A proposal that adds a new option or a new control faces a higher bar
than one that gets the same result with fewer of them.

## Security first

When a change touches data collection, storage, logging, or anything that leaves the
device, default to the more secure option, even if a laxer default would be simpler to
build or slightly smoother for the user. Banana's own feedback reporting is the model:
it's useful because it carries real detail, but every report is scrubbed before it
leaves the device. Hold new contributions to that pattern: collect what you need,
strip what you don't, and don't trade a user's data for convenience you could get
another way.

## Licences

Native-client and shared code is GPL-3.0-only; service code, including the browser app,
is AGPL-3.0-only. [LICENSING.md](LICENSING.md) defines the scope. Do not add code, data
or artwork without preserving its provenance and licence notices.

## Local development

See [README.md](README.md), [Service/README.md](Service/README.md) and the tooling READMEs.
