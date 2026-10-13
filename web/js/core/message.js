// One message. Port of Sources/LuluCore/Message.swift (decode(firebaseKey:value:now:), firebasePayload())
// and FirebaseDecode (SSEParser.swift). Wire format: `/pairs/<code>/messages/<key>` =
// `{from, kind, text?, stickerId?, ts, v?, outfit?, trip?, remind?, ackOf?, answer?, late?, character?}` plus any
// fields a newer client adds (kept in `extra`, re-encoded unchanged).
//
// Msg (plain object; absent fields are not set):
//   { id, from: "lulu"|"lumei", kind: string, text?, stickerId?, ts, v?, outfit?, trip?,
//     remind?: string (raw wire value, e.g. "water" | "stand" | "water.later"), ackOf?, answer?, late?: boolean,
//     character?: "lulu"|"lumei", extra?: {unknown fields, verbatim} }

import { MAX_TEXT, MAX_ENCODED_BYTES, clipUTF16, field, isFuture } from "./wire.js";

export const UNKNOWN_KIND_PLACEHOLDER = "［新版本消息，请升级噜噜桌宠查看］";
export const STICKER_FALLBACK_PREFIX = "[表情] ";
export const CURRENT_SCHEMA_VERSION = 1;
export const TRIP_LOCAL = "local";
export const TRIP_DELIVER = "deliver";
export const KNOWN_KINDS = ["text", "sticker", "poke", "visit", "remind"];
export const SEATS = ["lulu", "lumei"];
export const CHARACTERS = ["lulu", "lumei"];

const KNOWN_KEYS = new Set(["id", "from", "kind", "text", "stickerId", "ts", "v", "outfit", "trip", "localId",
  "remind", "ackOf", "answer", "late", "character"]);

/** `text` cut to 500 UTF-16 units without splitting a character. */
export function clampText(s) {
  return clipUTF16(s, MAX_TEXT);
}

const isPlainObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const str = (v) => (typeof v === "string" ? v : undefined);

/** UTF-8 byte length of `value` serialized the way LuluCore's JSONSerialization does it (compact, `/` escaped as `\/`). */
export function encodedSize(value) {
  const json = JSON.stringify(value);
  let bytes = 0;
  for (let i = 0; i < json.length; i++) {
    const c = json.charCodeAt(i);
    if (c < 0x80) bytes += c === 0x2f ? 2 : 1;
    else if (c < 0x800) bytes += 2;
    else if (c >= 0xd800 && c <= 0xdbff) { bytes += 4; i++; }
    else bytes += 3;
  }
  return bytes;
}

/**
 * Decodes one Firebase child (`value` of `/messages/<key>`). null when: not an object, over 4096 bytes, missing /
 * wrongly typed `from` / `kind` / `ts` (or a non-string `id`), `from` not a seat, `ts` not an integer, or `ts` more than a
 * day ahead of `now`. `text` is cut to 500 UTF-16 units; stickerId / outfit / trip / remind / ackOf / answer over
 * 64 read as absent. A wrongly typed optional field reads as absent.
 */
export function decodeChild(key, value, now) {
  if (!isPlainObject(value)) return null;
  let size;
  try { size = encodedSize(value); } catch { return null; }
  if (size > MAX_ENCODED_BYTES) return null;
  const { from, kind, ts } = value;
  if (!SEATS.includes(from) || typeof kind !== "string") return null;
  if (typeof ts !== "number" || !Number.isSafeInteger(ts)) return null;
  if (value.id !== undefined && value.id !== null && typeof value.id !== "string") return null;
  if (isFuture(ts, now)) return null;

  const m = { id: String(key), from, kind, ts };
  const text = str(value.text);
  if (text !== undefined) m.text = clampText(text);
  const opt = { stickerId: "stickerId", outfit: "outfit", trip: "trip", remind: "remind", ackOf: "ackOf", answer: "answer" };
  for (const [k, wire] of Object.entries(opt)) {
    const f = field(str(value[wire]));
    if (f !== null) m[k] = f;
  }
  if (typeof value.v === "number" && Number.isSafeInteger(value.v)) m.v = value.v;
  if (typeof value.late === "boolean") m.late = value.late;
  const extra = {};
  for (const k of Object.keys(value)) {
    if (!KNOWN_KEYS.has(k)) extra[k] = value[k];
  }
  const ch = value.character;
  if (ch !== undefined && ch !== null) {
    if (CHARACTERS.includes(ch)) m.character = ch;
    else extra.character = ch; // unknown (future) character: kept verbatim
  }
  if (Object.keys(extra).length) m.extra = extra;
  return m;
}

/**
 * Firebase children `{key: value}` (a backlog `put`, a multi-child `patch`, or a plain GET body) → decoded messages,
 * sorted by (ts, id). Anything that isn't an object → [].
 */
