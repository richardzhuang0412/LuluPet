import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createChannel } from "../js/net/channel.js";
import { createMemoryStore } from "../js/net/store.js";
import {
  startFake, testPairCode, rest, makeEventSource, makeSilentEventSource, faultyFetch, waitFor, sleep, record, FAST, macMsg,
} from "./net.helpers.mjs";

let fake;
before(async () => { fake = await startFake(); });
after(async () => { await fake?.stop(); });

const open = [];
function make({ seat = "lulu", code = testPairCode(), store = createMemoryStore(), fetch, ES, timing = {}, deviceId = "web-test-" + Math.random().toString(36).slice(2, 8), lock = false, lockName } = {}) {
  const ch = createChannel({
    config: { databaseURL: fake.url, pairCode: code, seat }, store, deviceId,
    fetch, EventSource: ES ?? makeEventSource(), timing: { ...FAST, ...timing, feed: { ...FAST.feed, ...(timing.feed ?? {}) } },
    lock, lockName, lifecycle: false, isHidden: () => false,
  });
  open.push(ch);
  return { ch, code, store, deviceId, log: record(ch), r: rest(fake.url, code) };
}
after(() => { for (const ch of open) ch.stop(); });

const connected = (log) => waitFor(() => log.of("connection").some((c) => c.state === "connected"), { what: "connected" });

test("send: idempotent PUT to a client push key with the §2.1 fields; ts strictly increasing", async () => {
  const { ch, log, r } = make({ seat: "lumei" });
  await ch.start();
  await connected(log);
  const t = Date.now() + 5000;
  const a = ch.send({ kind: "text", text: "你好 <b>", ts: t, v: 1 });
  const b = ch.send({ kind: "poke", ts: t, v: 1 });   // same ms → bumped
  assert.match(a.id, /^[-0-9A-Za-z_]{20}$/);
  assert.equal(b.ts, a.ts + 1);
  await waitFor(() => log.of("sent").length === 2, { what: "sent" });
  const all = await r.get("messages");
  assert.deepEqual(Object.keys(all).sort(), [a.id, b.id].sort());
  assert.deepEqual(all[a.id], { from: "lumei", kind: "text", text: "你好 <b>", ts: t, v: 1, character: "lumei", trip: "local" });
  assert.deepEqual(all[b.id], { from: "lumei", kind: "poke", ts: t + 1, v: 1, character: "lumei", trip: "local" });
  assert.equal(log.of("message").length, 0, "own echo is not a partner message");
  assert.equal(log.of("own").length, 0, "own echo of this browser's sends is not reported");
  assert.equal(ch.store.get("outbox"), null);
});

test("send: a write that times out after the server stored it is retried to the same key (one child)", async () => {
  let failOnce = true;
  const f = faultyFetch(async (url, init) => {
    if (init.method === "PUT" && url.includes("/messages/") && failOnce) {
      failOnce = false;
      await fetch(url, init);              // reached the server …
      throw new DOMException("t", "TimeoutError");   // … but the answer was lost
    }
  });
  const { ch, log, r } = make({ fetch: f });
  await ch.start();
  await connected(log);
  const m = ch.send({ kind: "text", text: "once", v: 1 });
  await waitFor(() => log.of("sent").length === 1, { what: "sent after retry" });
  const puts = f.calls.filter((c) => c.method === "PUT" && c.url.includes(`/messages/${m.id}.json`));
  assert.equal(puts.length, 2);
  assert.deepEqual(Object.keys(await r.get("messages")), [m.id]);
});

test("outbox: survives a reload (same store), dropped for another pair code / seat", async () => {
  const store = createMemoryStore();
  const code = testPairCode();
  const down = faultyFetch((url, init) => { if (init.method === "PUT" && url.includes("/messages/")) throw new TypeError("offline"); });
  const first = make({ code, store, fetch: down });
  await first.ch.start();
  const m1 = first.ch.send({ kind: "text", text: "a", v: 1 });
  const m2 = first.ch.send({ kind: "text", text: "b", v: 1 });
  await sleep(100);
  first.ch.stop();
  const saved = store.get("outbox");
  assert.equal(saved.pairCode, code);
  assert.equal(saved.seat, "lulu");
  assert.deepEqual(saved.messages.map((m) => m.id), [m1.id, m2.id]);

  const other = createMemoryStore({ outbox: saved });
  const wrongSeat = make({ code, seat: "lumei", store: other });
  assert.equal(wrongSeat.ch.pending.length, 0);
  assert.equal(other.get("outbox"), null);

  const second = make({ code, store });
  assert.equal(second.ch.pending.length, 2);
  const m3 = second.ch.send({ kind: "text", text: "c", ts: 1, v: 1 });
  assert.ok(m3.ts > m2.ts, "ts continues after the persisted outbox");
  await second.ch.start();
  await waitFor(() => second.log.of("sent").length === 3, { what: "all sent" });
  assert.deepEqual(second.log.of("sent").map((s) => s.msg.id), [m1.id, m2.id, m3.id]);
  assert.equal(Object.keys(await second.r.get("messages")).length, 3);
  assert.equal(store.get("outbox"), null);
});

