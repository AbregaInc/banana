import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { lzfseDecompress } from "../public/app/assets/vendor/lzfse.js";
import { OutBuffer } from "../public/app/assets/vendor/outbuffer.js";

test("the decoder's output stops at the caller's bound, and its buffer starts at the size it was told", () => {
  const packed = readFileSync(new URL("./fixtures/web-health.lzfse", import.meta.url));
  const input = packed.subarray(new TextDecoder().decode(packed.subarray(0, 6)) === "LZFSE1" ? 6 : 0);
  const whole = lzfseDecompress(input, input.length * 4);
  assert.ok(whole.length > 0);
  assert.throws(() => lzfseDecompress(input, 16, whole.length - 1), /exceeds/);
  assert.equal(lzfseDecompress(input, 16, whole.length).length, whole.length);
  assert.equal(new OutBuffer(1024, 4096).buf.length, 1024);
  assert.equal(new OutBuffer(1 << 30, 4096).buf.length, 4096, "never more than the bound up front");
});