export function decodeChildren(obj, now) {
  if (!isPlainObject(obj)) return [];
  const out = [];
  for (const [k, v] of Object.entries(obj)) {
    const m = decodeChild(k, v, now);
    if (m) out.push(m);
  }
  return out.sort((a, b) => (a.ts - b.ts) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/**
 * One SSE event of the message stream (FirebaseDecode). `event` = SSE event name, `data` = its data line.
 * → `{backlog, msgs}`: `backlog` is true for path "/" (the first put = messages from while we were away);
 * `msgs` is [] for events that carry no messages (keep-alive, deeper paths, deletions, bad JSON).
 */
export function decodeStreamEvent(event, data, now) {
  let env;
  try { env = JSON.parse(data); } catch { return { backlog: false, msgs: [] }; }
  if (!isPlainObject(env) || typeof env.path !== "string") return { backlog: false, msgs: [] };
  const parts = env.path.split("/").filter((p) => p.length > 0);
  const backlog = parts.length === 0;
  if ((event !== "put" && event !== "patch") || !isPlainObject(env.data)) return { backlog, msgs: [] };
  let entries;
  if (parts.length === 0) entries = env.data;
  else if (parts.length === 1) entries = { [parts[0]]: env.data };
  else return { backlog, msgs: [] };
  return { backlog, msgs: decodeChildren(entries, now) };
}

/** True when Firebase closed the stream because the rules deny access. */
export function isAuthRevokedEvent(event) {
  return event === "cancel" || event === "auth_revoked";
}

/**
 * The JSON object to PUT for `msg` (`Message.firebasePayload()`): keys sorted, no `id` / `localId`, unknown fields
 * from `extra` kept verbatim.
 */
export function encodePayload(msg) {
  const out = {};
  if (msg.extra) for (const [k, v] of Object.entries(msg.extra)) if (!KNOWN_KEYS.has(k)) out[k] = v;
  out.from = msg.from;
  out.kind = msg.kind;
  if (msg.text != null) out.text = msg.text;
  if (msg.stickerId != null) out.stickerId = msg.stickerId;
  out.ts = msg.ts;
  if (msg.v != null) out.v = msg.v;
  if (msg.outfit != null) out.outfit = msg.outfit;
  if (msg.trip != null) out.trip = msg.trip;
  if (msg.remind != null) out.remind = msg.remind;
  if (msg.ackOf != null) out.ackOf = msg.ackOf;
  if (msg.answer != null) out.answer = msg.answer;
  if (msg.late != null) out.late = msg.late;
  if (msg.character != null) out.character = msg.character;
  else if (msg.extra && msg.extra.character !== undefined) out.character = msg.extra.character;
  const sorted = {};
  for (const k of Object.keys(out).sort()) sorted[k] = out[k];
  return sorted;
}

// MARK: factories (what the web client sends; §2.1). `me` = {from: seat, character?, outfit?}.
// `trip` is always "local" (the PiP pet never runs off), `v` is 1. `id` is assigned by the channel (push key).

function base(kind, me, ts) {
  const m = { from: me.from, kind, ts, v: CURRENT_SCHEMA_VERSION, trip: TRIP_LOCAL };
  if (me.character != null) m.character = me.character;
  if (me.outfit != null) m.outfit = me.outfit;
  return m;
}

export function textMsg(text, me, ts) {
  const m = base("text", me, ts);
  m.text = clampText(String(text));
  return m;
}

/** `label` = the sticker's name; sent as the fallback text「[表情] <label>」 (omitted when there is no label). */
export function stickerMsg(stickerId, label, me, ts) {
  const m = base("sticker", me, ts);
  m.stickerId = stickerId;
  if (label != null && label !== "") m.text = clampText(STICKER_FALLBACK_PREFIX + label);
  return m;
}

export function pokeMsg(me, ts) {
  return base("poke", me, ts);
}

/** 叫 TA 喝水 / 起来动动: `kind` = "water" | "stand". */
export function remindMsg(kind, me, ts) {
  const m = base("remind", me, ts);
  m.remind = kind;
  return m;
}

// MARK: display helpers

/** The sticker's name from the fallback text「[表情] 么么哒」 (null when absent). */
export function stickerFallbackLabel(msg) {
  if (msg.kind !== "sticker" || typeof msg.text !== "string" || !msg.text.startsWith(STICKER_FALLBACK_PREFIX)) return null;
  const label = msg.text.slice(STICKER_FALLBACK_PREFIX.length).trim();
  return label === "" ? null : label;
}

/** Bubble text for a sticker this client can't show: 「［表情：<catalog label | fallback label | id>］」. */
export function unknownStickerText(msg, catalogLabel = null) {
  return `［表情：${catalogLabel ?? stickerFallbackLabel(msg) ?? msg.stickerId ?? "?"}］`;
}

/** Whether this client understands the message kind (else it shows UNKNOWN_KIND_PLACEHOLDER). */
export function isKnownKind(kind) {
  return KNOWN_KINDS.includes(kind);
}
