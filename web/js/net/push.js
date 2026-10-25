// Web Push subscription for phone / background reminders (spec docs/superpowers/specs/2026-10-22-web-push.md).
// The browser's push subscription is stored at /pairs/{code}/push/{seat}/{subId}; Cloud Functions (functions/) push
// TA's messages and my eye drops to it while I'm away from the Mac / this page. sw.js shows them.
//
//   const push = createPush({config, deviceId, store});
//   push.support()             → "ok" | "no-key" | "ios-install" | "unsupported"
//   push.status()              → {on, prefs}
//   await push.enable(prefs?)  → needs a user gesture (permission prompt); throws Error with a Chinese message
//   await push.disable()
//   await push.setPrefs(patch)
//   await push.refresh()       → at startup: re-stores a renewed subscription, forgets a lost one ("lost" | "ok" | "off")
//   push.watchVisibility()     → phones only: `vis` = {hidden, at} so the server pushes while the page is frozen

import { createFirebase } from "./firebase.js";
import { VAPID_PUBLIC_KEY } from "./vapid.js";

export const KEY_PREFIX = 16;
export const DEFAULT_PREFS = Object.freeze({ messages: true, reminders: true, eyedrops: true, onlyWhenAway: true, dnd: "silent" });
const STORE_KEY = "push";

/** base64url → Uint8Array (applicationServerKey). */
export function keyBytes(b64url) {
  const s = String(b64url).replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(s + "=".repeat((4 - (s.length % 4)) % 4));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

/** iPhone / iPad (iPadOS reports a Mac with touch). */
export function isIOS(nav) {
  return /iPhone|iPad|iPod/.test(nav?.userAgent ?? "") || (nav?.platform === "MacIntel" && nav?.maxTouchPoints > 1);
}

/** A phone / tablet: its page is frozen in the background, so `vis` tells the server to push anyway. */
export function isPhoneDevice(nav) {
  return nav?.userAgentData?.mobile === true || isIOS(nav) || /Android|Mobile/.test(nav?.userAgent ?? "");
}

/** What the settings section can offer. iOS only has Web Push in a home-screen app (iOS 16.4+). */
export function supportOf({ key, nav, standalone, hasPush }) {
  if (!key) return "no-key";
  if (isIOS(nav) && !standalone) return "ios-install";
  return hasPush ? "ok" : "unsupported";
}

/** Prefs with only known fields / values. */
export function cleanPrefs(p) {
  const o = { ...DEFAULT_PREFS, ...(p && typeof p === "object" ? p : {}) };
  return { messages: o.messages !== false, reminders: o.reminders !== false, eyedrops: o.eyedrops === true,
    onlyWhenAway: o.onlyWhenAway !== false, dnd: o.dnd === "skip" ? "skip" : "silent" };
}

/** The record stored for the server (functions/src/rules.js decodeSub). No pair code: it's in the path already. */
export function subscriptionRecord({ json, deviceId, phone, tz, ua, prefs, now, key }) {
  return {
    endpoint: json.endpoint,
    keys: { p256dh: json.keys.p256dh, auth: json.keys.auth },
    device: deviceId,
    phone: !!phone,
    tz: typeof tz === "string" ? tz.slice(0, 64) : "",
    ua: String(ua ?? "").slice(0, 64),
    at: now,
    key: String(key).slice(0, KEY_PREFIX),
    prefs: cleanPrefs(prefs),
  };
}

/** Stable id per browser subscription: first 20 hex chars of SHA-256(endpoint). */
export async function subIdFor(endpoint) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(endpoint));
  return Array.from(new Uint8Array(d).slice(0, 10), (b) => b.toString(16).padStart(2, "0")).join("");
}

function shortUA(nav) {
  const ua = nav?.userAgent ?? "";
  const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac OS X/.test(ua) ? "macOS" : /Windows/.test(ua) ? "Windows" : "other";
  const br = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome" : /Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : "browser";
  return `${br} · ${os}`;
}

