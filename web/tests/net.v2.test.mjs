// W3 (v2 §4.4 / §4.5 / §2.2): channel look / 勿扰 / 专注 / trip / peek, history-db, tools-sync, fake query limits.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createChannel } from "../js/net/channel.js";
import { createMemoryStore } from "../js/net/store.js";
import { createFirebase, FirebaseError } from "../js/net/firebase.js";
import { openHistory, createMemoryBackend, messagesFetcher, backfillQuery } from "../js/net/history-db.js";
import { createToolsSync, slotLeaf } from "../js/net/tools-sync.js";
import { startFake, testPairCode, rest, makeEventSource, faultyFetch, waitFor, sleep, record, FAST, macMsg } from "./net.helpers.mjs";

let fake;
before(async () => { fake = await startFake(); });
after(async () => { await fake?.stop(); });

const open = [];
after(() => { for (const ch of open) ch.stop(); });
function make({ seat = "lulu", code = testPairCode(), fetch, timing = {}, deviceId = "web-v2-" + Math.random().toString(36).slice(2, 8) } = {}) {
  const ch = createChannel({
    config: { databaseURL: fake.url, pairCode: code, seat }, store: createMemoryStore(), deviceId,
    fetch, EventSource: makeEventSource(), timing: { ...FAST, lookBeatMinMs: 200, ...timing, feed: FAST.feed },
    lock: false, lifecycle: false, isHidden: () => false,
  });
  open.push(ch);
  return { ch, code, deviceId, log: record(ch), r: rest(fake.url, code) };
}
const presencePuts = (f, seat = "lulu") => f.calls.filter((c) => c.method === "PUT" && c.url.includes(`/presence/${seat}.json`));
const body = (call) => JSON.parse(call.body);

// ---- channel ----

test("setLook / setDnd / setFocus while owning the seat: immediate heartbeat with the fields, coalesced", async () => {
  const f = faultyFetch();
  const { ch, r } = make({ fetch: f, timing: { heartbeatMs: 60_000 } });
  await ch.start();
  await waitFor(() => presencePuts(f).length === 1, { what: "first beat" });
  assert.equal(body(presencePuts(f)[0]).pose, "idle");
  assert.equal(body(presencePuts(f)[0]).dnd, undefined);

  ch.setLook({ outfit: "bear", pose: "weather:rain" });
  await waitFor(() => presencePuts(f).length === 2, { what: "look beat" });
  const until = Date.now() + 600_000;
  ch.setDnd({ mood: "busy", until: 0 });
  ch.setFocus({ phase: "focus", until });
  ch.setLook({ pose: "dnd" });
  await sleep(100);
  assert.equal(presencePuts(f).length, 2, "changes within lookBeatMinMs wait");
  await waitFor(() => presencePuts(f).length === 3, { what: "coalesced beat" });
  await sleep(300);   // also lets that PUT land
  assert.equal(presencePuts(f).length, 3, "one beat for the three changes");
  const p = await r.get("presence/lulu");
  assert.equal(p.outfit, "bear");
  assert.equal(p.pose, "dnd");
  assert.deepEqual(p.dnd, { mood: "busy", until: 0 });
  assert.deepEqual(p.focus, { phase: "focus", until });
  assert.equal(p.client, "web");

  ch.setLook({ pose: "dnd" });   // unchanged → nothing
  await sleep(300);
  assert.equal(presencePuts(f).length, 3);

  ch.setDnd(null);
  ch.setFocus(null);
  // changes made in the same task leave together in one beat (the shell sets look + 勿扰 + 专注 at once)
  await waitFor(() => presencePuts(f).length === 4, { what: "off beat" });
  const q = await waitFor(async () => { const v = await r.get("presence/lulu"); return v.dnd === undefined && v.focus === undefined && v; }, { what: "off written" });
  assert.equal(q.dnd, undefined);
  assert.equal(q.focus, undefined);

  // a message carries the web's own outfit while owning the seat; trip option
  const m = ch.send({ kind: "poke", v: 1 }, { trip: "deliver" });
  assert.equal(m.trip, "deliver");
  assert.equal(m.outfit, "bear");
  assert.equal(ch.send({ kind: "poke", v: 1 }).trip, "local");
  assert.equal(ch.send({ kind: "poke", v: 1, trip: "deliver" }).trip, "deliver");

  // sign-off keeps dnd, drops pose / focus
  ch.setDnd({ mood: "angry", until: 0 });
  ch.setFocus({ until });
  await waitFor(async () => (await r.get("presence/lulu"))?.dnd?.mood === "angry", { what: "dnd beat" });
  assert.equal(await ch.signOff(), true);
  const off = await r.get("presence/lulu");
  assert.equal(off.lastSeen, 0);
  assert.deepEqual(off.dnd, { mood: "angry", until: 0 });
  assert.equal(off.focus, undefined);
  assert.equal(off.pose, undefined);
  assert.equal(off.outfit, "bear");
});

