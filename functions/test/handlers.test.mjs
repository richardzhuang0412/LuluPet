import { test } from "node:test";
import assert from "node:assert/strict";
import { eyedropsForSeat, handleMessage, runEyedrops, updateIndex } from "../src/handlers.js";
import { slotInstant } from "../vendor/eyedrops.js";
import { CODE, VAPID, fakeDb, fakeWebpush, sub } from "./helpers.mjs";

const LA = "America/Los_Angeles";
const D = "2026-10-12";
const at = (time, day = D) => slotInstant(day, time, LA);
const MIN = 60_000;

test("message → push to the other seat; 404 / 410 subscriptions are deleted, others kept", async () => {
  const now = at("10:00");
  const db = fakeDb({ pairs: { [CODE]: {
    push: {
      lulu: { ok: sub({ endpoint: "https://p/ok" }), gone: sub({ endpoint: "https://p/gone" }), old: sub({ endpoint: "https://p/410" }),
        flaky: sub({ endpoint: "https://p/500" }) },
      lumei: { mine: sub({ endpoint: "https://p/sender" }) },
    },
  } } });
  const wp = fakeWebpush((e) => ({ "https://p/gone": 404, "https://p/410": 410, "https://p/500": 500 })[e] ?? null);
  const r = await handleMessage({ db, webpush: wp, vapid: VAPID, code: CODE, id: "-Nx1",
    value: { from: "lumei", kind: "text", text: "在吗", ts: now - 500, character: "lumei" }, now });
  assert.equal(r.sent, 1);
  assert.deepEqual(wp.calls.map((c) => c.endpoint).sort(), ["https://p/410", "https://p/500", "https://p/gone", "https://p/ok"]);
  assert.deepEqual(wp.calls[0].payload, { v: 1, key: "-Nx1", tag: "msg--Nx1", kind: "message", title: "噜妹说：", body: "在吗" });
  assert.equal(wp.calls[0].opts.TTL, 21600);
  assert.deepEqual(wp.calls[0].opts.vapidDetails, VAPID);
  assert.deepEqual(Object.keys(db.tree().pairs[CODE].push.lulu).sort(), ["flaky", "ok"]);
  assert.ok(db.tree().pairs[CODE].push.lumei.mine, "the sender's own subscriptions are untouched");
});

test("message: nothing read beyond /push when the recipient has no subscription; bad code ignored", async () => {
  const db = fakeDb({ pairs: { [CODE]: { presence: { lulu: { lastSeen: 1 } } } } });
  const wp = fakeWebpush();
  const now = at("10:00");
  const r = await handleMessage({ db, webpush: wp, vapid: VAPID, code: CODE, id: "a", value: { from: "lumei", kind: "poke", ts: now }, now });
  assert.equal(r.skipped, "no-subs");
  assert.deepEqual(db.reads, [`pairs/${CODE}/push/lulu`]);
  assert.equal((await handleMessage({ db, webpush: wp, vapid: VAPID, code: "bad", id: "a", value: { from: "lumei", kind: "poke", ts: now }, now })).skipped, "code");
  assert.equal(wp.calls.length, 0);
});

test("message: recipient using the Mac → no push; Mac online but idle → push; in 勿扰 → silent", async () => {
  const now = at("10:00");
  const tree = (presence, devices) => ({ pairs: { [CODE]: { push: { lulu: { a: sub() } }, presence: { lulu: presence }, devices: { lulu: devices } } } });
  const value = { from: "lumei", kind: "text", text: "hi", ts: now };
  const macOnline = { lastSeen: now - 20_000, device: "mac-1" };
  let wp = fakeWebpush();
  await handleMessage({ db: fakeDb(tree(macOnline, { "mac-1": { kind: "mac", activeAt: now - 60_000, at: now - 20_000 } })),
    webpush: wp, vapid: VAPID, code: CODE, id: "m", value, now });
  assert.equal(wp.calls.length, 0);
  await handleMessage({ db: fakeDb(tree(macOnline, { "mac-1": { kind: "mac", activeAt: now - 600_000, at: now - 20_000 } })),
    webpush: wp, vapid: VAPID, code: CODE, id: "m", value, now });
  assert.equal(wp.calls.length, 1, "home Mac awake but idle: the phone is pushed");
  await handleMessage({ db: fakeDb(tree(macOnline, null)), webpush: wp, vapid: VAPID, code: CODE, id: "m", value, now });
  assert.equal(wp.calls.length, 2, "0.18 Mac (no records): pushed");
  wp = fakeWebpush();
  await handleMessage({ db: fakeDb(tree(macOnline, { "web-phone": { kind: "phone", activeAt: now - 5_000, at: now - 5_000, vis: "visible" } })),
    webpush: wp, vapid: VAPID, code: CODE, id: "m", value, now });
  assert.equal(wp.calls.length, 0, "phone app open: shown in-app");
  wp = fakeWebpush();
  await handleMessage({ db: fakeDb(tree({ lastSeen: 0, device: "mac-1", dnd: { mood: "resting", until: 0 } })), webpush: wp, vapid: VAPID, code: CODE, id: "m", value, now });
  assert.equal(wp.calls.length, 1);
  assert.equal(wp.calls[0].payload.silent, true);
});

