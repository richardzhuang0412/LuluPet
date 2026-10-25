// Pure push rules (no Firebase, no network): what a new message turns into, who gets it, and when a subscription is
// skipped because the recipient is at a device that already shows it. Spec: docs/superpowers/specs/2026-10-22-web-push.md.
//
// Subscription record, /pairs/{code}/push/{seat}/{subId} (written by web/js/net/push.js):
//   {endpoint, keys: {p256dh, auth}, device: "web-…", phone: bool, tz: IANA, ua, at: ms, key: VAPID public key prefix,
//    prefs: {messages, reminders, eyedrops, onlyWhenAway, dnd: "silent" | "skip"}, vis?: {hidden: bool, at: ms}}
// Device activity record, /pairs/{code}/devices/{seat}/{deviceId} (web/js/net/devices.js, the Mac ≥ 0.19; schema in
//   vendor/devices.js): {kind: "mac" | "web" | "phone", activeAt: ms, at: ms, vis?: "visible" | "hidden"}.
// Push payload (JSON, read by web/sw.js 'push'): {v: 1, kind: "message" | "partner-remind" | "eyedrops", title, body,
//   tag, key?, remind?, slot?, silent?}. Never the pair code or the database URL.

import { decodeChild, stickerFallbackLabel } from "../vendor/message.js";
import { decodeReply, replyLine, reminderKind, remindBubble } from "../vendor/remind.js";
import { decodePresence, dndActive, focusActive, isOnline } from "../vendor/presence.js";
import { clipUTF16 } from "../vendor/wire.js";
import { decodeDevices, isActivelyUsed, isVisibleNow } from "../vendor/devices.js";

export const SEATS = ["lulu", "lumei"];
export const NAMES = { lulu: "噜噜", lumei: "噜妹" };
export const CODE_RE = /^[A-HJ-NP-Z2-9]{24}$/;
export const BODY_MAX = 80;
/** A message created with a ts older than this (an outbox that waited all night) is not pushed any more. */
export const MAX_AGE_MS = 6 * 3_600_000;
/** Characters of the VAPID public key stored on a subscription (`key`), to skip subscriptions made with an old key. */
export const KEY_PREFIX = 16;
export const TTL = { message: 6 * 3600, remind: 2 * 3600, reply: 3600, eyedrops: 900 };

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const str = (v, max = 64) => (typeof v === "string" ? clipUTF16(v, max) : "");

export const otherSeat = (seat) => (seat === "lulu" ? "lumei" : seat === "lumei" ? "lulu" : null);

/** Body text: at most 80 UTF-16 units (79 + 「…」), never inside an emoji. */
export function clipBody(s) {
  const t = String(s ?? "").replace(/\s+/g, " ").trim();
  return t.length <= BODY_MAX ? t : clipUTF16(t, BODY_MAX - 1) + "…";
}

/**
 * A new message → {category: "messages" | "reminders", ttl, urgency, payload} or null (not pushed: replies to my
 * own reminders are pushed, every other kind of ack / unknown kind / stale or malformed message is not).
 */
export function messagePush(id, value, now) {
  const msg = decodeChild(id, value, now);
  if (!msg || now - msg.ts > MAX_AGE_MS) return null;
  const name = NAMES[msg.character] ?? NAMES[msg.from];
  const said = `${name}说：`;
  const base = { v: 1, key: msg.id, tag: "msg-" + msg.id };
  const message = (title, body) => ({ category: "messages", ttl: TTL.message, urgency: "normal",
    payload: { ...base, kind: "message", title, body: clipBody(body) } });
  switch (msg.kind) {
    case "text":
      return msg.text ? message(said, msg.text) : null;
    case "sticker": {
      const label = stickerFallbackLabel(msg);
      return message(said, `［表情］${label ?? ""}`);
    }
    case "poke":
      return message(name, `${name}给你发了一颗爱心 ❤️`);
    case "visit":
      return message(name, `${name}跑来找你玩啦`);
    case "remind": {
      const kind = reminderKind(msg);
      if (kind) {
        const b = remindBubble(kind, name);
        return { category: "reminders", ttl: TTL.remind, urgency: "high",
          payload: { ...base, kind: "partner-remind", title: b.header, body: b.line, remind: kind } };
      }
      const reply = decodeReply(msg);
      if (reply) {
        return { category: "reminders", ttl: TTL.reply, urgency: "normal",
          payload: { ...base, kind: "message", title: name, body: replyLine(reply) } };
      }
      return null;
    }
    default:
      return null;
  }
}

/** Tolerant prefs: messages / reminders / onlyWhenAway default on, eyedrops default off, dnd "silent" unless "skip". */
export function decodePrefs(p) {
  const o = isObj(p) ? p : {};
  return {
    messages: o.messages !== false,
    reminders: o.reminders !== false,
    eyedrops: o.eyedrops === true,
    onlyWhenAway: o.onlyWhenAway !== false,
    dnd: o.dnd === "skip" ? "skip" : "silent",
  };
}