test("an expired dnd / focus is not written", async () => {
  const f = faultyFetch();
  const { ch, r } = make({ fetch: f, timing: { heartbeatMs: 60_000 } });
  await ch.start();
  ch.setDnd({ mood: "busy", until: Date.now() - 1 });
  ch.setFocus({ phase: "focus", until: Date.now() - 1 });
  await waitFor(() => presencePuts(f).length >= 2, { what: "beat" });
  const p = await r.get("presence/lulu");
  assert.equal(p.dnd, undefined);
  assert.equal(p.focus, undefined);
});

test("yielding to my Mac: look / 勿扰 / 专注 only remembered, written with the first heartbeat after taking over", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  const mac = { lastSeen: Date.now(), character: "lulu", mode: "couple", device: "mac-home", outfit: "classic", pose: "idle" };
  await r.put("presence/lulu", mac);
  const f = faultyFetch();
  const { ch, log } = make({ code, fetch: f });
  await ch.start();
  assert.equal(ch.yielding, true);
  ch.setLook({ outfit: "bear", pose: "quiet" });
  ch.setDnd({ mood: "resting", until: 0 });
  const until = Date.now() + 600_000;
  ch.setFocus({ phase: "focus", until });
  assert.equal(ch.outfit, "classic", "while yielding, the Mac's outfit");
  const m = ch.send({ kind: "poke", v: 1 });
  assert.equal(m.outfit, "classic");
  for (let i = 0; i < 3; i++) { await r.put("presence/lulu", { ...mac, lastSeen: Date.now() }); await sleep(120); }
  assert.equal(presencePuts(f).length, 0, "nothing written over the online Mac");
  assert.equal((await r.get("presence/lulu")).device, "mac-home");

  await r.put("presence/lulu", { ...mac, lastSeen: 0 });
  await waitFor(() => presencePuts(f).length >= 1, { what: "take over" });
  const first = body(presencePuts(f)[0]);
  assert.equal(first.outfit, "bear");
  assert.equal(first.pose, "quiet");
  assert.deepEqual(first.dnd, { mood: "resting", until: 0 });
  assert.deepEqual(first.focus, { phase: "focus", until });
  assert.ok(log.of("mySeat").some((s) => s.yielding === false));
});

test("peekPartner: reads now, null when never written, last known on network trouble, error when nothing known", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  let down = false;
  const f = faultyFetch(() => { if (down) throw new TypeError("offline"); });
  const { ch, log } = make({ code, fetch: f });
  assert.equal(await ch.peekPartner(), null);
  await r.put("presence/lumei", { lastSeen: Date.now(), character: "lumei", mode: "couple", device: "mac-ta", outfit: "angel", pose: "doze" });
  const p = await ch.peekPartner();
  assert.equal(p.outfit, "angel");
  assert.equal(p.pose, "doze");
  assert.equal(log.of("partner").at(-1).online, true);
  down = true;
  assert.equal((await ch.peekPartner()).outfit, "angel");
  const g = make({ code, fetch: f });
  await assert.rejects(g.ch.peekPartner(), (e) => e instanceof FirebaseError);
});

// ---- fake firebase queries ----

