// Per-device activity records: js/core/devices.js (schema, shared with functions/ via vendor) and js/net/devices.js
// (throttled writer, kind detection, DOM / IdleDetector wiring).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ACTIVE_WINDOW_MS, HEARTBEAT_MS, INPUT_WRITE_MS, STALE_MS, VISIBLE_FRESH_MS, decodeDevice, decodeDevices, deviceRecord,
  isActivelyUsed, isVisibleNow, staleDeviceIds,
} from "../js/core/devices.js";
import { TICK_MS, createActivityWriter, deviceKind, startDeviceActivity } from "../js/net/devices.js";

const IPHONE = { userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Version/17.4 Mobile/15E148 Safari/604.1", maxTouchPoints: 5, platform: "iPhone" };
const MAC_CHROME = { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0 Safari/537.36", maxTouchPoints: 0, platform: "MacIntel" };
const NOW = 1_791_900_000_000;

test("core: constants, record encoding / decoding, activity windows", () => {
  assert.equal(ACTIVE_WINDOW_MS, 180_000);
  assert.equal(VISIBLE_FRESH_MS, 90_000);
  assert.equal(INPUT_WRITE_MS, 60_000);
  assert.equal(HEARTBEAT_MS, 300_000);
  assert.equal(STALE_MS, 7 * 86_400_000);
  assert.deepEqual(deviceRecord({ kind: "phone", activeAt: 5.7, at: 9, vis: "hidden" }), { kind: "phone", activeAt: 5, at: 9, vis: "hidden" });
  assert.deepEqual(deviceRecord({ kind: "toaster", activeAt: -1, at: 9, vis: "maybe" }), { kind: "web", activeAt: 0, at: 9 });
  assert.equal(decodeDevice("a", { kind: "mac" }), null);
  assert.equal(decodeDevice("a", 7), null);
  assert.deepEqual(decodeDevice("a", { kind: "watch", activeAt: "x", at: 3, extra: 1 }), { id: "a", kind: "watch", activeAt: 0, at: 3, vis: null });
  const node = { b: { kind: "mac", activeAt: 1, at: NOW - 1000 }, a: { kind: "web", activeAt: 1, at: NOW - STALE_MS - 1 }, c: "junk" };
  assert.deepEqual(decodeDevices(node, NOW).map((d) => d.id), ["b"]);
  assert.deepEqual(staleDeviceIds(node, NOW), ["a"]);
  const r = (activeAt, at = NOW, vis) => decodeDevice("x", { kind: "web", activeAt, at, vis });
  assert.equal(isActivelyUsed(r(NOW - ACTIVE_WINDOW_MS), NOW), true);
  assert.equal(isActivelyUsed(r(NOW - ACTIVE_WINDOW_MS - 1), NOW), false);
  assert.equal(isActivelyUsed(r(0), NOW), false);
  assert.equal(isActivelyUsed(r(NOW + 3_600_000), NOW), false);
  assert.equal(isVisibleNow(r(0, NOW - VISIBLE_FRESH_MS, "visible"), NOW), true);
  assert.equal(isVisibleNow(r(0, NOW - VISIBLE_FRESH_MS - 1, "visible"), NOW), false);
  assert.equal(isVisibleNow(r(0, NOW, "hidden"), NOW), false);
  assert.equal(isVisibleNow(r(0, NOW), NOW), false);
});

test("kind: iOS home-screen app or coarse pointer + small screen = phone; desktops = web", () => {
  const mm = (coarse) => (q) => ({ matches: q === "(pointer: coarse)" ? coarse : false });
  assert.equal(deviceKind({ nav: IPHONE, matchMedia: mm(true), screen: { width: 390, height: 844 }, standalone: true }), "phone");
  assert.equal(deviceKind({ nav: IPHONE, matchMedia: null, screen: null, standalone: true }), "phone");
  assert.equal(deviceKind({ nav: IPHONE, matchMedia: mm(true), screen: { width: 390, height: 844 }, standalone: false }), "phone");
  assert.equal(deviceKind({ nav: { userAgent: "Android" }, matchMedia: mm(true), screen: { width: 900, height: 412 }, standalone: false }), "phone");
  assert.equal(deviceKind({ nav: MAC_CHROME, matchMedia: mm(false), screen: { width: 1512, height: 982 }, standalone: true }), "web");
  assert.equal(deviceKind({ nav: { userAgent: "tablet" }, matchMedia: mm(true), screen: { width: 1180, height: 820 }, standalone: false }), "web");
});

function clock(t = NOW) {
  return { now: () => t, add: (ms) => { t += ms; }, at: () => t };
}

test("writer: input throttled to one write a minute, trailing write catches up, heartbeat every 5 minutes", () => {
  const c = clock();
  const writes = [];
  const w = createActivityWriter({ kind: "web", now: c.now, visible: true, write: (rec, keepalive) => writes.push({ ...rec, keepalive }) });
  w.start();
  assert.deepEqual(writes, [{ kind: "web", activeAt: NOW, at: NOW, vis: "visible", keepalive: false }]);
  for (let i = 0; i < 59; i++) { c.add(1000); w.input(); }             // a minute of mouse moves
  assert.equal(writes.length, 1);
  c.add(1000); w.input();                                              // 60 s after the last write
  assert.equal(writes.length, 2);
  assert.equal(writes[1].activeAt, NOW + 60_000);
  c.add(10_000); w.input();                                            // throttled …
  c.add(5_000); w.tick();
  assert.equal(writes.length, 2);
  c.add(45_000); w.tick();                                             // … the trailing write carries it
  assert.equal(writes.length, 3);
  assert.equal(writes[2].activeAt, NOW + 70_000);
  // idle: nothing until the heartbeat (activeAt unchanged, at moves on)
  for (let i = 0; i < 4; i++) { c.add(TICK_MS); w.tick(); }
  assert.equal(writes.length, 3);
  c.add(TICK_MS); w.tick();
  assert.equal(writes.length, 4);
  assert.equal(writes[3].activeAt, NOW + 70_000);
  assert.equal(writes[3].at, c.at());
});

test("writer: visibility writes at once (keepalive when hiding); showing counts as input; a hidden start has no input", () => {
  const c = clock();
  const writes = [];
  const w = createActivityWriter({ kind: "phone", now: c.now, visible: false, write: (rec, keepalive) => writes.push({ ...rec, keepalive }) });
  w.start();
  assert.deepEqual(writes[0], { kind: "phone", activeAt: 0, at: NOW, vis: "hidden", keepalive: false });
  c.add(1000); w.visibility("visible");
  assert.deepEqual(writes[1], { kind: "phone", activeAt: NOW + 1000, at: NOW + 1000, vis: "visible", keepalive: false });
  c.add(1000); w.visibility("hidden");                                 // not throttled
  assert.deepEqual(writes[2], { kind: "phone", activeAt: NOW + 1000, at: NOW + 2000, vis: "hidden", keepalive: true });
});

/** A document / window stand-in with listeners; fetch records REST calls. */
function env({ hidden = false, idle = null, nav = MAC_CHROME } = {}) {
  const doc = new EventTarget();
  doc.visibilityState = hidden ? "hidden" : "visible";
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ method: init.method, path: new URL(url).pathname, body: JSON.parse(init.body), keepalive: !!init.keepalive });
    return { ok: true, status: 200, text: async () => init.body };
  };
  let tick = null;
  const win = {
    matchMedia: () => ({ matches: false }),
    screen: { width: 1512, height: 982 },
    ...(idle ? { IdleDetector: function IdleDetector() { return idle; } } : {}),
  };
  const navi = { ...nav, permissions: { query: async () => ({ state: idle ? "granted" : "prompt" }) } };
  return { doc, win, nav: navi, fetch, calls, setInterval: (fn) => { tick = fn; return 1; }, clearInterval: () => { tick = null; }, tick: () => tick?.() };
}