test("outbox: 400 parks that message and the rest go on; 5xx retries", async () => {
  let flaky = 2;
  const f = faultyFetch((url, init) => {
    if (init.method !== "PUT") return;
    if (String(init.body).includes("refused")) return new Response('{"error":"bad"}', { status: 400 });
    if (url.includes("/messages/") && flaky > 0) { flaky--; return new Response("{}", { status: 503 }); }
  });
  const { ch, log, r, store } = make({ fetch: f });
  await ch.start();
  await connected(log);
  const a = ch.send({ kind: "text", text: "retried", v: 1 });
  await waitFor(() => log.of("sent").length === 1, { what: "sent after 503s" });
  assert.equal(log.of("sent")[0].msg.id, a.id);
  const b = ch.send({ kind: "text", text: "refused", v: 1 });
  const c = ch.send({ kind: "text", text: "after", v: 1 });
  await waitFor(() => log.of("sent").length === 2, { what: "c sent" });
  assert.deepEqual(log.of("parked").map((p) => [p.msg.id, p.status]), [[b.id, 400]]);
  assert.deepEqual(store.get("outbox").failed, [b.id]);
  assert.deepEqual(Object.keys(await r.get("messages")).sort(), [a.id, c.id].sort());
});

test("outbox: 401 retries while reads fail, parks once the stream is connected", async () => {
  const f = faultyFetch((url, init) => { if (init.method === "PUT" && url.includes("/messages/")) return new Response("{}", { status: 401 }); });
  const { ch, log } = make({ fetch: f, ES: makeSilentEventSource(), timing: { feed: { firstPutTimeoutMs: 60_000 } } });
  await ch.start();   // stream never connects: state stays "connecting"
  const m = ch.send({ kind: "text", text: "x", v: 1 });
  await sleep(500);
  assert.equal(log.of("parked").length, 0);
  assert.ok(f.calls.filter((c) => c.url.includes(m.id)).length >= 2, "retried");
  ch.stop();

  const g = make({ fetch: f });
  await g.ch.start();
  await connected(g.log);
  const n = g.ch.send({ kind: "text", text: "y", v: 1 });
  await waitFor(() => g.log.of("parked").length === 1, { what: "parked" });
  assert.equal(g.log.of("parked")[0].msg.id, n.id);
});

test("receive: backlog (first put) as one event, then live messages; own seat not shown; dedupe", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  await r.put("messages/k1", macMsg("lumei", 1000));
  await r.put("messages/k2", macMsg("lumei", 1001, { kind: "sticker", stickerId: "missyou", text: "[表情] 想你了" }));
  await r.put("messages/m1", macMsg("lulu", 1002));   // my home Mac
  const { ch, log } = make({ code });
  await ch.start();
  await waitFor(() => log.of("backlog").length === 1, { what: "backlog" });
  assert.deepEqual(log.of("backlog")[0].msgs.map((m) => m.id), ["k1", "k2"]);
  assert.equal(log.of("own").length, 1);
  assert.equal(log.of("own")[0].msg.id, "m1");
  await r.put("messages/k3", macMsg("lumei", 1003, { kind: "remind", remind: "water" }));
  await r.put("messages/bad", { from: "eve", kind: "text", ts: 1004 });
  await waitFor(() => log.of("message").length === 1, { what: "live" });
  assert.equal(log.of("message")[0].msg.id, "k3");
  assert.equal(log.of("message")[0].live, true);
  const mine = ch.send({ kind: "text", text: "after own", ts: 1, v: 1 });
  assert.ok(mine.ts > 1002, "lastSentTs absorbed my seat's messages");
});

test("receive: a backlog of 60 is folded to the newest 50; the folded are marked read", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  for (let i = 0; i < 60; i++) await r.put(`messages/f${String(i).padStart(2, "0")}`, macMsg("lumei", 2000 + i));
  const { ch, log, store } = make({ code });
  await ch.start();
  await waitFor(() => log.of("backlog").length === 1, { what: "backlog" });
  assert.deepEqual(log.of("folded"), [{ count: 10 }]);
  const kept = log.of("backlog")[0].msgs;
  assert.equal(kept.length, 50);
  assert.equal(kept[0].ts, 2010);
  assert.equal(store.get("lastReadTs"), 2009, "cursor stops before the oldest unread");
});