test("message: device records older than 7 days are pruned; fresh and malformed ones kept", async () => {
  const now = at("10:00");
  const DAY = 86_400_000;
  const db = fakeDb({ pairs: { [CODE]: { push: { lulu: { a: sub() } }, devices: { lulu: {
    old: { kind: "mac", activeAt: now - 9 * DAY, at: now - 8 * DAY },
    fresh: { kind: "web", activeAt: now - DAY, at: now - DAY },
    odd: { kind: "web" },
  }, lumei: { other: { kind: "mac", activeAt: 1, at: 1 } } } } } });
  const wp = fakeWebpush();
  await handleMessage({ db, webpush: wp, vapid: VAPID, code: CODE, id: "m", value: { from: "lumei", kind: "poke", ts: now }, now });
  assert.equal(wp.calls.length, 1);
  assert.deepEqual(Object.keys(db.tree().pairs[CODE].devices.lulu).sort(), ["fresh", "odd"]);
  assert.ok(db.tree().pairs[CODE].devices.lumei.other, "only the recipient seat is read / pruned");
});

test("index: a seat is listed while one of its subscriptions wants eye drops", async () => {
  const db = fakeDb({ pairs: { [CODE]: { push: { lulu: { a: sub(), b: sub({ prefs: { eyedrops: true } }) } } } } });
  assert.equal(await updateIndex({ db, code: CODE, seat: "lulu" }), true);
  assert.equal(db.tree().pushIndex[CODE].lulu, true);
  await db.update({ [`pairs/${CODE}/push/lulu/b`]: null });
  assert.equal(await updateIndex({ db, code: CODE, seat: "lulu" }), false);
  assert.equal(db.tree().pushIndex?.[CODE]?.lulu, undefined);
  assert.equal(await updateIndex({ db, code: "nope", seat: "lulu" }), false);
});

function eyeTree({ presence = null, days = {}, subs = null, settings = {} } = {}) {
  return {
    pushIndex: { [CODE]: { lulu: true } },
    pairs: { [CODE]: {
      push: { lulu: subs ?? { a: sub({ prefs: { eyedrops: true } }) } },
      presence: presence ? { lulu: presence } : {},
      tools: { lulu: { eyedrops: {
        settings: { enabled: true, times: ["08:00", "12:00", "16:00", "21:00"], notify: true, at: at("07:00", "2026-10-01"), device: "mac-1", ...settings },
        days,
      } } },
    } },
  };
}

test("eye drops: pushed at 0 / 15 / 30 minutes, then never again for that slot", async () => {
  const db = fakeDb(eyeTree());
  const wp = fakeWebpush();
  const pushedAt = [];
  for (let t = at("11:50"); t <= at("14:10"); t += MIN) {
    const before = wp.calls.length;
    await runEyedrops({ db, webpush: wp, vapid: VAPID, now: t });
    if (wp.calls.length > before) pushedAt.push((t - at("12:00")) / MIN);
  }
  assert.deepEqual(pushedAt, [0, 15, 30]);
  assert.deepEqual(wp.calls[0].payload, { v: 1, kind: "eyedrops", title: "👁️💧 眼药水", body: "该滴眼药水啦（12:00 · 今天第 2 次）", tag: "eyedrops", slot: "2026-10-12/1200" });
  assert.equal(wp.calls[0].opts.topic, "eyedrops");
  assert.equal(wp.calls[0].opts.TTL, 900);
  assert.deepEqual(db.tree().pairs[CODE].tools.lulu.eyedrops.pushed[D]["1200"], { shown: 3, next: at("12:45"), at: at("12:30") });
});

test("eye drops: a check-in on any device stops the nag", async () => {
  const db = fakeDb(eyeTree());
  const wp = fakeWebpush();
  await runEyedrops({ db, webpush: wp, vapid: VAPID, now: at("08:00") });
  assert.equal(wp.calls.length, 1);
  await db.update({ [`pairs/${CODE}/tools/lulu/eyedrops/days/${D}/0800`]: { done: at("08:05"), device: "mac-1" } });
  for (let t = at("08:01"); t <= at("09:00"); t += MIN) await runEyedrops({ db, webpush: wp, vapid: VAPID, now: t });
  assert.equal(wp.calls.length, 1);
});