const CONFIG = { databaseURL: "https://example.invalid", pairCode: "TESTDEVICESXXXXXXXXXXXXX", seat: "lumei" };
const flush = () => new Promise((r) => setTimeout(r, 0));

test("startDeviceActivity: PUTs devices/{seat}/{deviceId}; input on the page; visibility; stop", async () => {
  const c = clock();
  const e = env();
  const a = startDeviceActivity({ config: CONFIG, deviceId: "web-abc", fetch: e.fetch, doc: e.doc, win: e.win, nav: e.nav, now: c.now,
    setInterval: e.setInterval, clearInterval: e.clearInterval });
  await flush();
  assert.equal(e.calls.length, 1);
  assert.equal(e.calls[0].method, "PUT");
  assert.equal(e.calls[0].path, `/pairs/${CONFIG.pairCode}/devices/lumei/web-abc.json`);
  assert.deepEqual(e.calls[0].body, { kind: "web", activeAt: NOW, at: NOW, vis: "visible" });
  c.add(61_000);
  e.doc.dispatchEvent(new Event("keydown"));
  await flush();
  assert.equal(e.calls.length, 2);
  assert.equal(e.calls[1].body.activeAt, NOW + 61_000);
  c.add(1000);
  e.doc.visibilityState = "hidden";
  e.doc.dispatchEvent(new Event("visibilitychange"));
  await flush();
  assert.deepEqual(e.calls[2].body, { kind: "web", activeAt: NOW + 61_000, at: NOW + 62_000, vis: "hidden" });
  assert.equal(e.calls[2].keepalive, true);
  a.stop();
  c.add(600_000);
  e.doc.dispatchEvent(new Event("pointerdown"));
  e.tick();
  await flush();
  assert.equal(e.calls.length, 3);
});