test("fake: limitToLast / limitToFirst / endAt like Firebase (ordered by ts, ties by key)", async () => {
  const code = testPairCode();
  const fb = createFirebase({ databaseURL: fake.url, pairCode: code });
  for (let i = 1; i <= 10; i++) await fb.put(`messages/k${String(i).padStart(2, "0")}`, macMsg("lumei", 100 + i));
  await fb.put("messages/tie", macMsg("lulu", 110));
  const keys = (o) => Object.keys(o ?? {}).sort();
  assert.deepEqual(keys(await fb.get("messages", { query: 'orderBy=%22ts%22&limitToLast=3' })), ["k09", "k10", "tie"]);
  assert.deepEqual(keys(await fb.get("messages", { query: 'orderBy=%22ts%22&limitToFirst=2' })), ["k01", "k02"]);
  assert.deepEqual(keys(await fb.get("messages", { query: 'orderBy=%22ts%22&endAt=103' })), ["k01", "k02", "k03"]);
  assert.deepEqual(keys(await fb.get("messages", { query: 'orderBy=%22ts%22&endAt=110&limitToLast=2' })), ["k10", "tie"]);
  assert.deepEqual(keys(await fb.get("messages", { query: 'orderBy=%22ts%22&endAt=109&limitToLast=2' })), ["k08", "k09"]);
  assert.deepEqual(keys(await fb.get("messages", { query: 'orderBy=%22ts%22&startAt=104&endAt=105' })), ["k04", "k05"]);
  assert.equal(await fb.get("messages", { query: 'orderBy=%22ts%22&endAt=5' }), null);
  await assert.rejects(fb.get("messages", { query: 'orderBy=%22ts%22&limitToLast=0' }), (e) => e.status === 400);
  await fb.del("messages/tie");
  assert.equal((await fb.get("messages/tie")), null);
});

// ---- history-db ----

test("history: first backfill = latest 300, older pages via endAt until complete, then only newer; dedupe by key", async () => {
  const code = testPairCode();
  const fb = createFirebase({ databaseURL: fake.url, pairCode: code });
  const base = 1_700_000_000_000;
  const seed = {};
  for (let i = 0; i < 700; i++) seed[`h${String(i).padStart(4, "0")}`] = macMsg(i % 2 ? "lumei" : "lulu", base + i);
  await fb.put("messages", seed);

  const queries = [];
  const real = messagesFetcher({ databaseURL: fake.url, pairCode: code });
  const fetcher = (q) => { queries.push(q); return real(q); };
  const backend = createMemoryBackend();
  const h = await openHistory({ pairCode: code, seat: "lulu" }, { backend });

  // a live message stored before the first backfill must not hide the gap below it
  await h.put([{ id: "live1", from: "lumei", kind: "text", text: "live", ts: base + 699, v: 1 }]);
  assert.equal(await h.latestTs(), base + 699);

  let r = await h.backfill(fetcher);
  assert.deepEqual(r, { added: 300, complete: false });
  assert.equal(queries[0], backfillQuery.latest());
  assert.equal(queries[0], "orderBy=%22ts%22&limitToLast=300");
  assert.equal(backend.shared.rows.size, 301);
  r = await h.backfill(fetcher, { older: true });
  assert.equal(queries[1], `orderBy=%22ts%22&endAt=${base + 399}&limitToLast=300`);
  assert.deepEqual(r, { added: 300, complete: false });
  r = await h.backfill(fetcher, { older: true });
  assert.deepEqual(r, { added: 100, complete: true });
  assert.equal(h.meta.oldestComplete, true);
  assert.equal(backend.shared.rows.size, 701);
  r = await h.backfill(fetcher, { older: true });
  assert.deepEqual(r, { added: 0, complete: true });
  assert.equal(queries.length, 3, "no request once complete");

  // newer only
  await fb.put("messages/n1", macMsg("lumei", base + 800));
  r = await h.backfill(fetcher);
  assert.equal(queries[3], `orderBy=%22ts%22&startAt=${base + 700}`);
  assert.deepEqual(r, { added: 1, complete: true });
  r = await h.backfill(fetcher);
  assert.equal(queries[4], `orderBy=%22ts%22&startAt=${base + 801}`);
  assert.equal(r.added, 0);

  // dedupe: the same keys again (stream + backfill) are stored once
  await h.put({ n1: macMsg("lumei", base + 800), h0000: seed.h0000 });
  assert.equal(backend.shared.rows.size, 702);

  // pages: newest first page, then older, oldest first within a page, (ts, id) bound handles equal ts
  const p1 = await h.page({ limit: 100 });
  assert.equal(p1.length, 100);
  assert.equal(p1.at(-1).id, "n1");
  assert.ok(p1.every((m, i) => i === 0 || p1[i - 1].ts <= m.ts));
  const p2 = await h.page({ beforeTs: p1[0].ts, beforeId: p1[0].id, limit: 100 });
  assert.equal(p2.at(-1).ts, p1[0].ts - 1);
  const ids = new Set([...p1, ...p2].map((m) => m.id));
  assert.equal(ids.size, 200);
  assert.ok(ids.has("live1") && ids.has("h0699"), "two messages with the same ts both listed");

  // reopen: same pair keeps; another seat clears
  const again = await openHistory({ pairCode: code, seat: "lulu" }, { backend });
  assert.equal(await again.latestTs(), base + 800);
  assert.equal(again.meta.oldestComplete, true);
  const other = await openHistory({ pairCode: code, seat: "lumei" }, { backend });
  assert.equal(await other.latestTs(), 0);
  assert.equal(backend.shared.rows.size, 0);
  assert.equal(other.meta.syncedTo, null);
});

