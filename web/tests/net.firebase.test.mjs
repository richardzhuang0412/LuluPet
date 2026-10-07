import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import {
  buildURL, messagesQuery, misconfigurationReason, createFirebase, FirebaseError, MessageFeed,
} from "../js/net/firebase.js";
import { createScheduler } from "../js/net/scheduler.js";
import { startFake, testPairCode, rest, makeEventSource, makeSilentEventSource, waitFor, macMsg, faultyFetch } from "./net.helpers.mjs";

let fake;
before(async () => { fake = await startFake(); });
after(async () => { await fake?.stop(); });

test("buildURL / messagesQuery match FirebaseClient", () => {
  assert.equal(buildURL("http://127.0.0.1:8765/", "ABC", "messages", messagesQuery(41)),
    "http://127.0.0.1:8765/pairs/ABC/messages.json?orderBy=%22ts%22&startAt=42");
  assert.equal(buildURL(" https://x.example.com ", "A B", "presence/lulu"), "https://x.example.com/pairs/A%20B/presence/lulu.json");
  assert.throws(() => buildURL("ftp://x", "A", "m"), FirebaseError);
  assert.throws(() => buildURL("https://x/y", "A", "m"), FirebaseError);
});

test("misconfigurationReason wording", () => {
  assert.equal(misconfigurationReason(new FirebaseError("http", 401)), "数据库规则拒绝访问 (HTTP 401)");
  assert.equal(misconfigurationReason(new FirebaseError("http", 404)), "数据库地址有误 (HTTP 404)");
  assert.equal(misconfigurationReason(new FirebaseError("http", 400)), "数据库规则缺少 ts 索引 (HTTP 400)");
  assert.equal(misconfigurationReason(new FirebaseError("cancelled")), "数据库规则拒绝访问");
  assert.equal(misconfigurationReason(new FirebaseError("http", 500)), null);
  assert.equal(misconfigurationReason(new FirebaseError("network")), null);
});

test("fake --cors: preflight, CORS header, PATCH", async () => {
  const pre = await fetch(`${fake.url}/pairs/X/messages/k.json`, { method: "OPTIONS" });
  assert.equal(pre.status, 204);
  assert.equal(pre.headers.get("access-control-allow-origin"), "*");
  assert.match(pre.headers.get("access-control-allow-methods"), /PUT/);
  assert.match(pre.headers.get("access-control-allow-methods"), /PATCH/);
  assert.match(pre.headers.get("access-control-allow-headers"), /Content-Type/);
  const code = testPairCode();
  const fb = createFirebase({ databaseURL: fake.url, pairCode: code });
  await fb.put("read/lulu", { ts: 5, device: "web-t", at: 6 });
  await fb.patch("read/lulu", { ts: 7 });
  assert.deepEqual(await fb.get("read/lulu"), { ts: 7, device: "web-t", at: 6 });
  const res = await fetch(`${fake.url}/pairs/${code}/read/lulu.json`);
  assert.equal(res.headers.get("access-control-allow-origin"), "*");
});

test("REST: get null, put/get round trip, http error and timeout", async () => {
  const code = testPairCode();
  const fb = createFirebase({ databaseURL: fake.url, pairCode: code });
  assert.equal(await fb.get("presence/lulu"), null);
  await fb.put("messages/k1", macMsg("lumei", 10));
  assert.equal((await fb.get("messages", { query: messagesQuery(9) })).k1.ts, 10);
  assert.equal(await fb.get("messages", { query: messagesQuery(10) }), null);

  const f401 = faultyFetch(() => new Response("{}", { status: 401 }));
  await assert.rejects(createFirebase({ databaseURL: fake.url, pairCode: code, fetch: f401 }).get("x"),
    (e) => e instanceof FirebaseError && e.kind === "http" && e.status === 401);
  const hang = (url, init) => new Promise((_, rej) => init.signal.addEventListener("abort", () => rej(init.signal.reason)));
  await assert.rejects(createFirebase({ databaseURL: fake.url, pairCode: code, fetch: hang }).get("x", { timeoutMs: 50 }),
    (e) => e.kind === "timeout");
  const refused = createFirebase({ databaseURL: "http://127.0.0.1:1", pairCode: code });
  await assert.rejects(refused.get("x"), (e) => e.kind === "network");
});