test("eye drops: not pushed while another device of the seat is actively used; pushed once it goes idle", async () => {
  const tree = eyeTree({ presence: { lastSeen: at("15:59"), device: "mac-1" } });
  tree.pairs[CODE].devices = { lulu: { "mac-1": { kind: "mac", activeAt: at("15:59"), at: at("15:59") } } };
  const db = fakeDb(tree);
  const wp = fakeWebpush();
  const r = await eyedropsForSeat({ db, webpush: wp, vapid: VAPID, code: CODE, seat: "lulu", now: at("16:00") });
  assert.equal(r.result, "present");
  assert.equal(db.tree().pairs[CODE].tools.lulu.eyedrops.pushed, undefined, "nothing recorded when nothing pushed");
  // Mac still online (presence fresh) but nobody touched it for > 3 minutes → the phone is pushed
  await db.update({ [`pairs/${CODE}/presence/lulu/lastSeen`]: at("16:02") });
  const r2 = await eyedropsForSeat({ db, webpush: wp, vapid: VAPID, code: CODE, seat: "lulu", now: at("16:03") });
  assert.equal(r2.result, "sent");
  assert.equal(r2.shown, 1);
  // prefs onlyWhenAway false = 「不管在不在电脑前」
  const tree2 = eyeTree({ subs: { a: sub({ prefs: { eyedrops: true, onlyWhenAway: false } }) } });
  tree2.pairs[CODE].devices = structuredClone(tree.pairs[CODE].devices);
  assert.equal((await eyedropsForSeat({ db: fakeDb(tree2), webpush: wp, vapid: VAPID, code: CODE, seat: "lulu", now: at("16:00") })).result, "sent");
  // an old Mac online without records doesn't hold it back
  const db3 = fakeDb(eyeTree({ presence: { lastSeen: at("15:59"), device: "mac-1" } }));
  assert.equal((await eyedropsForSeat({ db: db3, webpush: wp, vapid: VAPID, code: CODE, seat: "lulu", now: at("16:00") })).result, "sent");
  // the phone's own app open on screen → not pushed (its page nags itself)
  const tree4 = eyeTree();
  tree4.pairs[CODE].devices = { lulu: { "web-phone": { kind: "phone", activeAt: at("15:59"), at: at("15:59"), vis: "visible" } } };
  assert.equal((await eyedropsForSeat({ db: fakeDb(tree4), webpush: wp, vapid: VAPID, code: CODE, seat: "lulu", now: at("16:00") })).result, "present");
});

test("eye drops: off / no eye-drop subscription / no time zone / slot before the settings change", async () => {
  const wp = fakeWebpush();
  const run = (tree, now = at("12:00")) => eyedropsForSeat({ db: fakeDb(tree), webpush: wp, vapid: VAPID, code: CODE, seat: "lulu", now });
  assert.equal((await run(eyeTree({ settings: { enabled: false } }))).result, "off");
  assert.equal((await run(eyeTree({ subs: { a: sub() } }))).result, "no-subs");
  assert.equal((await run(eyeTree({ subs: { a: sub({ tz: "", prefs: { eyedrops: true } }) } }))).result, "no-tz");
  assert.equal((await run(eyeTree({ settings: { at: at("12:30") } }), at("12:31"))).result, "none");
  assert.equal(wp.calls.length, 0);
});

test("eye drops: old pushed days are cleaned up; a late-evening slot is nagged after midnight", async () => {
  const tree = eyeTree({ settings: { times: ["23:50"] } });
  tree.pairs[CODE].tools.lulu.eyedrops.pushed = { "2026-10-01": { "2350": { shown: 3, next: 1, at: 1 } } };
  const db = fakeDb(tree);
  const wp = fakeWebpush();
  await runEyedrops({ db, webpush: wp, vapid: VAPID, now: at("23:50") });
  await runEyedrops({ db, webpush: wp, vapid: VAPID, now: at("00:05", "2026-10-13") });
  assert.equal(wp.calls.length, 2);
  const pushed = db.tree().pairs[CODE].tools.lulu.eyedrops.pushed;
  assert.deepEqual(Object.keys(pushed), [D]);
  assert.equal(pushed[D]["2350"].shown, 2);
});

test("eye drops: gone subscriptions removed; one broken seat doesn't stop the others", async () => {
  const tree = eyeTree({ subs: { a: sub({ endpoint: "https://p/gone", prefs: { eyedrops: true } }) } });
  tree.pushIndex.ZZZZZZZZZZZZZZZZZZZZZZZZ = { lulu: true };
  tree.pairs.ZZZZZZZZZZZZZZZZZZZZZZZZ = { push: { lulu: { a: sub({ prefs: { eyedrops: true } }) } }, tools: { lulu: { eyedrops: { settings: { enabled: true, times: ["12:00"], at: 0 } } } } };
  const db = fakeDb(tree);
  const orig = db.get;
  db.get = async (p) => { if (p.startsWith("pairs/ZZZ") && p.endsWith("/presence/lulu")) throw new Error("boom"); return orig(p); };
  const wp = fakeWebpush((e) => (e === "https://p/gone" ? 410 : null));
  const out = await runEyedrops({ db, webpush: wp, vapid: VAPID, now: at("12:00") });
  assert.deepEqual(out.map((r) => r.result), ["sent", "error"]);
  assert.deepEqual(db.tree().pairs[CODE].push.lulu, {});
});