test("history: olderPage fetches TA's older messages even when my own older ones are already stored (E10 run B)", async () => {
  const code = testPairCode();
  const fb = createFirebase({ databaseURL: fake.url, pairCode: code });
  const base = 1_700_000_000_000;
  const seed = {};
  const key = (i) => `h${String(i).padStart(4, "0")}`;
  for (let i = 1; i <= 700; i++) seed[key(i)] = macMsg(i % 2 ? "lumei" : "lulu", base + i);
  await fb.put("messages", seed);
  const queries = [];
  const real = messagesFetcher({ databaseURL: fake.url, pairCode: code });
  const fetcher = (q) => { queries.push(q); return real(q); };
  const h = await openHistory({ pairCode: code, seat: "lulu" }, { backend: createMemoryBackend() });

  // the channel's first GET (no read cursor) delivered all of my 350 as `own`: stored before any backfill
  const mine = Object.fromEntries(Object.entries(seed).filter(([, v]) => v.from === "lulu"));
  assert.equal(await h.put(mine), 350);
  await h.backfill(fetcher);                       // tab opened: latest 300 (#401..#700)
  let msgs = await h.page({ limit: 100 });
  assert.equal(msgs[0].id, key(601));

  let fetches = 0;
  for (let click = 1; click <= 10; click++) {
    const r = await h.olderPage(fetcher, { beforeTs: msgs[0].ts, beforeId: msgs[0].id, limit: 100, onFetch: () => fetches++ });
    // every page is contiguous: TA's messages between mine are never skipped
    r.page.forEach((m, i) => assert.equal(m.id, key(msgs[0].ts - base - r.page.length + i), `click ${click}`));
    msgs = r.page.concat(msgs);
    if (r.complete && r.page.length < 100) break;
  }
  assert.deepEqual(msgs.map((m) => m.id), Object.keys(seed), "all 700 shown, in order");
  assert.equal(fetches, 2, "server asked when the page reached below what backfill covered (#401, #101), not before");
  assert.deepEqual(queries.slice(1), [backfillQuery.older(base + 401), backfillQuery.older(base + 101)]);
  assert.equal(h.meta.oldestComplete, true);

  // offline: the fetch error rejects (the tab keeps what it shows); never synced + empty server: complete at once
  const h2 = await openHistory({ pairCode: "R", seat: "lulu" }, { backend: createMemoryBackend() });
  await h2.put(mine);
  await assert.rejects(h2.olderPage(async () => { throw new FirebaseError("network"); }, { beforeTs: base + 1000, limit: 100 }));
  const r2 = await h2.olderPage(async () => null, { beforeTs: base + 1000, limit: 100 });
  assert.deepEqual(r2, { page: await h2.page({ limit: 100 }), complete: true });
});

test("history: raw JSON kept as is (unknown kind / extra fields), bad children skipped, clear()", async () => {
  const backend = createMemoryBackend();
  const h = await openHistory({ pairCode: "P", seat: "lumei" }, { backend });
  const future = { from: "lulu", kind: "hologram", ts: 5, v: 2, glow: { a: 1 } };
  const n = await h.put({ a: future, b: { from: "eve", kind: "text", ts: 6 }, c: "x", d: macMsg("lulu", 7, { kind: "sticker", stickerId: "hug" }) });
  assert.equal(n, 2);
  assert.deepEqual(backend.shared.rows.get("a").raw, future);
  const rows = await h.page();
  assert.deepEqual(rows.map((m) => [m.id, m.kind]), [["a", "hologram"], ["d", "sticker"]]);
  assert.deepEqual(rows[0].extra, { glow: { a: 1 } });
  // decoded messages (channel events) go back to their wire form
  await h.put([{ id: "e", from: "lumei", kind: "text", text: "嗨", ts: 8, v: 1, character: "lumei", trip: "deliver" }]);
  assert.deepEqual(backend.shared.rows.get("e").raw, { from: "lumei", kind: "text", text: "嗨", ts: 8, v: 1, character: "lumei", trip: "deliver" });
  await h.clear();
  assert.equal(await h.latestTs(), 0);
  assert.deepEqual(await h.page(), []);
  assert.equal(h.meta.pairCode, "P");
});

