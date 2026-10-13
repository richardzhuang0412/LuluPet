// 眼药水提醒 (docs/superpowers/specs/2026-10-12-eyedrops-and-web-v2.md §2). Twin of Sources/LuluCore/EyeDrops.swift;
// web/tests/vectors/wire.json `eyedrops` is checked against both.
//
// Shapes (JSON-safe, same as the remote `/pairs/{code}/tools/{seat}/eyedrops`):
//   settings = {enabled, times: ["08:00", …] (sorted, ≤ 8), notify, at: ms, device}
//   days     = {"2026-10-12": {"0800": {done: ms, device}, …}, …}      (the `today` argument of plan / progress:
//              the days map, normally today and yesterday — a slot late in the evening is still nagged after midnight)
//   nag      = {slot: "2026-10-12/1400", shown: 1…3, next: ms}          (one at a time, this device only)
// Times are Unix ms; `tz` is an IANA name (Swift: `TimeZone`).

import { clipUTF16 } from "./wire.js";
import { addDays, dayString, localToMs, parseDay } from "./tz.js";

export const SLOT_LIMITS = Object.freeze({
  maxSlots: 8, minGapMin: 30, nagEveryMs: 900_000, maxShows: 3, catchUpMs: 7_200_000, activeIdleS: 300,
});
/** While a slot is due but the user is away: look again after this long. */
export const INACTIVE_POLL_MS = 60_000;
/** Longest sleep `plan` asks for. */
export const MAX_WAKE_MS = 86_400_000;
export const HEADER = "👁️💧 眼药水";
export const BUTTON_DONE = "滴了 ✓";
export const BUTTON_LATER = "等会儿";
export const ERRORS = Object.freeze({
  format: "时间格式不对", empty: "至少要设一个时间", tooMany: "一天最多 8 次", gap: "相邻两次至少隔 30 分钟",
});

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isNum = (v) => typeof v === "number" && Number.isFinite(v);
const pad2 = (n) => String(n).padStart(2, "0");

/** "HH:mm" (24 h, two digits each) → minutes after midnight; null when malformed. */
export function parseTime(t) {
  const m = typeof t === "string" ? /^([01]\d|2[0-3]):([0-5]\d)$/.exec(t) : null;
  return m ? +m[1] * 60 + +m[2] : null;
}

/** Minutes after midnight → "HH:mm". */
export function formatTime(min) {
  return `${pad2(Math.floor(min / 60))}:${pad2(min % 60)}`;
}

/** 1 → 09:00; 2 → 09 21; 3 → 08 14 20; 4 → 08 12 16 20; 5–8 → 08:00…22:00 evenly, rounded to 30 minutes. */
export function suggestedTimes(n) {
  const k = Math.min(SLOT_LIMITS.maxSlots, Math.max(1, Math.trunc(Number(n) || 0)));
  const fixed = { 1: ["09:00"], 2: ["09:00", "21:00"], 3: ["08:00", "14:00", "20:00"], 4: ["08:00", "12:00", "16:00", "20:00"] };
  if (fixed[k]) return fixed[k].slice();
  const step = (22 * 60 - 8 * 60) / (k - 1);
  return Array.from({ length: k }, (_, i) => formatTime(8 * 60 + Math.round((i * step) / 30) * 30));
}

/** Settings check → {ok, times (sorted), error}. Errors in this order: format, empty, too many, gap < 30 min. */
export function validateTimes(times) {
  const list = Array.isArray(times) ? times : [];
  const mins = list.map(parseTime);
  const sorted = mins.filter((m) => m != null).sort((a, b) => a - b).map(formatTime);
  const fail = (error) => ({ ok: false, times: sorted, error });
  if (!Array.isArray(times) || mins.some((m) => m == null)) return fail(ERRORS.format);
  if (sorted.length === 0) return fail(ERRORS.empty);
  if (sorted.length > SLOT_LIMITS.maxSlots) return fail(ERRORS.tooMany);
  const m = sorted.map(parseTime);
  for (let i = 1; i < m.length; i++) if (m[i] - m[i - 1] < SLOT_LIMITS.minGapMin) return fail(ERRORS.gap);
  return { ok: true, times: sorted, error: null };
}

/** "08:00" → "0800" (the remote leaf key); null when malformed. */
export function slotKey(time) {
  const m = parseTime(time);
  return m == null ? null : time.slice(0, 2) + time.slice(3);
}

/** "0800" → "08:00"; null when malformed. */
export function slotTime(key) {
  const m = typeof key === "string" ? /^([01]\d|2[0-3])([0-5]\d)$/.exec(key) : null;
  return m ? `${m[1]}:${m[2]}` : null;
}