test("startDeviceActivity: hidden tab + IdleDetector active (granted) counts as in use; locked screen doesn't", async () => {
  const c = clock();
  const idle = Object.assign(new EventTarget(), { userState: "active", screenState: "unlocked", start: async () => {} });
  const e = env({ hidden: true, idle });
  startDeviceActivity({ config: CONFIG, deviceId: "web-abc", fetch: e.fetch, doc: e.doc, win: e.win, nav: e.nav, now: c.now,
    setInterval: e.setInterval, clearInterval: e.clearInterval });
  await flush(); await flush();
  assert.deepEqual(e.calls[0].body, { kind: "web", activeAt: 0, at: NOW, vis: "hidden" });
  c.add(TICK_MS); e.tick();
  await flush();
  assert.equal(e.calls.length, 2);
  assert.equal(e.calls[1].body.activeAt, NOW + TICK_MS);
  idle.screenState = "locked";
  for (let i = 0; i < 4; i++) { c.add(TICK_MS); e.tick(); }
  await flush();
  assert.equal(e.calls.length, 2, "locked: no input, heartbeat not due yet");
  // without the permission a hidden tab is only "open", never "in use"
  const e2 = env({ hidden: true });
  startDeviceActivity({ config: CONFIG, deviceId: "web-x", fetch: e2.fetch, doc: e2.doc, win: e2.win, nav: e2.nav, now: c.now,
    setInterval: e2.setInterval, clearInterval: e2.clearInterval });
  await flush();
  for (let i = 0; i < 5; i++) { c.add(TICK_MS); e2.tick(); }
  await flush();
  assert.deepEqual(e2.calls.map((x) => x.body.activeAt), [0, 0]);
});

test("startDeviceActivity: an iPhone home-screen app writes kind phone", async () => {
  const e = env({ nav: { ...IPHONE, standalone: true } });
  startDeviceActivity({ config: CONFIG, deviceId: "web-p", fetch: e.fetch, doc: e.doc, win: e.win, nav: e.nav, now: () => NOW,
    setInterval: e.setInterval, clearInterval: e.clearInterval });
  await flush();
  assert.equal(e.calls[0].body.kind, "phone");
});
