// Web Push client (js/net/push.js) and the service worker's 'push' / notificationclick (sw.js).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import {
  DEFAULT_PREFS, cleanPrefs, createPush, isIOS, isPhoneDevice, keyBytes, subIdFor, subscriptionRecord, supportOf,
} from "../js/net/push.js";

const KEY = "BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U";
const IPHONE = { userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Version/17.4 Mobile/15E148 Safari/604.1", maxTouchPoints: 5, platform: "iPhone" };
const MAC_CHROME = { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0 Safari/537.36", maxTouchPoints: 0, platform: "MacIntel", userAgentData: { mobile: false } };
const IPAD = { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Version/17.4 Safari/605.1.15", maxTouchPoints: 5, platform: "MacIntel" };

test("helpers: key bytes, device kind, support, prefs, record", async () => {
  const b = keyBytes(KEY);
  assert.equal(b.length, 65);
  assert.equal(b[0], 4);
  assert.equal(isIOS(IPHONE), true);
  assert.equal(isIOS(IPAD), true);
  assert.equal(isIOS(MAC_CHROME), false);
  assert.equal(isPhoneDevice(IPHONE), true);
  assert.equal(isPhoneDevice(MAC_CHROME), false);
  assert.equal(isPhoneDevice({ userAgent: "Mozilla/5.0 (Linux; Android 14) Chrome/130 Mobile Safari/537.36" }), true);
  assert.equal(supportOf({ key: "", nav: MAC_CHROME, standalone: false, hasPush: true }), "no-key");
  assert.equal(supportOf({ key: KEY, nav: IPHONE, standalone: false, hasPush: false }), "ios-install");
  assert.equal(supportOf({ key: KEY, nav: IPHONE, standalone: true, hasPush: true }), "ok");
  assert.equal(supportOf({ key: KEY, nav: MAC_CHROME, standalone: false, hasPush: false }), "unsupported");
  assert.deepEqual(cleanPrefs(null), DEFAULT_PREFS);
  assert.deepEqual(cleanPrefs({ messages: 0, dnd: "loud", junk: 1 }), { messages: true, reminders: true, eyedrops: true, onlyWhenAway: true, dnd: "silent" });
  assert.deepEqual(cleanPrefs({ messages: false, dnd: "skip" }).dnd, "skip");
  const rec = subscriptionRecord({ json: { endpoint: "https://push.example.invalid/x", keys: { p256dh: "p", auth: "a" } }, deviceId: "web-1",
    phone: true, tz: "Asia/Shanghai", ua: "Safari · iOS", prefs: {}, now: 5, key: KEY });
  assert.deepEqual(rec, { endpoint: "https://push.example.invalid/x", keys: { p256dh: "p", auth: "a" }, device: "web-1", phone: true,
    tz: "Asia/Shanghai", ua: "Safari · iOS", at: 5, key: KEY.slice(0, 16), prefs: DEFAULT_PREFS });
  const id = await subIdFor("https://push.example.invalid/x");
  assert.match(id, /^[0-9a-f]{20}$/);
  assert.equal(id, await subIdFor("https://push.example.invalid/x"));
});

/** Browser stand-ins: a push manager, Notification, a fetch that records REST calls. */
function browser({ permission = "granted", endpoint = "https://push.example.invalid/sub-1" } = {}) {
  const calls = [];
  let current = null;
  const mkSub = (ep) => ({
    endpoint: ep,
    options: { applicationServerKey: keyBytes(KEY).buffer },
    toJSON: () => ({ endpoint: ep, keys: { p256dh: "pk", auth: "ak" } }),
    unsubscribe: async () => { current = null; return true; },
  });
  const pushManager = {
    getSubscription: async () => current,
    subscribe: async (opts) => { assert.equal(opts.userVisibleOnly, true); current = mkSub(endpoint); return current; },
  };
  const nav = { ...IPHONE, serviceWorker: { ready: Promise.resolve({ pushManager }) } };
  globalThis.Notification = { permission, requestPermission: async () => permission };
  const fetch = async (url, init) => {
    calls.push({ method: init.method, path: new URL(url).pathname.replace(/^\/pairs\/[^/]+\//, ""), body: init.body ? JSON.parse(init.body) : undefined });
    return { ok: true, status: 200, text: async () => init.body ?? "null" };
  };
  const mem = new Map();
  const store = { get: (k, f = null) => (mem.has(k) ? structuredClone(mem.get(k)) : f), set: (k, v) => mem.set(k, structuredClone(v)), remove: (k) => mem.delete(k) };
  return { calls, nav, fetch, store, pushManager, setEndpoint: (e) => { current = mkSub(e); }, drop: () => { current = null; } };
}

const CONFIG = { databaseURL: "http://127.0.0.1:9", pairCode: "ABCDEFGHJKLMNPQRSTUVWXYZ", seat: "lulu" };

test("enable → PUT push/{seat}/{subId}; prefs → PUT …/prefs; disable → DELETE", async () => {
  const b = browser();
  const push = createPush({ config: CONFIG, deviceId: "web-phone", store: b.store, fetch: b.fetch, key: KEY, nav: b.nav, now: () => 42 });
  assert.equal(push.status().on, false);
  await push.enable();
  const id = await subIdFor("https://push.example.invalid/sub-1");
  assert.equal(b.calls[0].method, "PUT");
  assert.equal(b.calls[0].path, `push/lulu/${id}.json`);
  assert.equal(b.calls[0].body.device, "web-phone");
  assert.equal(b.calls[0].body.phone, true);
  assert.equal(b.calls[0].body.key, KEY.slice(0, 16));
  assert.doesNotMatch(JSON.stringify(b.calls[0].body), /ABCDEFGHJKLMNPQRSTUVWXYZ|127\.0\.0\.1/);
  assert.equal(push.status().on, true);

  await push.setPrefs({ eyedrops: false });
  const p = b.calls.at(-1);
  assert.deepEqual([p.method, p.path], ["PUT", `push/lulu/${id}/prefs.json`]);
  assert.equal(p.body.eyedrops, false);
  assert.equal(push.status().prefs.eyedrops, false);

  await push.disable();
  assert.deepEqual([b.calls.at(-1).method, b.calls.at(-1).path], ["DELETE", `push/lulu/${id}.json`]);
  assert.equal(push.status().on, false);
  assert.equal(await b.pushManager.getSubscription(), null);
});

test("enable: permission refused → a Chinese error, nothing stored", async () => {
  const b = browser({ permission: "denied" });
  const push = createPush({ config: CONFIG, deviceId: "web-phone", store: b.store, fetch: b.fetch, key: KEY, nav: b.nav });
  await assert.rejects(push.enable(), /通知被拒绝了/);
  assert.equal(b.calls.length, 0);
  assert.equal(push.status().on, false);
});

test("refresh: renewed endpoint is re-stored (old record deleted); a lost subscription is forgotten", async () => {
  const b = browser();
  const push = createPush({ config: CONFIG, deviceId: "web-phone", store: b.store, fetch: b.fetch, key: KEY, nav: b.nav });
  await push.enable();
  const oldId = await subIdFor("https://push.example.invalid/sub-1");
  b.setEndpoint("https://push.example.invalid/sub-2");
  assert.equal(await push.refresh(), "ok");
  const newId = await subIdFor("https://push.example.invalid/sub-2");
  assert.ok(b.calls.some((c) => c.method === "PUT" && c.path === `push/lulu/${newId}.json`));
  assert.ok(b.calls.some((c) => c.method === "DELETE" && c.path === `push/lulu/${oldId}.json`));

  b.drop();
  globalThis.Notification.permission = "default";   // can't silently subscribe again
  assert.equal(await push.refresh(), "lost");
  assert.equal(push.status().on, false);
  assert.ok(b.calls.some((c) => c.method === "DELETE" && c.path === `push/lulu/${newId}.json`));
});

// ---- sw.js

function loadSW() {
  const listeners = {};
  const shown = [];
  const opened = [];
  const posted = [];
  const clientsList = [];
  const self = {
    registration: {
      scope: "https://app.example.invalid/",
      showNotification: async (title, options) => { shown.push(JSON.parse(JSON.stringify({ title, options }))); },  // out of the vm realm
    },
    location: { origin: "https://app.example.invalid" },
    addEventListener: (type, fn) => { listeners[type] = fn; },
    clients: {
      matchAll: async () => clientsList,
      openWindow: async (u) => { opened.push(u); },
      claim: async () => {},
    },
    skipWaiting: async () => {},
    Notification: { maxActions: 2 },
  };
  const store = new Map();
  const caches = { open: async () => ({ put: async (k, v) => store.set(k, v), match: async () => undefined }), keys: async () => [] };
  vm.runInNewContext(readFileSync(new URL("../sw.js", import.meta.url), "utf8"),
    { self, caches, URL, Response, Promise, JSON, Date, fetch: async () => ({ ok: false }) });
  const fire = async (type, ev) => {
    let p = null;
    listeners[type]({ ...ev, waitUntil: (x) => { p = x; } });
    await p;
  };
  return { fire, shown, opened, posted, clientsList, pending: store };
}

const pushEvent = (obj) => ({ data: { json: () => (typeof obj === "string" ? JSON.parse(obj) : obj) } });

test("sw push: message / partner reminder / eye drops are shown like notify.js, with data.push", async () => {
  const sw = loadSW();
  await sw.fire("push", pushEvent({ v: 1, kind: "message", title: "噜妹说：", body: "在吗", tag: "msg-k1", key: "k1" }));
  await sw.fire("push", pushEvent({ v: 1, kind: "partner-remind", title: "噜妹说：", body: "噜妹叫你喝水啦 💧", tag: "msg-r1", key: "r1", remind: "water", silent: true }));
  await sw.fire("push", pushEvent({ v: 1, kind: "eyedrops", title: "👁️💧 眼药水", body: "该滴眼药水啦（12:00 · 今天第 2 次）", tag: "eyedrops", slot: "2026-10-12/1200" }));
  const [m, r, e] = sw.shown;
  assert.equal(m.title, "噜妹说：");
  assert.equal(m.options.body, "在吗");
  assert.equal(m.options.tag, "msg-k1");
  assert.equal(m.options.actions.length, 0);
  assert.deepEqual({ ...m.options.data }, { kind: "message", key: "k1", remind: null, slot: null, push: true });
  assert.deepEqual(r.options.actions.map((a) => a.title), ["马上", "等会儿"]);
  assert.equal(r.options.silent, true);
  assert.equal(r.options.data.remind, "water");
  assert.deepEqual(e.options.actions.map((a) => a.action), ["done", "later"]);
  assert.equal(e.options.tag, "eyedrops");
  assert.equal(e.options.data.slot, "2026-10-12/1200");
});

test("sw push: a broken payload still shows something (every push must)", async () => {
  const sw = loadSW();
  await sw.fire("push", { data: { json: () => { throw new Error("bad"); } } });
  await sw.fire("push", { data: null });
  assert.equal(sw.shown.length, 2);
  assert.equal(sw.shown[0].title, "噜噜桌宠");
  assert.equal(sw.shown[0].options.body, "有新消息");
});

test("sw click: pushed eye drop 等会儿 opens nothing; 滴了 with no page keeps the action and opens the app", async () => {
  const sw = loadSW();
  const note = (data) => ({ data, close() {} });
  await sw.fire("notificationclick", { action: "later", notification: note({ kind: "eyedrops", slot: "2026-10-12/1200", push: true }) });
  assert.deepEqual(sw.opened, []);
  assert.equal(sw.pending.size, 0);
  await sw.fire("notificationclick", { action: "done", notification: note({ kind: "eyedrops", slot: "2026-10-12/1200", push: true }) });
  assert.deepEqual(sw.opened, ["https://app.example.invalid/"]);
  assert.equal(sw.pending.size, 1);
  // iOS: no buttons — a tap is "open"
  await sw.fire("notificationclick", { action: "", notification: note({ kind: "partner-remind", key: "r1", remind: "water", push: true }) });
  assert.equal(sw.opened.length, 2);
});