function feedHarness({ ES, since = () => 0, timing = {}, fetch } = {}) {
  const code = testPairCode();
  const sched = createScheduler({ useWorker: false });
  const batches = [], states = [];
  const fb = createFirebase({ databaseURL: fake.url, pairCode: code, EventSource: ES, fetch });
  const feed = new MessageFeed({
    fb, since, sched,
    onBatch: (children, backlog) => batches.push({ keys: Object.keys(children).sort(), backlog }),
    onState: (s, r) => states.push(r ? `${s}:${r}` : s),
    timing: { backoffMinMs: 100, backoffMaxMs: 400, misconfiguredRetryMs: 300, firstPutTimeoutMs: 1500, pollVisibleMs: 100, pollHiddenMs: 200, ...timing },
    isHidden: () => false,
  });
  return { code, feed, batches, states, sched, r: rest(fake.url, code), done: () => { feed.stop(); sched.dispose(); } };
}

test("stream: backlog put, then live children; startAt = cursor + 1", async () => {
  const opened = [];
  const h = feedHarness({ ES: makeEventSource(opened), since: () => 100 });
  try {
    await h.r.put("messages/a", macMsg("lumei", 100));   // already read: not in the stream
    await h.r.put("messages/b", macMsg("lumei", 101));
    h.feed.start();
    await waitFor(() => h.batches.length >= 1, { what: "backlog" });
    assert.deepEqual(h.batches[0], { keys: ["b"], backlog: true });
    assert.deepEqual(h.states, ["connected"]);
    assert.match(opened[0], /orderBy=%22ts%22&startAt=101$/);
    await h.r.put("messages/c", macMsg("lumei", 102));
    await waitFor(() => h.batches.length >= 2, { what: "live child" });
    assert.deepEqual(h.batches[1], { keys: ["c"], backlog: false });
  } finally { h.done(); }
});

test("stream: server goes away → offline, backoff, reconnect with the new cursor", async () => {
  const opened = [];
  let cursor = 0;
  const h = feedHarness({ ES: makeEventSource(opened), since: () => cursor });
  try {
    h.feed.start();
    await waitFor(() => h.states.includes("connected"), { what: "connected" });
    cursor = 500;
    await fake.restart();
    await waitFor(() => h.states.filter((s) => s === "connected").length >= 2, { timeout: 8000, what: "reconnect" });
    assert.ok(h.states.includes("offline"), h.states.join(","));
    assert.match(opened.at(-1), /startAt=501$/);
  } finally { h.done(); }
});

test("stream: `cancel` event → misconfigured, retried later", async () => {
  class CancelES {
    constructor() { this.l = {}; CancelES.n = (CancelES.n ?? 0) + 1; setTimeout(() => this.l.cancel?.({ data: "null" }), 10); }
    addEventListener(t, f) { this.l[t] = f; }
    close() {}
  }
  const h = feedHarness({ ES: CancelES });
  try {
    h.feed.start();
    await waitFor(() => h.states.length, { what: "state" });
    assert.deepEqual(h.states, ["misconfigured:数据库规则拒绝访问"]);
    await waitFor(() => CancelES.n >= 2, { what: "retry after misconfiguredRetryMs" });
  } finally { h.done(); }
});