export function createPush({ config, deviceId, store, fetch, key = VAPID_PUBLIC_KEY, nav = globalThis.navigator, now = () => Date.now() }) {
  const fb = createFirebase({ databaseURL: config.databaseURL, pairCode: config.pairCode, fetch });
  const path = (id) => `push/${config.seat}/${id}`;
  const saved = () => { const s = store.get(STORE_KEY, null); return s && typeof s.subId === "string" ? s : null; };
  const save = (s) => (s ? store.set(STORE_KEY, s) : store.remove(STORE_KEY));
  const tz = () => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone; } catch { return ""; } };
  let watching = false;

  async function registration() {
    if (!nav?.serviceWorker) throw new Error("这个浏览器不支持推送");
    const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error("后台服务还没准备好，刷新页面再试")), 10_000));
    return Promise.race([nav.serviceWorker.ready, timeout]);
  }

  async function store1(sub, prefs) {
    const json = sub.toJSON();
    const subId = await subIdFor(json.endpoint);
    const rec = subscriptionRecord({ json, deviceId, phone: isPhoneDevice(nav), tz: tz(), ua: shortUA(nav), prefs, now: now(), key });
    await fb.put(path(subId), rec);
    const old = saved();
    if (old && old.subId !== subId) await fb.del(path(old.subId)).catch(() => {});
    save({ subId, endpoint: json.endpoint, key: rec.key, prefs: rec.prefs });
    return subId;
  }

  async function subscribe(reg) {
    return reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(key) });
  }

  return {
    support() {
      const standalone = typeof matchMedia === "function" && matchMedia("(display-mode: standalone)").matches || nav?.standalone === true;
      const hasPush = typeof globalThis.PushManager === "function" && !!nav?.serviceWorker && typeof globalThis.Notification === "function";
      return supportOf({ key, nav, standalone, hasPush });
    },

    status() {
      const s = saved();
      return { on: !!s, prefs: cleanPrefs(s?.prefs) };
    },

    async enable(prefs = DEFAULT_PREFS) {
      if (Notification.permission !== "granted") {
        const p = await Notification.requestPermission().catch(() => Notification.permission);
        if (p !== "granted") throw new Error(p === "denied" ? "通知被拒绝了：在系统 / 浏览器设置里允许这个网站的通知" : "没有允许通知");
      }
      const reg = await registration();
      let sub = await reg.pushManager.getSubscription();
      if (sub && sub.options?.applicationServerKey) {
        const have = new Uint8Array(sub.options.applicationServerKey);
        const want = keyBytes(key);
        if (have.length !== want.length || have.some((b, i) => b !== want[i])) { await sub.unsubscribe().catch(() => {}); sub = null; }
      }
      sub = sub ?? await subscribe(reg);
      await store1(sub, prefs);
      this.watchVisibility();
    },

    async disable() {
      const s = saved();
      save(null);
      try { const reg = await registration(); await (await reg.pushManager.getSubscription())?.unsubscribe(); } catch { /* gone already */ }
      if (s) await fb.del(path(s.subId)).catch(() => {});
    },

    async setPrefs(patch) {
      const s = saved();
      if (!s) return;
      const prefs = cleanPrefs({ ...s.prefs, ...patch });
      save({ ...s, prefs });
      await fb.put(`${path(s.subId)}/prefs`, prefs);   // PUT prefs → the server re-indexes eye-drop seats
    },

    async refresh() {
      const s = saved();
      if (!s || !key) return "off";
      try {
        const reg = await registration();
        let sub = await reg.pushManager.getSubscription();
        if (sub && s.key !== String(key).slice(0, KEY_PREFIX)) { await sub.unsubscribe().catch(() => {}); sub = null; }
        if (!sub && Notification.permission === "granted") sub = await subscribe(reg).catch(() => null);
        if (!sub) {
          save(null);
          await fb.del(path(s.subId)).catch(() => {});
          return "lost";
        }
        if (sub.endpoint !== s.endpoint || s.key !== String(key).slice(0, KEY_PREFIX)) await store1(sub, s.prefs);
        this.watchVisibility();
        return "ok";
      } catch {
        return "ok";   // offline / no service worker yet: try again next start
      }
    },

    watchVisibility() {
      if (watching || !isPhoneDevice(nav) || typeof document === "undefined") return;
      watching = true;
      const send = () => {
        const s = saved();
        if (!s) return;
        fb.put(`${path(s.subId)}/vis`, { hidden: document.visibilityState === "hidden", at: now() }, { keepalive: true }).catch(() => {});
      };
      document.addEventListener("visibilitychange", send);
      send();
    },
  };
}
