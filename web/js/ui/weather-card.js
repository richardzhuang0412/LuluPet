// Weather card: one row for me (my Mac's city, my seat's presence `place`) and one for TA, with TA's status badge.
// Open-Meteo every 30 minutes while the page is visible; a failed fetch keeps the old numbers ("x 分钟前"),
// older than 3 hours greys out.

import { h, setChildren } from "./dom.js";
import { fetchWeather, weatherText } from "./deps.js";
import { store } from "./store.js";

const REFRESH_MS = 30 * 60_000;
const MAX_CACHE = 4;

const keyOf = (p) => `${weatherText.round2(p.latitude)},${weatherText.round2(p.longitude)}`;
const msOf = (t) => (t > 1e12 ? t : t * 1000);   // fetchedAt: seconds (Swift) or ms

function validPlace(p) {
  return p && typeof p.name === "string" && Number.isFinite(p.latitude) && Number.isFinite(p.longitude) ? p : null;
}

function cacheGet(p) { return (store.get("weatherCache", {}) || {})[keyOf(p)] || null; }
function cachePut(p, snap) {
  const c = store.get("weatherCache", {}) || {};
  c[keyOf(p)] = snap;
  const keys = Object.keys(c).sort((a, b) => msOf(c[b].fetchedAt) - msOf(c[a].fetchedAt));
  for (const k of keys.slice(MAX_CACHE)) delete c[k];
  store.set("weatherCache", c);
}

function localTime(tz) {
  try {
    return new Intl.DateTimeFormat("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false, timeZone: tz }).format(new Date());
  } catch { return ""; }
}

/** The cached snapshot for a presence `place` (or null). */
export function snapshotFor(place) { const p = validPlace(place); return p ? cacheGet(p) : null; }

export function createWeatherCard({ onChange } = {}) {
  const el = h("section.weather", { "aria-label": "天气" });
  const rows = { me: null, ta: null };       // {place, badge}
  const inflight = new Map();
  const lastTry = new Map();

  async function refresh(place, force) {
    const k = keyOf(place);
    const cached = cacheGet(place);
    const fresh = cached && Date.now() - msOf(cached.fetchedAt) < REFRESH_MS;
    if ((fresh && !force) || inflight.has(k) || document.hidden) return;
    if (Date.now() - (lastTry.get(k) || 0) < 60_000) return;
    lastTry.set(k, Date.now());
    const p = fetchWeather(place).then((snap) => { if (snap) cachePut(place, snap); }).catch(() => {}).finally(() => {
      inflight.delete(k);
      render();
    });
    inflight.set(k, p);
  }

  function row(label, info, avatar) {
    const place = validPlace(info?.place);
    const snap = place && cacheGet(place);
    const now = Date.now();
    const right = !place ? null
      : snap ? h("div.wx-now", { class: weatherText.isStale(msOf(snap.fetchedAt), now) ? "stale" : null },
        h("span.wx-emoji", weatherText.emoji(weatherText.condition(snap), snap.isDay)),
        h("span.wx-temp", `${Math.round(snap.temperature)}°`),
        snap.high != null && snap.low != null ? h("span.wx-range", `${Math.round(snap.high)}° / ${Math.round(snap.low)}°`) : null)
        : h("div.wx-none", weatherText.unavailable);
    const sub = [];
    if (place) {
      const t = localTime(place.timezone);
      const parts = [t, snap ? weatherText.label(weatherText.condition(snap)) : null, snap ? weatherText.ageLabel(msOf(snap.fetchedAt), now) : null];
      sub.push(h("span", parts.filter(Boolean).join(" · ")));
    }
    if (info?.badge) sub.push(h("span.badge", `${info.badge.dot} ${info.badge.text}`));
    return h("div.wx-row",
      h("span.wx-avatar", { "aria-hidden": "true" }, avatar),
      h("div.wx-main",
        h("div.wx-title", h("span.wx-who", label), h("span.wx-city", { class: place ? null : "muted" }, place ? place.name : "还没设置城市")),
        h("div.wx-sub", sub)),
      right);
  }

  function render() {
    const list = [];
    if (rows.ta) list.push(row("TA", rows.ta, rows.ta.avatar));
    list.push(row("我", rows.me, rows.me?.avatar ?? "🙂"));
    if (!validPlace(rows.me?.place)) list.push(h("div.wx-hint", "我的城市跟着家里 Mac 的设置走（🍊 → 设置 → 通用）"));
    setChildren(el, list);
    onChange?.();
  }

  function tick(force = false) {
    for (const r of [rows.me, rows.ta]) { const p = validPlace(r?.place); if (p) refresh(p, force); }
    render();
  }

  setInterval(() => tick(), 60_000);   // re-renders local time / ages; fetches only when due and visible
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tick(); });

  return {
    el,
    /** me / ta: {place, badge?, avatar?}. */
    set(me, ta) {
      const changed = (a, b) => validPlace(a?.place) && (!validPlace(b?.place) || keyOf(a.place) !== keyOf(b.place));
      const need = changed(me, rows.me) || changed(ta, rows.ta);
      rows.me = me;
      rows.ta = ta;
      if (need) tick();
      else render();
    },
  };
}
