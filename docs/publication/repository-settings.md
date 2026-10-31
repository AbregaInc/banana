# Public repository settings

What the contribution process needs on GitHub beyond the files in `.github/`. Apply
when the public repository is created; none of this can live in a file.

## Variables and labels

- Repository variable `MAINTAINERS`: space-separated GitHub logins that bypass the
  contribution gate and the CLA (the owner's GitHub login).
- Label `approved` (the gate reads it), plus `bug` and `proposal` (the issue forms set them).

## Rulesets on `main`

- Restrict deletions and force pushes; require a pull request with one approving review
  from a maintainer; dismiss stale approvals on new commits.
- Required status checks: `Contribution gate / gate` and `CLA / cla`.
- Bypass list: nobody, or the repository admin only.

## Repository features

- Issues on, with blank issues disabled (`.github/ISSUE_TEMPLATE/config.yml`).
- Discussions, Wiki and Projects off unless wanted.
- Secret scanning and push protection on. Dependabot alerts on.
- Actions: allow GitHub's actions and `contributor-assistant/github-action`; set the
  default `GITHUB_TOKEN` to read-only so each workflow declares its own permissions.
- Performance workflows stay `workflow_dispatch` only until the harness is ready.

## When a wave of unsolicited pull requests arrives

Settings › Moderation › Interaction limits: restrict to prior contributors for up to
six months. The gate already closes non-compliant pull requests within seconds.

## How approval works day to day

Read the issue. If the change should happen, add `approved` and assign the issue to the
person who will do it. That is the whole approval step; the gate does the rest.