/** "2026-10-12" + "14:00" → "2026-10-12/1400" (the `nag.slot` / `plan().slot` id). */
export function slotId(day, time) {
  return `${day}/${slotKey(time)}`;
}

/** "2026-10-12/1400" → {day, key: "1400", time: "14:00"}; null when malformed. */
export function parseSlotId(id) {
  const m = typeof id === "string" ? /^(\d{4}-\d{2}-\d{2})\/(\d{4})$/.exec(id) : null;
  if (!m || !parseDay(m[1]) || !slotTime(m[2])) return null;
  return { day: m[1], key: m[2], time: slotTime(m[2]) };
}

/** Local date "yyyy-MM-dd" of `ms` in `tz`. */
export function dayKey(ms, tz) {
  return dayString(ms, tz);
}

/** The instant of `time` on local `day` in `tz` (skipped time → the jump; repeated time → first). null if malformed. */
export function slotInstant(day, time, tz) {
  const d = parseDay(day), m = parseTime(time);
  if (!d || m == null) return null;
  return localToMs(d.year, d.month, d.day, Math.floor(m / 60), m % 60, tz);
}

/** Times as stored: valid "HH:mm" only, deduplicated, sorted, at most 8. */
export function normalizeTimes(times) {
  const mins = (Array.isArray(times) ? times : []).map(parseTime).filter((m) => m != null);
  return [...new Set(mins)].sort((a, b) => a - b).slice(0, SLOT_LIMITS.maxSlots).map(formatTime);
}

/** Tolerant settings: not an object → null; enabled / notify only `true` counts; `at` a number else 0. */
export function decodeSettings(obj) {
  if (!isObj(obj)) return null;
  return {
    enabled: obj.enabled === true,
    times: normalizeTimes(obj.times),
    notify: obj.notify === true,
    at: isNum(obj.at) ? Math.trunc(obj.at) : 0,
    device: typeof obj.device === "string" ? clipUTF16(obj.device, 64) : "",
  };
}

/** One check-in leaf: needs a numeric `done`; device clipped to 64. */
export function decodeMark(obj) {
  if (!isObj(obj) || !isNum(obj.done)) return null;
  return { done: Math.trunc(obj.done), device: typeof obj.device === "string" ? clipUTF16(obj.device, 64) : "" };
}

/** `days` object: bad day keys, slot keys and leaves are skipped; days left empty are dropped. */
export function decodeDays(obj) {
  const out = {};
  if (!isObj(obj)) return out;
  for (const day of Object.keys(obj).sort()) {
    if (!parseDay(day) || !isObj(obj[day])) continue;
    const rec = {};
    for (const key of Object.keys(obj[day]).sort()) {
      const mark = slotTime(key) ? decodeMark(obj[day][key]) : null;
      if (mark) rec[key] = mark;
    }
    if (Object.keys(rec).length) out[day] = rec;
  }
  return out;
}

/** The whole `eyedrops` node → {settings (or null), days}. */
export function decodeEyedrops(obj) {
  return { settings: decodeSettings(isObj(obj) ? obj.settings : null), days: decodeDays(isObj(obj) ? obj.days : null) };
}

/** Settings → the JSON written by `PUT …/eyedrops/settings.json`. */
export function settingsJSON(s) {
  return { enabled: s.enabled, times: s.times.slice(), notify: s.notify, at: s.at, device: s.device };
}

/** Stored nag → nag or null; `next` is clamped to ≤ now + 15 min (a clock set back never holds it for long). */
export function decodeNag(obj, now) {
  if (!isObj(obj) || !parseSlotId(obj.slot) || !isNum(obj.shown) || !isNum(obj.next)) return null;
  const shown = Math.min(SLOT_LIMITS.maxShows, Math.max(0, Math.trunc(obj.shown)));
  return { slot: obj.slot, shown, next: Math.min(Math.trunc(obj.next), now + SLOT_LIMITS.nagEveryMs) };
}

/** Newer `at` wins; a tie keeps `local`. Either may be null. */
export function mergeSettings(local, remote) {
  if (!remote) return local ?? null;
  if (!local) return remote;
  return remote.at > local.at ? remote : local;
}

// ---- planning

function slotsOn(day, times, tz) {
  return times.map((time) => ({ day, time, key: slotKey(time), id: slotId(day, time), inst: slotInstant(day, time, tz) }));
}

/** A slot that had already passed when the settings were changed that same day is not caught up. */
function counts(c, settings, tz) {
  return !(dayKey(settings.at, tz) === c.day && c.inst < settings.at);
}

function nextSlotAfter(times, now, tz) {
  const today = dayKey(now, tz);
  const later = [...slotsOn(today, times, tz), ...slotsOn(addDays(today, 1), times, tz)].map((c) => c.inst).filter((t) => t > now);
  return Math.min(now + MAX_WAKE_MS, ...later);
}

