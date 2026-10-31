import { test } from "node:test";
import assert from "node:assert/strict";
import { linkedIssueNumbers, decide, closingComment } from "./contribution-gate.mjs";

const here = { owner: "AbregaInc", repo: "banana" };

test("closing keywords in a body are found, same repository only", () => {
  const body = "Closes #12\nfixes AbregaInc/banana#7, resolves other/repo#9\nFixed: https://github.com/abregainc/banana/issues/30";
  assert.deepEqual(linkedIssueNumbers(body, here), [7, 12, 30]);
});

test("a plain mention without a closing keyword does not count", () => {
  assert.deepEqual(linkedIssueNumbers("See #12 for context", here), []);
  assert.deepEqual(linkedIssueNumbers(null, here), []);
});

const approvedMine = { number: 12, state: "open", labels: ["bug", "approved"], assignees: ["pat"] };

test("a maintainer bypasses the gate", () => {
  const d = decide({ author: "Noor", maintainers: ["noor"], linked: [], issues: [] });
  assert.equal(d.allowed, true);
  assert.equal(d.code, "maintainer");
});

test("no linked issue closes the pull request", () => {
  const d = decide({ author: "pat", linked: [], issues: [] });
  assert.equal(d.allowed, false);
  assert.equal(d.code, "no-issue");
});

test("a linked issue without the approved label is refused", () => {
  const d = decide({ author: "pat", linked: [12], issues: [{ ...approvedMine, labels: ["bug"] }] });
  assert.equal(d.code, "not-approved");
});

test("an approved but closed issue is refused", () => {
  const d = decide({ author: "pat", linked: [12], issues: [{ ...approvedMine, state: "closed" }] });
  assert.equal(d.code, "closed");
});

test("an approved issue assigned to someone else is refused", () => {
  const d = decide({ author: "pat", linked: [12], issues: [{ ...approvedMine, assignees: ["sam"] }] });
  assert.equal(d.code, "not-assigned");
  assert.match(d.reason, /#12/);
});

test("an open approved issue assigned to the author allows the pull request", () => {
  const d = decide({ author: "Pat", linked: [12, 13], issues: [approvedMine, { number: 13, state: "open", labels: [], assignees: [] }] });
  assert.equal(d.allowed, true);
  assert.equal(d.code, "approved");
});

test("the closing comment names the reason and the process", () => {
  const c = closingComment(decide({ author: "pat", linked: [], issues: [] }));
  assert.match(c, /does not close an issue/);
  assert.match(c, /CONTRIBUTING\.md/);
});