/** One subscription record → decoded, or null when it can't be pushed to (no https endpoint / keys). */
export function decodeSub(id, v) {
  if (!isObj(v) || typeof v.endpoint !== "string" || !v.endpoint.startsWith("https://") || v.endpoint.length > 1024) return null;
  if (!isObj(v.keys) || typeof v.keys.p256dh !== "string" || typeof v.keys.auth !== "string") return null;
  return {
    id: String(id),
    endpoint: v.endpoint,
    keys: { p256dh: v.keys.p256dh, auth: v.keys.auth },
    device: str(v.device),
    phone: v.phone === true,
    tz: str(v.tz),
    key: str(v.key),
    prefs: decodePrefs(v.prefs),
    vis: isObj(v.vis) ? { hidden: v.vis.hidden === true, at: typeof v.vis.at === "number" ? v.vis.at : 0 } : null,
  };
}

/** `/push/{seat}` node → decoded subscriptions (bad ones skipped), in key order. */
export function decodeSubs(node) {
  if (!isObj(node)) return [];
  return Object.keys(node).sort().map((k) => decodeSub(k, node[k])).filter(Boolean);
}

/** A subscription made with another VAPID key can't be pushed with the current one (the browser re-subscribes). */
export function keyMatches(sub, publicKey) {
  return !sub.key || !publicKey || sub.key === publicKey.slice(0, KEY_PREFIX);
}

/** A phone's page is in the background: the newer of its device record's `vis` and the subscription's own `vis`. */
function hiddenNow(sub, own) {
  if (own?.vis && (!sub.vis || own.at >= sub.vis.at)) return own.vis === "hidden";
  return sub.vis?.hidden === true;
}

/**
 * Where the recipient is, for one subscription S (spec §2.1; `devices` = decodeDevices of /devices/{seat}):
 * - "here": S's own page shows it already — its device record is "visible" and written within 90 s, or (as before)
 *   S's browser holds the seat presence (a phone page only while not hidden: iOS freezes it in the background;
 *   a hidden desktop tab still runs and notifies itself);
 * - "elsewhere": ANOTHER device of the seat is actively used (real input within 3 min) — that one shows it;
 * - "away": neither. Presence online alone (an awake but idle home Mac) no longer counts, and a device without a
 *   record (0.18 Macs) never suppresses: extra notifications rather than missed ones.
 */
export function whereIs(sub, presence, now, devices = []) {
  const own = sub.device ? devices.find((d) => d.id === sub.device) ?? null : null;
  if (isVisibleNow(own, now)) return "here";
  if (presence && isOnline(presence.lastSeen, now) && sub.device && presence.device === sub.device
      && !(sub.phone && hiddenNow(sub, own))) return "here";
  if (devices.some((d) => d.id !== sub.device && isActivelyUsed(d, now))) return "elsewhere";
  return "away";
}

/** Push to this subscription? Away → yes; here → no; elsewhere → only when its prefs say 「不管在不在电脑前」. */
export function shouldSend(sub, presence, now, devices = []) {
  const w = whereIs(sub, presence, now, devices);
  return w === "away" || (w === "elsewhere" && !sub.prefs.onlyWhenAway);
}

/** Recipient in 勿扰 or a focus round (a 勿扰 stays on the presence after sign-off). */
export function isQuiet(presence, now) {
  return !!presence && (dndActive(presence.dnd, now) || focusActive(presence.focus, now));
}

/**
 * Message → recipient seat and the subscriptions to push to, each with `silent`.
 * `subsNode` / `presenceRaw` / `devicesRaw` are the recipient's `/push/{seat}`, `/presence/{seat}` and
 * `/devices/{seat}` as stored.
 */
export function messageTargets({ built, subsNode, presenceRaw, devicesRaw = null, now, publicKey }) {
  const subs = decodeSubs(subsNode).filter((s) => keyMatches(s, publicKey) && s.prefs[built.category]);
  if (!subs.length) return [];
  const presence = decodePresence(presenceRaw);
  const quiet = isQuiet(presence, now);
  const devices = decodeDevices(devicesRaw, now);
  return subs
    .filter((s) => !(quiet && s.prefs.dnd === "skip"))
    .filter((s) => shouldSend(s, presence, now, devices))
    .map((sub) => ({ sub, silent: quiet }));
}

/** A valid IANA time zone name, else null. */
export function validTz(tz) {
  if (typeof tz !== "string" || !tz) return null;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return tz;
  } catch {
    return null;
  }
}

/** Eye-drop clock: the subscribing device's zone → settings.tz (if a client ever stores it) → the seat's city. */
export function pickTz(subs, rawSettings, presence) {
  for (const s of subs) if (validTz(s.tz)) return s.tz;
  if (isObj(rawSettings) && validTz(rawSettings.tz)) return rawSettings.tz;
  return validTz(presence?.place?.timezone) ?? null;
}

export { decodePresence, decodeDevices };
