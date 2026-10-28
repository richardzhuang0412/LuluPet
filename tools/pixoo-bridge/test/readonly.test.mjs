// The bridge must never write to Firebase (presence / read cursor / devices / anything).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { readOnlyFetch, createReadOnlyFirebase, ReadOnlyViolation } from "../src/readonly.js";
import { MessageFeed } from "../../../web/js/net/firebase.js";
import { BRIDGE, recordingFetch } from "./helpers.mjs";

const URL_ = "http://127.0.0.1:9/pairs/TESTCODE/messages.json";

test("readOnlyFetch refuses every non-GET method before the request leaves", () => {
  const inner = recordingFetch();
  const seen = [];
  const f = readOnlyFetch(inner, (e) => seen.push(e.method));
  for (const method of ["PUT", "PATCH", "POST", "DELETE", "put", "OPTIONS"]) {
    assert.throws(() => f(URL_, { method, body: "{}" }), ReadOnlyViolation);
  }
  assert.throws(() => f(new Request(URL_, { method: "PUT", body: "{}" })), ReadOnlyViolation);
  assert.throws(() => f(URL_, { body: "{}" }), ReadOnlyViolation);          // GET with a body
  assert.equal(inner.calls.length, 0, "nothing reached the network");
  assert.equal(seen.length, 8);
});

test("readOnlyFetch lets GET (explicit or default) through", async () => {
  const inner = recordingFetch();
  const f = readOnlyFetch(inner);
  await f(URL_);
  await f(URL_, { method: "get" });
  await f(URL_, { method: "HEAD" });
  assert.deepEqual(inner.calls.map((c) => c.method), ["GET", "GET", "HEAD"]);
});

test("read-only Firebase: put / patch / del throw, get works, every request is a GET", async () => {
  const inner = recordingFetch(() => new Response(JSON.stringify({ lastSeen: 1 }), { status: 200 }));
  const violations = [];
  const fb = createReadOnlyFirebase({ databaseURL: "http://127.0.0.1:9", pairCode: "TESTCODE", fetch: inner, onViolation: (e) => violations.push(e) });
  assert.throws(() => fb.put("presence/lumei", { lastSeen: 1 }), ReadOnlyViolation);
  assert.throws(() => fb.patch("read/lumei", { ts: 1 }), ReadOnlyViolation);
  assert.throws(() => fb.del("devices/lumei/x"), ReadOnlyViolation);
  assert.ok(Object.isFrozen(fb));
  assert.deepEqual(await fb.get("presence/lulu"), { lastSeen: 1 });
  assert.equal(violations.length, 3);
  assert.deepEqual(inner.calls.map((c) => c.method), ["GET"]);
});

test("the EventSource gets the guarded fetch too", () => {
  let given;
  class FakeES { constructor(url, init) { given = init; this.url = url; } addEventListener() {} close() {} }
  const fb = createReadOnlyFirebase({ databaseURL: "http://127.0.0.1:9", pairCode: "TESTCODE", fetch: recordingFetch(), EventSource: FakeES });
  fb.openEventSource("messages", "orderBy=%22ts%22&startAt=1");
  assert.equal(typeof given.fetch, "function");
  assert.throws(() => given.fetch(URL_, { method: "PUT" }), ReadOnlyViolation);
});

test("MessageFeed in polling mode over the read-only client only ever GETs", async () => {
  const inner = recordingFetch(() => new Response("{}", { status: 200 }));
  class FailingES { constructor() { setTimeout(() => this.onerror?.(), 0); } addEventListener() {} close() {} }
  const fb = createReadOnlyFirebase({ databaseURL: "http://127.0.0.1:9", pairCode: "TESTCODE", fetch: inner, EventSource: FailingES });
  const sched = { now: () => Date.now(), setTimeout: (f, ms) => setTimeout(f, ms), clearTimeout: (h) => clearTimeout(h) };
  const feed = new MessageFeed({ fb, since: () => 5, onBatch: () => {}, sched, isHidden: () => false,
    timing: { backoffMinMs: 5, backoffMaxMs: 10, failedOpensBeforePolling: 1, pollVisibleMs: 10, firstPutTimeoutMs: 1000, idleTimeoutMs: 1000 } });
  feed.start();
  await new Promise((r) => setTimeout(r, 150));
  feed.stop();
  assert.ok(inner.calls.length >= 2, `polled (${inner.calls.length})`);
  assert.ok(inner.calls.every((c) => c.method === "GET" && c.body == null));
  assert.ok(inner.calls.every((c) => c.url.includes("/messages.json?orderBy=%22ts%22&startAt=6")));
});

test("source guard: only src/readonly.js creates a Firebase client; nothing calls put / patch / del", () => {
  const files = [...readdirSync(join(BRIDGE, "src")).map((f) => join("src", f)), ...readdirSync(join(BRIDGE, "bin")).map((f) => join("bin", f))]
    .filter((f) => f.endsWith(".js"));
  for (const f of files) {
    const src = readFileSync(join(BRIDGE, f), "utf8");
    if (f !== join("src", "readonly.js")) assert.ok(!/createFirebase\b/.test(src), `${f} must use createReadOnlyFirebase`);
    assert.ok(!/\.(put|patch|del)\s*\(/.test(src), `${f} calls put / patch / del`);
  }
});
