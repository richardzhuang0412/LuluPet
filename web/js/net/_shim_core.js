// TEMP — W2 stand-in for W1's web/js/core/** (spec §10 W1 contract). The merge DELETES this file and points the
// imports in web/js/net/*.js at the real modules:
//   decodeChild, encodePayload                               → ../core/message.js
//   generatePushKey, isValidPushKey                          → ../core/pushkey.js
//   clampCursor, isFuture, queueFold, outboxVerdict, backoffAfter → ../core/wire.js
//   decodePresence, isOnline, heartbeatPayload, signOffPayload → ../core/presence.js
//   seatYield, isWebDevice, adoptIdentity                    → ../core/seat.js
//   ReadCursor                                               → ../core/cursor.js
//   parseForecast                                            → ../core/weather.js
// Minimal ports of the Swift rules, only what the net layer needs; W1's versions are the source of truth.

const FUTURE_SLACK_MS = 86_400_000;
const MAX_FIELD = 64;
const MAX_TEXT = 500;
const MAX_ENCODED = 4096;
const THRESHOLD_MS = 75_000;

// ---- wire.js ----
export function clipUTF16(s, max) {
  if (s.length <= max) return s;
  let out = "";
  const seg = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter() : null;
  const parts = seg ? Array.from(seg.segment(s), (x) => x.segment) : Array.from(s);
  for (const p of parts) {
    if (out.length + p.length > max) break;
    out += p;
  }
  return out;
}
const field = (s) => (typeof s === "string" && s.length <= MAX_FIELD ? s : undefined);
export const isFuture = (ts, now) => ts > now + FUTURE_SLACK_MS;
export const clampCursor = (ts, now) => Math.min(ts, now + FUTURE_SLACK_MS);
export function queueFold(items, cap = 50) {
  if (cap < 0 || items.length <= cap) return { folded: [], kept: items.slice() };
  const cut = items.length - cap;
  return { folded: items.slice(0, cut), kept: items.slice(cut) };
}
export function outboxVerdict(status, streamConnected) {
  if (status === 400 || status === 413 || status === 422) return "park";
  if (status === 401 || status === 403) return streamConnected ? "park" : "retry";
  return "retry";
}
/** Seconds, like `StreamBackoff.afterConnection`. */
export const backoffAfter = (current, livedFor) => (livedFor >= 30 ? 1 : current);

// ---- pushkey.js ----
const ALPHABET = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz";
export function generatePushKey(ms, rand) {
  let t = Math.max(0, Math.floor(ms));
  let head = "";
  for (let i = 0; i < 8; i++) {
    head = ALPHABET[t % 64] + head;
    t = Math.floor(t / 64);
  }
  const bytes = rand ? rand(12) : crypto.getRandomValues(new Uint8Array(12));
  let tail = "";
  for (let i = 0; i < 12; i++) tail += ALPHABET[bytes[i] % 64];
  return head + tail;
}
export const isValidPushKey = (s) => typeof s === "string" && s.length === 20 && [...s].every((c) => ALPHABET.includes(c));

// ---- message.js ----
const OPTIONAL_STRINGS = ["stickerId", "outfit", "trip", "remind", "ackOf", "answer", "character"];
export function decodeChild(key, value, now) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  let json;
  try { json = JSON.stringify(value); } catch { return null; }
  if (new TextEncoder().encode(json).length > MAX_ENCODED) return null;
  const { from, kind, ts } = value;
  if (from !== "lulu" && from !== "lumei") return null;
  if (typeof kind !== "string" || !Number.isInteger(ts) || isFuture(ts, now)) return null;
  const m = { id: key, from, kind, ts };
  if (typeof value.text === "string") m.text = clipUTF16(value.text, MAX_TEXT);
  for (const k of OPTIONAL_STRINGS) { const v = field(value[k]); if (v !== undefined) m[k] = v; }
  if (Number.isInteger(value.v)) m.v = value.v;
  if (typeof value.late === "boolean") m.late = value.late;
  return m;
}
export function encodePayload(msg) {
  const out = {};
  const keys = ["ackOf", "answer", "character", "from", "kind", "late", "outfit", "remind", "stickerId", "text", "trip", "ts", "v"];
  for (const k of keys) if (msg[k] !== undefined && msg[k] !== null) out[k] = msg[k];
  if (out.v === undefined) out.v = 1;
  return out;
}

// ---- presence.js ----
export function decodePresence(obj) {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return null;
  const p = {};
  if (Number.isInteger(obj.lastSeen)) p.lastSeen = obj.lastSeen;
  for (const k of ["character", "mode", "device", "app", "outfit", "pose", "client"]) {
    if (typeof obj[k] === "string") p[k] = clipUTF16(obj[k], MAX_FIELD);
  }
  if (obj.place && typeof obj.place === "object" && typeof obj.place.name === "string") p.place = obj.place;
  if (obj.dnd && typeof obj.dnd === "object") p.dnd = obj.dnd;
  if (obj.focus && typeof obj.focus === "object") p.focus = obj.focus;
  return p;
}
export const isOnline = (lastSeen, now) => typeof lastSeen === "number" && lastSeen > 0 && now - lastSeen <= THRESHOLD_MS;
export function heartbeatPayload(identity, now) {
  const out = { lastSeen: now, character: identity.character, mode: identity.mode, device: identity.device, client: "web", pose: "idle" };
  if (identity.outfit) out.outfit = identity.outfit;
  if (identity.place) out.place = identity.place;
  return out;
}
export function signOffPayload(identity) {
  const out = { lastSeen: 0, character: identity.character, mode: identity.mode, device: identity.device, client: "web" };
  if (identity.outfit) out.outfit = identity.outfit;
  if (identity.place) out.place = identity.place;
  return out;
}

// ---- seat.js ----
export const isWebDevice = (id) => typeof id === "string" && id.startsWith("web-");
export function seatYield({ mine, myDevice, now }) {
  if (mine && typeof mine.device === "string" && !isWebDevice(mine.device) && mine.device !== myDevice && isOnline(mine.lastSeen, now)) return "yield";
  return "beat";
}
export function adoptIdentity(presence, seat) {
  const character = presence?.character === "lulu" || presence?.character === "lumei" ? presence.character : seat;
  const id = { character, mode: presence?.mode === "friend" ? "friend" : "couple" };
  if (presence?.outfit) id.outfit = presence.outfit;
  if (presence?.place) id.place = presence.place;
  return id;
}

// ---- cursor.js ----
export class ReadCursor {
  constructor(start = 0) { this.high = start; this.unread = new Map(); }
  delivered(id, ts) { this.unread.set(id, ts); }
  markRead(id, ts, now) {
    this.unread.delete(id);
    this.high = Math.max(this.high, ts);
    let c = this.high;
    for (const t of this.unread.values()) c = Math.min(c, t - 1);
    return clampCursor(c, now);
  }
}

// ---- weather.js ----
export function parseForecast(json) {
  const cur = json?.current;
  if (!cur || typeof cur.temperature_2m !== "number") throw new Error("malformed forecast");
  const first = (k) => (Array.isArray(json.daily?.[k]) && typeof json.daily[k][0] === "number" ? json.daily[k][0] : null);
  return {
    code: typeof cur.weather_code === "number" ? cur.weather_code : -1,
    cloudCover: typeof cur.cloud_cover === "number" ? cur.cloud_cover : null,
    temperature: cur.temperature_2m,
    high: first("temperature_2m_max"),
    low: first("temperature_2m_min"),
    windSpeed: typeof cur.wind_speed_10m === "number" ? cur.wind_speed_10m : null,
    isDay: (cur.is_day ?? 1) !== 0,
  };
}
