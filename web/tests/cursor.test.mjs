import { test } from "node:test";
import assert from "node:assert/strict";
import { ReadCursor, startCursor, decodeSharedCursor, sharedCursorPayload } from "../js/core/cursor.js";

const now = 1791000000000;

test("out-of-order reads never pass an unread message", () => {
  const c = new ReadCursor(10);
  c.delivered("a", 100);
  c.delivered("b", 200);
  c.delivered("poke", 300);
  assert.equal(c.markRead("poke", 300, now), 99, "a still unread");
  assert.equal(c.pending, 2);
  assert.equal(c.markRead("b", 200, now), 99);
  assert.equal(c.markRead("a", 100, now), 300);
  assert.equal(c.pending, 0);
});

test("never moves back; clamps far-future ts", () => {
  const c = new ReadCursor(5000);
  c.delivered("old", 100);
  assert.equal(c.markRead("old", 100, now), 5000);
  assert.equal(c.markRead("far", now * 10, now), now + 86400000);
  assert.equal(c.absorb(1), now + 86400000);
  assert.equal(new ReadCursor(0).absorb(42), 42);
});

test("start cursor = max(local, shared); poisoned → now", () => {
  assert.equal(startCursor(100, 200, now), 200);
  assert.equal(startCursor(300, null, now), 300);
  assert.equal(startCursor(undefined, undefined, now), 0);
  assert.equal(startCursor(now + 86400000, 0, now), now + 86400000);
  assert.equal(startCursor(now + 86400001, 0, now), now);
});

test("shared cursor value", () => {
  assert.equal(decodeSharedCursor({ ts: 5, device: "web-a", at: 9 }), 5);
  assert.equal(decodeSharedCursor(null), null);
  assert.equal(decodeSharedCursor({ ts: "5" }), null);
  assert.deepEqual(sharedCursorPayload(5, "web-a", 9), { ts: 5, device: "web-a", at: 9 });
});
