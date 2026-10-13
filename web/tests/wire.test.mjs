import { test } from "node:test";
import assert from "node:assert/strict";
import * as W from "../js/core/wire.js";
import { generatePushKey, isValidPushKey, PUSH_KEY_ALPHABET } from "../js/core/pushkey.js";

test("push keys: time-ordered prefix, valid, random tail", () => {
  const a = generatePushKey(1791000000000), b = generatePushKey(1791000000001);
  assert.ok(isValidPushKey(a) && isValidPushKey(b));
  assert.ok(a.slice(0, 8) < b.slice(0, 8));
  assert.notEqual(generatePushKey(5).slice(8), generatePushKey(5).slice(8));
  let i = 0;
  assert.equal(generatePushKey(0, () => i++).slice(8), PUSH_KEY_ALPHABET.slice(0, 12));
  assert.equal(generatePushKey(-5, () => 0), "-".repeat(20));
});

test("send timestamps strictly increase", () => {
  assert.equal(W.nextSendTs(100, 0), 100);
  assert.equal(W.nextSendTs(100, 100), 101);
  assert.equal(W.nextSendTs(100, 150), 151);
});

test("backoff doubles to 30 s and resets only after a 30 s connection", () => {
  let b = 1;
  const seen = [];
  for (let k = 0; k < 7; k++) { seen.push(b); b = W.nextBackoff(b); }
  assert.deepEqual(seen, [1, 2, 4, 8, 16, 30, 30]);
  assert.equal(W.backoffAfter(16, 5), 16);
  assert.equal(W.backoffAfter(16, 30), 1);
});

test("clipUTF16 never splits a grapheme", () => {
  assert.equal(W.clipUTF16("👍🏽x", 3), "");
  assert.equal(W.clipUTF16("👍🏽x", 4), "👍🏽");
  assert.equal(W.clipUTF16("ab", 5), "ab");
});