test("read cursor: out-of-order markRead never passes an unread message", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  await r.put("messages/a", macMsg("lumei", 3000));
  await r.put("messages/b", macMsg("lumei", 3001));
  await r.put("messages/c", macMsg("lumei", 3002));
  const { ch, log, store } = make({ code });
  await ch.start();
  await waitFor(() => log.of("backlog").length === 1, { what: "backlog" });
  const [a, b, c] = log.of("backlog")[0].msgs;
  ch.markRead(c);
  assert.equal(store.get("lastReadTs"), 2999);
  ch.markRead(a);
  assert.equal(store.get("lastReadTs"), 3000);
  ch.markRead(b);
  assert.equal(store.get("lastReadTs"), 3002);
});

test("shared read cursor: start = max(local, read/{seat}); writes throttled to one per cursorWriteMs; pagehide flushes", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  await r.put("read/lulu", { ts: 5000, device: "mac-home", at: 1 });
  await r.put("messages/old", macMsg("lumei", 4999));
  for (let i = 1; i <= 4; i++) await r.put(`messages/n${i}`, macMsg("lumei", 5000 + i));
  const opened = [];
  const f = faultyFetch();
  const { ch, log, store, deviceId } = make({ code, fetch: f, ES: makeEventSource(opened), store: createMemoryStore({ lastReadTs: 4000 }) });
  await ch.start();
  await waitFor(() => log.of("backlog").length === 1, { what: "backlog" });
  assert.match(opened[0], /startAt=5001$/);
  assert.equal(store.get("lastReadTs"), 5000);
  const msgs = log.of("backlog")[0].msgs;
  assert.deepEqual(msgs.map((m) => m.id), ["n1", "n2", "n3", "n4"]);
  const readPuts = () => f.calls.filter((c) => c.method === "PUT" && c.url.includes("/read/lulu.json"));

  ch.markRead(msgs[0]);
  await waitFor(() => readPuts().length === 1, { what: "first write (not throttled)" });
  ch.markRead(msgs[1]);
  ch.markRead(msgs[2]);
  await sleep(250);
  assert.equal(readPuts().length, 1, "throttled");
  await waitFor(() => readPuts().length === 2, { timeout: 2000, what: "trailing write" });
  let shared = await r.get("read/lulu");
  assert.equal(shared.ts, 5003);
  assert.equal(shared.device, deviceId);
  assert.ok(Number.isInteger(shared.at));

  ch.markRead(msgs[3]);
  ch.onPageHide({ persisted: false });
  await waitFor(() => readPuts().length === 3, { what: "pagehide flush" });
  assert.equal(readPuts().at(-1).keepalive, true);
  shared = await r.get("read/lulu");
  assert.equal(shared.ts, 5004);
  await sleep(800);
  assert.equal(readPuts().length, 3, "nothing new to write");
});

test("shared read cursor: never written backwards; a far-future value is clamped", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  const future = Date.now() + 10 * 86_400_000;
  await r.put("read/lulu", { ts: future, device: "x", at: 1 });
  const opened = [];
  const { ch, store } = make({ code, ES: makeEventSource(opened) });
  await ch.start();
  await waitFor(() => opened.length, { what: "stream" });
  const v = store.get("lastReadTs");
  assert.ok(v <= Date.now() + 86_400_000 && v > Date.now(), "clamped to now + 1 day");
});

test("seat yield: my Mac online → no heartbeat; Mac signs off → web heartbeats within a seat check", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  const mac = { lastSeen: Date.now(), character: "lulu", mode: "couple", device: "mac-home", app: "0.16.0", outfit: "bear", place: { name: "上海", latitude: 31.23, longitude: 121.47, timezone: "Asia/Shanghai" } };
  await r.put("presence/lulu", mac);
  const f = faultyFetch();
  const { ch, log, deviceId } = make({ code, fetch: f });
  await ch.start();
  const beats = () => f.calls.filter((c) => c.method === "PUT" && c.url.includes("/presence/lulu.json"));
  assert.equal(ch.yielding, true);
  assert.equal(log.of("mySeat")[0].yielding, true);
  assert.deepEqual(log.of("mySeat")[0].identity, { character: "lulu", mode: "couple", outfit: "bear", place: mac.place });
  // keep the Mac "online" for a few checks
  for (let i = 0; i < 4; i++) { await r.put("presence/lulu", { ...mac, lastSeen: Date.now() }); await sleep(120); }
  assert.equal(beats().length, 0, "never writes over an online Mac");
  assert.equal(await ch.signOff(), false, "no sign-off over the Mac");
  assert.equal(beats().length, 0);
  ch.signedOff = false;

  await r.put("presence/lulu", { ...mac, lastSeen: 0 });   // Mac sleeps
  await waitFor(() => beats().length >= 1, { what: "web takes over" });
  const p = await r.get("presence/lulu");
  assert.equal(p.device, deviceId);
  assert.equal(p.client, "web");
  assert.equal(p.character, "lulu");
  assert.equal(p.outfit, "bear");
  assert.deepEqual(p.place, mac.place);
  assert.equal(p.app, undefined, "web never writes app");
  assert.ok(p.lastSeen > 0);
  await waitFor(() => log.of("mySeat").some((s) => s.yielding === false), { what: "mySeat yielding=false" });

  // heartbeats keep going at heartbeatMs, not every seat check
  const n0 = beats().length;
  await sleep(700);
  const n = beats().length - n0;
  assert.ok(n >= 1 && n <= 3, `heartbeats in 700 ms at 300 ms: ${n}`);

  assert.equal(await ch.signOff(), true);
  const off = await r.get("presence/lulu");
  assert.equal(off.lastSeen, 0);
  assert.equal(off.device, deviceId);
  assert.equal(beats().at(-1).keepalive, true);
  await sleep(500);
  assert.equal((await r.get("presence/lulu")).lastSeen, 0, "no heartbeat after sign-off");
});

