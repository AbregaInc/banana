import { test } from "node:test";
import assert from "node:assert/strict";
import { assertSupportedNode } from "../src/node-runtime.js";

test("Node runtime rejects pre-security, unsupported and prerelease versions", () => {
  for (const version of ["22.23.4", "24.18.0", "24.21.9", "24.22.0", "25.0.0", "26.12.1", "24.22.1-rc.1", "invalid"]) {
    assert.throws(() => assertSupportedNode(version), /requires Node.js >=24.22.1 <25/);
  }
  for (const version of ["24.22.1", "24.22.2", "24.23.0"]) {
    assert.doesNotThrow(() => assertSupportedNode(version));
  }
});
