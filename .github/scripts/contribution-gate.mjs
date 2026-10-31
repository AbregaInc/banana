// Contribution gate: a pull request stays open only when it closes an approved issue
// that is assigned to its author. Maintainers bypass. Runs on pull_request_target with
// the base repository checked out; it never executes code from the pull request.
//
//   node .github/scripts/contribution-gate.mjs            (in Actions)
//   node --test .github/scripts/contribution-gate.test.mjs  (tests)

export const APPROVED_LABEL = "approved";

const CLOSING = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+(?:(?<owner>[\w.-]+)\/(?<repo>[\w.-]+))?#(?<number>\d+)/gi;
const ISSUE_URL = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+https:\/\/github\.com\/(?<owner>[\w.-]+)\/(?<repo>[\w.-]+)\/issues\/(?<number>\d+)/gi;

/** Issue numbers a body says it closes, for this repository only. */
export function linkedIssueNumbers(body, { owner, repo }) {
  const found = new Set();
  for (const re of [CLOSING, ISSUE_URL]) {
    for (const m of (body ?? "").matchAll(re)) {
      const g = m.groups;
      const sameRepo = !g.owner || (g.owner.toLowerCase() === owner.toLowerCase() && g.repo.toLowerCase() === repo.toLowerCase());
      if (sameRepo) found.add(Number(g.number));
    }
  }
  return [...found].sort((a, b) => a - b);
}

/**
 * The decision. `issues` are the linked issues as fetched: { number, state, labels: [names], assignees: [logins] }.
 * Returns { allowed, reason, code }.
 */
export function decide({ author, maintainers = [], linked = [], issues = [] }) {
  const who = author.toLowerCase();
  if (maintainers.map((m) => m.toLowerCase()).includes(who)) {
    return { allowed: true, code: "maintainer", reason: `@${author} is a maintainer.` };
  }
  if (linked.length === 0) {
    return { allowed: false, code: "no-issue", reason: "The pull request does not close an issue in this repository." };
  }
  const approved = issues.filter((i) => i.labels.map((l) => l.toLowerCase()).includes(APPROVED_LABEL));
  if (approved.length === 0) {
    return { allowed: false, code: "not-approved", reason: `None of the linked issues (${linked.map((n) => `#${n}`).join(", ")}) carries the \`${APPROVED_LABEL}\` label.` };
  }
  const open = approved.filter((i) => i.state === "open");
  if (open.length === 0) {
    return { allowed: false, code: "closed", reason: `The approved issue is closed (${approved.map((i) => `#${i.number}`).join(", ")}).` };
  }
  const mine = open.filter((i) => i.assignees.map((a) => a.toLowerCase()).includes(who));
  if (mine.length === 0) {
    return { allowed: false, code: "not-assigned", reason: `Approved issue ${open.map((i) => `#${i.number}`).join(", ")} is not assigned to @${author}.` };
  }
  return { allowed: true, code: "approved", reason: `Closes approved issue ${mine.map((i) => `#${i.number}`).join(", ")} assigned to @${author}.` };
}

export function closingComment(decision) {
  return [
    `Thanks for the pull request. It is being closed automatically: ${decision.reason}`,
    "",
    "Banana accepts pull requests only for issues a maintainer has approved. Open an issue first",
    "(a bug report or a change proposal). Once it carries the `approved` label and is assigned to you,",
    "reopen this pull request or open a new one whose description says `Closes #<issue>`.",
    "The contribution process is in CONTRIBUTING.md.",
  ].join("\n");
}

// ---- GitHub runner -------------------------------------------------------------------

async function api(path, { method = "GET", body } = {}) {
  const res = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}

async function main() {
  const { readFile } = await import("node:fs/promises");
  const event = JSON.parse(await readFile(process.env.GITHUB_EVENT_PATH, "utf8"));
  const pr = event.pull_request;
  const [owner, repo] = process.env.GITHUB_REPOSITORY.split("/");
  const maintainers = (process.env.MAINTAINERS ?? "").split(/[\s,]+/).filter(Boolean);
  const author = pr.user.login;
  const linked = linkedIssueNumbers(pr.body, { owner, repo });
  const issues = [];
  for (const number of linked) {
    try {
      const i = await api(`/repos/${owner}/${repo}/issues/${number}`);
      if (i.pull_request) continue; // a linked pull request is not an issue
      issues.push({ number, state: i.state, labels: i.labels.map((l) => l.name), assignees: i.assignees.map((a) => a.login) });
    } catch (e) {
      console.log(`issue #${number}: ${e.message}`);
    }
  }
  const decision = decide({ author, maintainers, linked, issues });
  console.log(`${decision.allowed ? "ALLOW" : "CLOSE"} (${decision.code}): ${decision.reason}`);
  if (decision.allowed) return;
  const prPath = `/repos/${owner}/${repo}/pulls/${pr.number}`;
  await api(`/repos/${owner}/${repo}/issues/${pr.number}/comments`, { method: "POST", body: { body: closingComment(decision) } });
  await api(prPath, { method: "PATCH", body: { state: "closed" } });
  process.exitCode = 1; // the check fails too, so a ruleset can require it
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