/** The slot `plan` is about: the newest one that has arrived, is inside its 2 h window and counts (else null). */
function currentSlot(settings, now, tz) {
  const today = dayKey(now, tz);
  const all = [...slotsOn(addDays(today, -1), settings.times, tz), ...slotsOn(today, settings.times, tz)];
  let best = null;
  for (const c of all) {
    if (c.inst <= now && now < c.inst + SLOT_LIMITS.catchUpMs && counts(c, settings, tz) && (!best || c.inst >= best.inst)) best = c;
  }
  return best;
}

/**
 * What to do now → {action: "none" | "show" | "wait", slot: id | null, nextWakeMs}.
 * Only the newest arrived slot is ever nagged (an older one still nagging is superseded). It is skipped when checked
 * in or shown 3 times; it waits for `nag.next`, or (user away) polls each minute; otherwise it shows.
 */
export function plan({ settings, today, nag, now, active, tz }) {
  const times = settings?.enabled ? settings.times : [];
  if (!times.length) return { action: "none", slot: null, nextWakeMs: nextSlotAfter(settings?.times ?? [], now, tz) };
  const nextSlot = nextSlotAfter(times, now, tz);
  const s = currentSlot(settings, now, tz);
  const mine = s && nag && nag.slot === s.id ? nag : null;
  if (!s || today?.[s.day]?.[s.key] || (mine && mine.shown >= SLOT_LIMITS.maxShows)) {
    return { action: "none", slot: null, nextWakeMs: nextSlot };
  }
  const nagNext = mine ? Math.min(mine.next, now + SLOT_LIMITS.nagEveryMs) : null;
  if (nagNext != null && nagNext > now) return { action: "wait", slot: s.id, nextWakeMs: Math.min(nagNext, nextSlot) };
  if (!active) return { action: "wait", slot: s.id, nextWakeMs: Math.min(now + INACTIVE_POLL_MS, nextSlot) };
  return { action: "show", slot: s.id, nextWakeMs: Math.min(now + SLOT_LIMITS.nagEveryMs, nextSlot) };
}

/** The nag after showing `slot` (another slot's nag is replaced). */
export function afterShow(nag, slot, now) {
  const shown = nag && nag.slot === slot ? nag.shown : 0;
  return { slot, shown: shown + 1, next: now + SLOT_LIMITS.nagEveryMs };
}

/** 「滴了」: no nag any more. */
export function afterDone(_nag) {
  return null;
}

/**
 * Today's card → {done, total, slots: [{time, state, device?}]}. States: done (with the device that checked in),
 * upcoming, showing (the current slot: due / being nagged), unconfirmed (nagged 3 times, or an older nagged slot that
 * was superseded), missed (passed without a reminder). `nag` (optional) tells nagged slots apart.
 */
export function progress(settings, today, now, tz, nag = null) {
  if (!settings) return { done: 0, total: 0, slots: [] };
  const day = dayKey(now, tz);
  const rec = today?.[day] ?? {};
  const list = slotsOn(day, settings.times, tz);
  const past = list.filter((c) => c.inst <= now);
  const latest = past.length ? past[past.length - 1] : null;
  let done = 0;
  const slots = list.map((c) => {
    const mark = rec[c.key];
    if (mark) {
      done++;
      return { time: c.time, state: "done", device: mark.device };
    }
    if (c.inst > now) return { time: c.time, state: "upcoming" };
    const nagged = nag && nag.slot === c.id ? nag : null;
    if (settings.enabled && c === latest && now < c.inst + SLOT_LIMITS.catchUpMs && counts(c, settings, tz)) {
      const over = nagged && nagged.shown >= SLOT_LIMITS.maxShows && now >= nagged.next;
      return { time: c.time, state: over ? "unconfirmed" : "showing" };
    }
    return { time: c.time, state: nagged && nagged.shown >= 1 ? "unconfirmed" : "missed" };
  });
  return { done, total: list.length, slots };
}

/** Title / PiP badge: 「👁️ 2/4」, or 「👁️ 该滴了」 while a slot is showing. Empty when there are no slots. */
export function badge(p) {
  if (!p || p.total === 0) return "";
  return p.slots.some((s) => s.state === "showing") ? "👁️ 该滴了" : `👁️ ${p.done}/${p.total}`;
}

/** The pet bubble: header 「👁️💧 眼药水」, line 「该滴眼药水啦（14:00 · 今天第 3 次）」 (`index` 1-based of `total`). */
export function bubbleCopy(slot, index, _total) {
  const time = parseSlotId(slot)?.time ?? (parseTime(slot) != null ? slot : "");
  return { header: HEADER, line: `该滴眼药水啦（${time} · 今天第 ${index} 次）`, done: BUTTON_DONE, later: BUTTON_LATER };
}
