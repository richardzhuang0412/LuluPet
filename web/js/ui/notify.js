// System notifications through the Service Worker (spec §13.4): registration.showNotification with action buttons.
// sw.js answers notificationclick by posting {type:"lulupet-notification", action, data} to the open page, or — when no
// page is open — by keeping it in Cache Storage ("lulupet-pending") and opening the page, which picks it up here.

let reg = null;
const PENDING_CACHE = "lulupet-pending";
const PENDING_URL = new URL("../../pending-action", import.meta.url).href;   // same key sw.js uses (scope + name)

export async function registerSW() {
  if (!("serviceWorker" in navigator)) return null;
  try {
    reg = await navigator.serviceWorker.register(new URL("../../sw.js", import.meta.url), { scope: new URL("../../", import.meta.url).pathname });
  } catch (e) {
    console.warn("[lulu] service worker", e);
  }
  return reg;
}

export const supported = () => "Notification" in window && "serviceWorker" in navigator;
export const permission = () => (supported() ? Notification.permission : "unsupported");

/** Needs a user gesture. Resolves to "granted" / "denied" / "default" / "unsupported". */
export async function requestPermission() {
  if (!supported()) return "unsupported";
  try { return await Notification.requestPermission(); } catch { return Notification.permission; }
}

/**
 * kind:
 * - "message": {title, body, key}
 * - "partner-remind": {title, body, key, remind} → buttons 马上 / 等会儿
 * - "own-remind": {title, body, remind, comply} → buttons 喝了 (好的) / 等会儿
 * - "eyedrops": {title, body, slot} → buttons 滴了 / 等会儿; tag "eyedrops" (the 2nd / 3rd nag replaces it)
 * - "pomodoro": {title, body} → no buttons
 * My own reminders make the system sound (they fire in 勿扰 / 专注 too — user decision); TA's messages are silent.
 */
export async function notify(kind, { title, body, key, remind, comply, slot }) {
  if (permission() !== "granted") return false;
  const r = reg || (await navigator.serviceWorker.getRegistration());
  if (!r) return false;
  const icon = new URL("../../icons/icon-192.png", import.meta.url).href;
  const own = kind === "own-remind" || kind === "eyedrops" || kind === "pomodoro";
  const actions = kind === "partner-remind" ? [{ action: "now", title: "马上" }, { action: "later", title: "等会儿" }]
    : kind === "own-remind" ? [{ action: "done", title: comply || (remind === "water" ? "喝了" : "好的") }, { action: "later", title: "等会儿" }]
      : kind === "eyedrops" ? [{ action: "done", title: "滴了" }, { action: "later", title: "等会儿" }]
        : [];
  const tag = kind === "own-remind" ? "own-" + remind : kind === "eyedrops" ? "eyedrops" : kind === "pomodoro" ? "pomodoro" : key ? "msg-" + key : undefined;
  try {
    await r.showNotification(title, {
      body, icon, badge: icon, actions, silent: !own, tag, renotify: own,
      requireInteraction: kind !== "message" && kind !== "pomodoro",
      data: { kind, key: key ?? null, remind: remind ?? null, slot: slot ?? null },
    });
    return true;
  } catch (e) {
    console.warn("[lulu] notification", e);
    return false;
  }
}

/** App icon badge (installed app) — unread count; 0 clears. */
export function setBadge(n) {
  try {
    const p = n > 0 ? navigator.setAppBadge?.(n) : navigator.clearAppBadge?.();
    p?.catch?.(() => {});
  } catch { /* unsupported */ }
}

/** Closes the notification for a message answered on the page. */
export async function closeFor(tag) {
  if (!("serviceWorker" in navigator)) return;
  const r = reg || (await navigator.serviceWorker.getRegistration());
  if (!r) return;
  for (const n of await r.getNotifications({ tag })) n.close();
}

/** handler({action, data}) for clicks while the page is open. */
export function onAction(handler) {
  navigator.serviceWorker?.addEventListener("message", (e) => {
    if (e.data?.type === "lulupet-notification") handler(e.data);
  });
}

/** A click that happened while no page was open (sw.js stored it, then opened us). Taken once. */
export async function takePending() {
  if (!("caches" in window)) return null;
  try {
    const c = await caches.open(PENDING_CACHE);
    const r = await c.match(PENDING_URL);
    if (!r) return null;
    await c.delete(PENDING_URL);
    const p = await r.json();
    return Date.now() - (p.at || 0) < 10 * 60_000 ? p : null;
  } catch { return null; }
}
