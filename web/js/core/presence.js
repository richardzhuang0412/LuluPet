// `/pairs/<code>/presence/<seat>`. Port of PresenceInfo.decode / payload (DoNotDisturb.swift), Presence.isOnline,
// DNDStatus / FocusStatus, WeatherPlace(json:), PresenceLook.cleanOutfit, PetPose(raw:).
//
// Decoded presence (absent fields are not set):
//   { lastSeen?, dnd?: {mood, until}, focus?: {phase, until}, character?, mode?, device?, app?,
//     place?: {name, admin?, country?, latitude, longitude, timezone}, outfit?, pose?, client? }

import { clipUTF16, clipped, MAX_FIELD } from "./wire.js";

export const HEARTBEAT_INTERVAL_S = 20;
export const ONLINE_THRESHOLD_MS = 75_000;
export const PARTNER_POLL_S = 15;
export const MODES = ["solo", "couple", "friend"];
export const CHARACTERS = ["lulu", "lumei"];
export const WEATHER_LOOKS = ["rain", "snow", "hot", "cold", "windy", "cloudy"];
const POSES = ["idle", "doze", "quiet", "focus", "dnd", "hidden"];

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
/** NSNumber-like: numbers (truncated to integers where LuluCore reads int64Value) and booleans (0 / 1). */
const nsInt = (v) => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : typeof v === "boolean" ? +v : undefined);
const nsDouble = (v) => (typeof v === "number" && Number.isFinite(v) ? v : typeof v === "boolean" ? +v : undefined);
const nonEmpty = (s) => (s == null || s === "" ? undefined : s);

/** Round half away from zero to 2 decimals (Swift `rounded()`). */
export function round2(v) {
  return (Math.sign(v) * Math.round(Math.abs(v) * 100)) / 100;
}

/** Tolerant `place` object: needs name / latitude / longitude / timezone (non-empty), else null. */
export function decodePlace(d) {
  if (!isObj(d) || typeof d.name !== "string" || d.name === "") return null;
  const lat = nsDouble(d.latitude), lon = nsDouble(d.longitude);
  if (lat === undefined || lon === undefined || typeof d.timezone !== "string" || d.timezone === "") return null;
  const p = { name: clipUTF16(d.name, MAX_FIELD) };
  const admin = clipped(d.admin), country = clipped(d.country);
  if (admin != null) p.admin = admin;
  if (country != null) p.country = country;
  p.latitude = round2(lat);
  p.longitude = round2(lon);
  p.timezone = clipUTF16(d.timezone, MAX_FIELD);
  return p;
}

/** `presence/<seat>/place` JSON for a decoded place. */
export function placeJSON(p) {
  const out = { name: p.name, latitude: p.latitude, longitude: p.longitude, timezone: p.timezone };
  if (p.admin != null) out.admin = p.admin;
  if (p.country != null) out.country = p.country;
  return out;
}

/** Outfit names are short identifiers; empty / over 64 characters / path-like → null. */
export function cleanOutfit(s) {
  if (typeof s !== "string" || s === "" || [...s].length > 64 || s.includes("/") || s.includes("..")) return null;
  return s;
}

/** Tolerant pose word: an unknown word reads as "idle". */
export function normalizePose(raw) {
  if (POSES.includes(raw)) return raw;
  if (typeof raw === "string" && raw.startsWith("weather:") && WEATHER_LOOKS.includes(raw.slice(8))) return raw;
  return "idle";
}

/**
 * Body of `GET presence/<seat>` (already JSON-parsed): null → null; a bare number → {lastSeen}; an object → its
 * fields (strings capped at 64 UTF-16 units; unknown character / mode → absent). Anything else → null.
 */