test("history: empty server → complete at once; a failed fetch rejects and changes nothing", async () => {
  const h = await openHistory({ pairCode: "Q", seat: "lulu" }, { backend: createMemoryBackend() });
  await assert.rejects(h.backfill(async () => { throw new FirebaseError("network"); }));
  assert.equal(h.meta.syncedTo, null);
  assert.deepEqual(await h.backfill(async () => null), { added: 0, complete: true });
  assert.equal(h.meta.syncedTo, 0);
  const qs = [];
  await h.backfill(async (q) => { qs.push(q); return null; });
  assert.deepEqual(qs, ["orderBy=%22ts%22&startAt=1"]);
});

// ---- tools-sync ----

test("tools-sync: settings / days at tools/{seat}/eyedrops, same JSON as ToolsSync", async () => {
  const code = testPairCode();
  const r = rest(fake.url, code);
  const ts = createToolsSync({ config: { databaseURL: fake.url, pairCode: code, seat: "lumei" }, deviceId: "web-abc", now: () => 1791000000000 });
  assert.equal(ts.path, "tools/lumei/eyedrops");
  assert.equal(await ts.getSettings(), null);
  assert.deepEqual(await ts.getDay("2026-10-12"), {});

  const s = await ts.putSettings({ enabled: true, times: ["08:00", "12:00"], notify: false });
  assert.deepEqual(s, { enabled: true, times: ["08:00", "12:00"], notify: false, at: 1791000000000, device: "web-abc" });
  assert.deepEqual(await r.get("tools/lumei/eyedrops/settings"), s);
  assert.deepEqual(await ts.getSettings(), s);
  await ts.putSettings({ enabled: false, times: [], notify: true, at: 5, device: "mac-x" });
  assert.deepEqual(await ts.getSettings(), { enabled: false, times: [], notify: true, at: 5, device: "mac-x" });

  assert.deepEqual(await ts.putDone("2026-10-12", "08:00"), { done: 1791000000000, device: "web-abc" });
  await r.put("tools/lumei/eyedrops/days/2026-10-12/1200", { done: 1791014500000, device: "mac-home" });
  await ts.putDone("2026-10-12", "2100", { done: 1791040000000 });
  assert.deepEqual(await ts.getDay("2026-10-12"), {
    "0800": { done: 1791000000000, device: "web-abc" },
    "1200": { done: 1791014500000, device: "mac-home" },
    "2100": { done: 1791040000000, device: "web-abc" },
  });
  await ts.deleteDone("2026-10-12", "08:00");
  assert.deepEqual(Object.keys(await ts.getDay("2026-10-12")), ["1200", "2100"]);
  assert.deepEqual(Object.keys(await r.get("tools/lumei/eyedrops")).sort(), ["days", "settings"]);
  assert.equal(await r.get("tools/lulu"), null, "my partner's seat untouched");

  await assert.rejects(ts.putDone("2026-1-2", "0800"), TypeError);
  await assert.rejects(ts.putDone("2026-10-12", "24:00"), TypeError);
  assert.equal(slotLeaf("7:30"), null);
  assert.equal(slotLeaf("23:59"), "2359");
});

test("tools-sync: errors reject (http / timeout); non-object bodies read as nothing", async () => {
  const code = testPairCode();
  const cfg = { databaseURL: fake.url, pairCode: code, seat: "lulu" };
  const f = faultyFetch(() => new Response("{}", { status: 401 }));
  await assert.rejects(createToolsSync({ config: cfg, deviceId: "web-x", fetch: f }).putDone("2026-10-12", "0800"),
    (e) => e instanceof FirebaseError && e.status === 401);
  const hang = (url, init) => new Promise((_, rej) => init.signal.addEventListener("abort", () => rej(init.signal.reason)));
  await assert.rejects(createToolsSync({ config: cfg, deviceId: "web-x", fetch: hang }).getDay("2026-10-12", { timeoutMs: 50 }),
    (e) => e.kind === "timeout");
  await rest(fake.url, code).put("tools/lulu/eyedrops/settings", 7);
  assert.equal(await createToolsSync({ config: cfg, deviceId: "web-x" }).getSettings(), null);
  assert.throws(() => createToolsSync({ config: { ...cfg, seat: "x" }, deviceId: "web-x" }));
});