test("seat yield: another web device or a stale Mac on my seat → heartbeat", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  await r.put("presence/lumei", { lastSeen: Date.now(), character: "lumei", mode: "friend", device: "web-phone", client: "web" });
  const f = faultyFetch();
  const { ch } = make({ code, seat: "lumei", fetch: f });
  await ch.start();
  assert.equal(ch.yielding, false);
  assert.ok(f.calls.some((c) => c.method === "PUT" && c.url.includes("/presence/lumei.json")));
  assert.equal(ch.identity.mode, "friend", "identity copied from a web-written seat when nothing better is known");
  ch.stop();

  const code2 = testPairCode();
  await rest(fake.url, code2).put("presence/lumei", { lastSeen: Date.now() - 120_000, device: "mac-x" });
  const g = make({ code: code2, seat: "lumei" });
  await g.ch.start();
  assert.equal(g.ch.yielding, false);
});

test("partner presence: event on change with online flag", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  const { ch, log } = make({ code });
  await ch.start();
  await waitFor(() => log.of("partner").length >= 1, { what: "first partner read" });
  assert.deepEqual(log.of("partner")[0], { presence: null, online: false });
  assert.deepEqual(log.of("mySeat")[0], { presence: null, yielding: false, identity: { character: "lulu", mode: "couple" } },
    "the first read of a never-written seat is reported");
  await r.put("presence/lumei", { lastSeen: Date.now(), character: "lumei", mode: "couple", device: "mac-ta", outfit: "angel" });
  await waitFor(() => log.of("partner").some((p) => p.online), { what: "online" });
  const p = log.of("partner").at(-1);
  assert.equal(p.presence.outfit, "angel");
});

test("Web Locks: only one channel per lock name runs; the next takes over when it stops", async () => {
  const lockName = "lulupet-test-" + Math.random();
  const code = testPairCode();
  const a = make({ code, lock: true, lockName });
  const b = make({ code, lock: true, lockName });
  await a.ch.start();
  const bStarted = b.ch.start();
  await waitFor(() => b.log.of("connection").some((c) => c.state === "elsewhere"), { what: "elsewhere" });
  await connected(a.log);
  assert.ok(!b.log.of("connection").some((c) => c.state === "connected"));
  a.ch.stop();
  await bStarted;
  await connected(b.log);
  b.ch.stop();
  // stop() while waiting for the lock resolves start()
  const c = make({ code, lock: true, lockName });
  const d = make({ code, lock: true, lockName });
  await c.ch.start();
  const dStarted = d.ch.start();
  await waitFor(() => d.ch.state === "elsewhere", { what: "d waits" });
  d.ch.stop();
  await dStarted;
  assert.equal(d.ch.running, false);
  c.ch.stop();
});

test("polling fallback through the channel: state polling, sends still go out, reads count as working", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  await r.put("messages/p1", macMsg("lumei", 7000));
  const f = faultyFetch((url, init) => { if (init.method === "PUT" && url.includes("/messages/")) return new Response("{}", { status: 403 }); });
  const { ch, log } = make({ code, fetch: f, ES: makeSilentEventSource(), timing: { feed: { firstPutTimeoutMs: 200 } } });
  await ch.start();
  await waitFor(() => log.of("connection").some((c) => c.state === "polling"), { what: "polling" });
  await waitFor(() => log.of("backlog").length === 1, { what: "backlog via poll" });
  await r.put("messages/p2", macMsg("lumei", 7001));
  await waitFor(() => log.of("message").length === 1, { what: "live via poll" });
  ch.send({ kind: "text", text: "z", v: 1 });
  await waitFor(() => log.of("parked").length === 1, { what: "403 parked while polling works" });
});