export function decodePresence(obj) {
  if (typeof obj === "number") return Number.isFinite(obj) ? { lastSeen: Math.trunc(obj) } : null;
  if (!isObj(obj)) return null;
  const p = {};
  const lastSeen = nsInt(obj.lastSeen);
  if (lastSeen !== undefined) p.lastSeen = lastSeen;
  if (isObj(obj.dnd)) p.dnd = { mood: clipped(obj.dnd.mood) ?? "", until: nsInt(obj.dnd.until) ?? 0 };
  if (isObj(obj.focus) && nsInt(obj.focus.until) !== undefined) {
    p.focus = { phase: typeof obj.focus.phase === "string" ? obj.focus.phase : "focus", until: nsInt(obj.focus.until) };
  }
  if (CHARACTERS.includes(obj.character)) p.character = obj.character;
  if (MODES.includes(obj.mode)) p.mode = obj.mode;
  const device = nonEmpty(clipped(obj.device));
  if (device !== undefined) p.device = device;
  const app = nonEmpty(clipped(obj.app));
  if (app !== undefined) p.app = app;
  const place = decodePlace(obj.place);
  if (place) p.place = place;
  const outfit = cleanOutfit(clipped(obj.outfit));
  if (outfit) p.outfit = outfit;
  if (typeof obj.pose === "string") p.pose = normalizePose(clipped(obj.pose));
  const client = nonEmpty(clipped(obj.client));
  if (client !== undefined) p.client = client;
  return p;
}

/** Online = lastSeen > 0 and at most 75 s old (0 = signed off). */
export function isOnline(lastSeen, now, thresholdMs = ONLINE_THRESHOLD_MS) {
  if (typeof lastSeen !== "number" || !(lastSeen > 0)) return false;
  return now - lastSeen <= thresholdMs;
}

/** 勿扰 on: `until` 0 = until turned off. */
export function dndActive(dnd, now) {
  return !!dnd && (dnd.until === 0 || now < dnd.until);
}

/** Focus round still running (a passed `until` reads as none). */
export function focusActive(focus, now) {
  return !!focus && now < focus.until;
}

/** Minutes of focus left, rounded up, at least 1. */
export function focusMinutesLeft(focus, now) {
  const ms = Math.max(0, focus.until - now);
  return Math.max(1, Math.floor((ms + 59_999) / 60_000));
}

const DND_REASONS = { angry: "😤 生气中", busy: "💼 忙碌中", resting: "😴 休息中" };

/** Partner status line: 「TA 勿扰中（😤 生气中）」 / 「TA 勿扰中」. */
export function partnerDNDLine(dnd) {
  const r = DND_REASONS[dnd?.mood];
  return r ? `TA 勿扰中（${r}）` : "TA 勿扰中";
}

function identityFields(identity) {
  const out = {};
  if (identity.character != null) out.character = identity.character;
  if (identity.mode != null) out.mode = identity.mode;
  if (identity.device != null) out.device = identity.device;
  out.client = "web";
  const outfit = cleanOutfit(identity.outfit);
  if (outfit) out.outfit = outfit;
  if (identity.place) out.place = placeJSON(identity.place);
  return out;
}

function stateFields(look) {
  const out = {};
  if (look?.dnd) out.dnd = { mood: look.dnd.mood, until: look.dnd.until };
  if (look?.focus) out.focus = { phase: look.focus.phase ?? "focus", until: look.focus.until };
  return out;
}

/**
 * Web heartbeat body (whole-object PUT, v1 §4.3): `{lastSeen, character, mode, device, client:"web", outfit, pose:"idle", place?}`.
 * `identity` = {character, mode, device, outfit?, place?} (from `adoptIdentity` + my device id). Never writes app.
 * v2 (eye-drops spec §4.4, only while I hold the seat): `look` = {dnd?: {mood, until ms | 0}, focus?: {phase, until ms},
 * pose?} adds `dnd` / `focus` (only when given) and the derived pose. Without `look` the body is exactly v1's.
 */
export function heartbeatPayload(identity, now, look) {
  if (look === undefined) return { lastSeen: now, ...identityFields(identity), pose: "idle" };
  return { lastSeen: now, ...identityFields(identity), ...stateFields(look), pose: look?.pose ?? "idle" };
}

/**
 * Sign-off body: lastSeen 0 with outfit / place / character / mode / device / client (no pose). v2: `extra` = {dnd?}
 * keeps a running 勿扰 visible after sign-off (Mac `markOffline`). Without `extra` exactly v1's.
 */
export function signOffPayload(identity, extra) {
  if (extra === undefined) return { lastSeen: 0, ...identityFields(identity) };
  return { lastSeen: 0, ...identityFields(identity), ...stateFields({ dnd: extra?.dnd }) };
}
