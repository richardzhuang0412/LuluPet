// 噜噜 web service worker (v1 spec §7.4 / §13.4, v2 spec §2.7 / §5).
// - Shell (html / js / css / manifests / version.json / assets/manifest.json): network first with HTTP revalidation,
//   cache when offline. The shell is also pre-cached on install so the installed app opens offline.
// - Everything else under assets/ (sprites, stickers, sounds — manifest v2 file names carry a content hash): cache
//   first, kept forever. Files that a newer assets/manifest.json no longer names are dropped on the next activate.
// - Cross-origin requests (Firebase, Open-Meteo) are never touched.
// - Notification buttons: post {type:"lulupet-notification", action, data} to the open page(s); with no page open,
//   keep the click in Cache Storage and open the page, which takes it (js/ui/notify.js takePending).
//   kinds: message · partner-remind (马上 / 等会儿) · own-remind (喝了 / 好的 · 等会儿) · eyedrops (滴了 / 等会儿) · pomodoro.
//   Dismissing my own reminder (own-remind / eyedrops) is posted as action "close" (= 喝了 for water / stand, the Mac
//   bubble rule; = 等会儿 for eye drops: the nag comes back in 15 minutes).

const SHELL = "lulupet-shell-v2";
const ASSETS = "lulupet-assets-v2";
const PENDING = "lulupet-pending";
const PENDING_URL = new URL("pending-action", self.registration.scope).href;
const SHELL_FILES = ["./", "index.html", "css/app.css", "css/pip.css", "js/app.js", "manifest.webmanifest",
  "icons/icon-192.png", "icons/favicon-32.png"];

const scopePath = new URL(self.registration.scope).pathname;
const isHashed = (path) => path.startsWith(scopePath + "assets/") && path !== scopePath + "assets/manifest.json"
  && path !== scopePath + "assets/README.md";

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL);
    await Promise.all(SHELL_FILES.map((f) => cache.add(new Request(new URL(f, self.registration.scope), { cache: "no-cache" })).catch(() => {})));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keep = new Set([SHELL, ASSETS, PENDING]);
    for (const k of await caches.keys()) {
      if (!k.startsWith("lulupet-") || keep.has(k)) continue;
      if (k === "lulupet-assets-v1") await migrateAssets(k);
      await caches.delete(k);
    }
    await pruneAssets();
    await self.clients.claim();
  })());
});

/** v1 → v2: hashed sprite / sticker files keep their names, so they move over instead of downloading again. */
async function migrateAssets(old) {
  try {
    const from = await caches.open(old), to = await caches.open(ASSETS);
    for (const req of await from.keys()) { const r = await from.match(req); if (r) await to.put(req, r); }
  } catch { /* best effort */ }
}

/** Drops cached asset files the current manifest no longer references (each asset is downloaded once per device). */
async function pruneAssets() {
  try {
    const r = await fetch(new URL("assets/manifest.json", self.registration.scope), { cache: "no-cache" });
    if (!r.ok) return;
    const text = await r.text();
    const cache = await caches.open(ASSETS);
    for (const req of await cache.keys()) {
      const name = new URL(req.url).pathname.split("/").pop();
      if (name && !text.includes(name)) await cache.delete(req);
    }
  } catch { /* offline: next time */ }
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET" || req.headers.has("range")) return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith(scopePath)) return;
  if ((req.headers.get("accept") || "").includes("text/event-stream")) return;
  if (url.pathname === scopePath + "pending-action") return;
  event.respondWith(isHashed(url.pathname) ? cacheFirst(req) : networkFirst(req));
});

async function cacheFirst(req) {
  const cache = await caches.open(ASSETS);
  const hit = await cache.match(req, { ignoreSearch: true });
  if (hit) return hit;
  const res = await fetch(req);
  if (res.ok && res.type === "basic") cache.put(req, res.clone());
  return res;
}

async function networkFirst(req) {
  const cache = await caches.open(SHELL);
  try {
    const res = await fetch(req, { cache: "no-cache" });
    if (res.ok && res.type === "basic") cache.put(req, res.clone());
    return res;
  } catch (err) {
    const hit = await cache.match(req, { ignoreSearch: req.mode === "navigate" });
    if (hit) return hit;
    if (req.mode === "navigate") {
      const index = await cache.match(scopePath) || await cache.match(scopePath + "index.html");
      if (index) return index;
    }
    throw err;
  }
}

async function windows() {
  const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
  return all.filter((c) => new URL(c.url).pathname.startsWith(scopePath));
}

async function deliver(payload, focus) {
  const list = await windows();
  if (list.length) {
    for (const c of list) c.postMessage(payload);
    if (focus) {
      const c = list.find((x) => x.focused) || list[0];
      try { await c.focus(); } catch { /* not allowed */ }
    }
    return;
  }
  if (payload.action !== "open" && payload.action !== "close") {
    const cache = await caches.open(PENDING);
    await cache.put(PENDING_URL, new Response(JSON.stringify({ ...payload, at: Date.now() }), { headers: { "content-type": "application/json" } }));
  }
  if (payload.action !== "close") await self.clients.openWindow(self.registration.scope);
}

self.addEventListener("notificationclick", (event) => {
  const n = event.notification;
  n.close();
  const action = event.action || "open";
  event.waitUntil(deliver({ type: "lulupet-notification", action, data: n.data || null }, action === "open"));
});

self.addEventListener("notificationclose", (event) => {
  const data = event.notification.data || null;
  if (data?.kind !== "own-remind" && data?.kind !== "eyedrops") return;
  event.waitUntil(windows().then((list) => {
    for (const c of list) c.postMessage({ type: "lulupet-notification", action: "close", data });
  }));
});