test("stream: HTTP 401 → probe GET reports the reason", async () => {
  const rejecting = await startFake({ args: ["--cors", "--reject"] });
  const sched = createScheduler({ useWorker: false });
  const states = [];
  const fb = createFirebase({ databaseURL: rejecting.url, pairCode: testPairCode(), EventSource: makeEventSource() });
  const feed = new MessageFeed({ fb, since: () => 0, sched, onBatch() {}, onState: (s, r) => states.push(`${s}:${r}`), timing: { misconfiguredRetryMs: 60_000 } });
  try {
    feed.start();
    await waitFor(() => states.length, { what: "state" });
    assert.deepEqual(states, ["misconfigured:数据库规则拒绝访问 (HTTP 401)"]);
  } finally { feed.stop(); sched.dispose(); await rejecting.stop(); }
});

test("watchdog: a silent stream is reopened after idleTimeoutMs", async () => {
  class OnePutES {
    constructor() { this.l = {}; OnePutES.n = (OnePutES.n ?? 0) + 1; setTimeout(() => this.l.put?.({ data: JSON.stringify({ path: "/", data: null }) }), 5); }
    addEventListener(t, f) { this.l[t] = f; }
    close() {}
  }
  const h = feedHarness({ ES: OnePutES, timing: { idleTimeoutMs: 200 } });
  try {
    h.feed.start();
    await waitFor(() => OnePutES.n >= 3, { what: "reopen" });
    assert.ok(h.states.includes("offline"));
  } finally { h.done(); }
});

test("polling fallback: no first put within firstPutTimeoutMs → polling, first poll = backlog, then live", async () => {
  const opened = [];
  const h = feedHarness({ ES: makeSilentEventSource(opened), timing: { firstPutTimeoutMs: 200 } });
  try {
    await h.r.put("messages/a", macMsg("lumei", 10));
    h.feed.start();
    await waitFor(() => h.states.includes("polling"), { what: "polling" });
    await waitFor(() => h.batches.length >= 1, { what: "first poll" });
    assert.deepEqual(h.batches[0], { keys: ["a"], backlog: true });
    await h.r.put("messages/b", macMsg("lumei", 11));
    await waitFor(() => h.batches.some((b) => b.keys.includes("b") && !b.backlog), { what: "polled live" });
    assert.equal(opened.length, 1);
    assert.ok(!h.states.includes("connected"));
  } finally { h.done(); }
});

test("polling fallback: SSE retried every sseRetryMs; a working stream takes over", async () => {
  let n = 0;
  const Real = makeEventSource(), Silent = makeSilentEventSource();
  const ES = function (url) { n++; return n === 1 ? new Silent(url) : new Real(url); };
  const h = feedHarness({ ES, timing: { firstPutTimeoutMs: 200, sseRetryMs: 400 } });
  try {
    h.feed.start();
    await waitFor(() => h.states.includes("polling"), { what: "polling" });
    await waitFor(() => h.states.at(-1) === "connected", { what: "back to stream" });
    assert.equal(n, 2);
    await h.r.put("messages/z", macMsg("lumei", 50));
    await waitFor(() => h.batches.some((b) => b.keys.includes("z") && !b.backlog), { what: "live via stream" });
  } finally { h.done(); }
});

test("stream keeps failing while a plain GET works → polling", async () => {
  class FailES {
    constructor() { this.onerror = null; setTimeout(() => this.onerror?.({}), 5); }
    addEventListener() {}
    close() {}
  }
  const h = feedHarness({ ES: FailES, timing: { failedOpensBeforePolling: 2 } });
  try {
    h.feed.start();
    await waitFor(() => h.states.includes("polling"), { what: "polling" });
    assert.equal(h.states[0], "offline");
  } finally { h.done(); }
});

test("stream: PATCH of the messages node arrives as a path-/ patch batch", async () => {
  const h = feedHarness({ ES: makeEventSource() });
  try {
    h.feed.start();
    await waitFor(() => h.states.includes("connected"), { what: "connected" });
    const fb = createFirebase({ databaseURL: fake.url, pairCode: h.code });
    await fb.patch("messages", { p1: macMsg("lumei", 20), p2: macMsg("lumei", 21) });
    await waitFor(() => h.batches.some((b) => b.keys.join() === "p1,p2"), { what: "patch batch" });
  } finally { h.done(); }
});
