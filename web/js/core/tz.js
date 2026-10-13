// Wall-clock helpers for an IANA time zone (pure; Intl only). The Swift side does the same arithmetic with
// `TimeZone.secondsFromGMT(for:)` (EyeDrops.swift `LocalClock`), so both agree on DST edges:
//   - a local time that does not exist (spring forward, e.g. 02:30) → the first instant after it (the jump, 03:00);
//   - a local time that happens twice (fall back, e.g. 01:30) → the first occurrence.
// `tz` = IANA name ("America/Los_Angeles"); null / undefined = the runtime's own zone.

const DAY_MS = 86_400_000;
const fmts = new Map();

function formatter(tz) {
  const key = tz ?? "";
  let f = fmts.get(key);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz ?? undefined, hourCycle: "h23",
      year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric",
    });
    fmts.set(key, f);
  }
  return f;
}

/** Local calendar fields of instant `ms` in `tz`: {year, month (1–12), day, hour, minute, second}. */
export function localParts(ms, tz) {
  const out = {};
  for (const p of formatter(tz).formatToParts(new Date(Math.floor(ms / 1000) * 1000))) {
    if (p.type !== "literal") out[p.type] = Number(p.value);
  }
  return { year: out.year, month: out.month, day: out.day, hour: out.hour % 24, minute: out.minute, second: out.second };
}

/** UTC offset of `tz` at instant `ms`, in ms (local = UTC + offset). */
export function offsetMs(ms, tz) {
  const p = localParts(ms, tz);
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - Math.floor(ms / 1000) * 1000;
}

/** The instant (ms) of local `y-mo-d h:mi` in `tz` (DST rules in the header). */
export function localToMs(y, mo, d, h, mi, tz) {
  const naive = Date.UTC(y, mo - 1, d, h, mi);
  const offsets = [...new Set([offsetMs(naive - DAY_MS, tz), offsetMs(naive, tz), offsetMs(naive + DAY_MS, tz)])];
  const valid = offsets.map((o) => naive - o).filter((t) => offsetMs(t, tz) === naive - t);
  if (valid.length) return Math.min(...valid);
  // In a gap: the transition instant, found by bisection to the minute between the two readings.
  let lo = naive - Math.max(...offsets), hi = naive - Math.min(...offsets);
  const before = offsetMs(lo, tz);
  while (hi - lo > 60_000) {
    const mid = lo + Math.max(1, Math.floor((hi - lo) / 120_000)) * 60_000;
    if (offsetMs(mid, tz) === before) lo = mid; else hi = mid;
  }
  return hi;
}

const pad2 = (n) => String(n).padStart(2, "0");

/** Local date "yyyy-MM-dd" of instant `ms` in `tz`. */
export function dayString(ms, tz) {
  const p = localParts(ms, tz);
  return `${String(p.year).padStart(4, "0")}-${pad2(p.month)}-${pad2(p.day)}`;
}

/** "yyyy-MM-dd" → {year, month, day}; null when malformed / not a real date. */
export function parseDay(s) {
  const m = typeof s === "string" ? /^(\d{4})-(\d{2})-(\d{2})$/.exec(s) : null;
  if (!m) return null;
  const y = +m[1], mo = +m[2], d = +m[3];
  const t = new Date(Date.UTC(y, mo - 1, d));
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== d) return null;
  return { year: y, month: mo, day: d };
}

/** Calendar arithmetic on "yyyy-MM-dd" (no time zone involved). */
export function addDays(day, n) {
  const p = parseDay(day);
  if (!p) return null;
  const t = new Date(Date.UTC(p.year, p.month - 1, p.day) + n * DAY_MS);
  return `${String(t.getUTCFullYear()).padStart(4, "0")}-${pad2(t.getUTCMonth() + 1)}-${pad2(t.getUTCDate())}`;
}

/** Whole calendar days from day `a` to day `b` ("yyyy-MM-dd"). */
export function daysBetween(a, b) {
  const p = parseDay(a), q = parseDay(b);
  return Math.round((Date.UTC(q.year, q.month - 1, q.day) - Date.UTC(p.year, p.month - 1, p.day)) / DAY_MS);
}

/** Start of the local day of `ms` (local midnight, or the first instant of the day when midnight is skipped). */
export function startOfDay(ms, tz) {
  const p = localParts(ms, tz);
  return localToMs(p.year, p.month, p.day, 0, 0, tz);
}

/** "HH:mm" of instant `ms` in `tz`. */
export function hhmm(ms, tz) {
  const p = localParts(ms, tz);
  return `${pad2(p.hour)}:${pad2(p.minute)}`;
}
