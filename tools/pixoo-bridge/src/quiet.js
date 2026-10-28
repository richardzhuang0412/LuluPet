// Night quiet hours ("23:00"–"08:00" wraps past midnight). Pure; time zone via Intl.

const fmtCache = new Map();

/** Minutes since local midnight of `ms` in `timeZone` (empty = system zone). */
export function minutesOfDay(ms, timeZone = "") {
  const key = timeZone || "";
  let f = fmtCache.get(key);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", { hour: "2-digit", minute: "2-digit", hourCycle: "h23", ...(timeZone ? { timeZone } : {}) });
    fmtCache.set(key, f);
  }
  const parts = f.formatToParts(new Date(ms));
  const h = Number(parts.find((p) => p.type === "hour").value) % 24;
  const m = Number(parts.find((p) => p.type === "minute").value);
  return h * 60 + m;
}

export function parseHHMM(s) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(s));
  if (!m) return null;
  const h = Number(m[1]), min = Number(m[2]);
  return h < 24 && min < 60 ? h * 60 + min : null;
}

/** True inside [start, end) local time. start == end → never quiet. Disabled → false. */
export function inQuietHours(ms, quiet, timeZone = "") {
  if (!quiet?.enabled) return false;
  const start = parseHHMM(quiet.start), end = parseHHMM(quiet.end);
  if (start === null || end === null || start === end) return false;
  const t = minutesOfDay(ms, timeZone);
  return start < end ? t >= start && t < end : t >= start || t < end;
}
