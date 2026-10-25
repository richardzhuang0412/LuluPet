// TA's answer to 「叫 TA 喝水 / 起来动动」. Port of Sources/LuluCore/RemindReply.swift (+ Visits.isRemindAck).
//
// Wire encoding (docs/upgrade-compat.md §6):
//   now:   {kind:"remind", remind:"water", ackOf:<id>, answer:"now"}
//   later: {kind:"remind", remind:"water.later", ackOf:<id>, answer:"later"}  (remind deliberately not a plain kind)
//   late:  a `now` reply with late:true (read only; web v1 never sends it)

import { CURRENT_SCHEMA_VERSION, TRIP_LOCAL } from "./message.js";

export const REMINDER_KINDS = ["water", "stand"];
export const LATER_SUFFIX = ".later";
/** Reminders younger than this still get 「马上 / 等会儿」 buttons in the away card (ms). */
export const REPLY_WINDOW_MS = 2 * 3600 * 1000;

/** A remind message with `ackOf` (any reply / receipt, known value or not). */
export function isRemindAck(msg) {
  return msg.kind === "remind" && msg.ackOf != null;
}

/**
 * The reply message answering reminder `ackOf`. `kind` "water" | "stand", `answer` "now" | "later".
 * `look` (optional) = {character, outfit} of my seat, as on every web message; `trip` is "local".
 */
export function replyMessage(kind, answer, from, ackOf, ts, look = {}) {
  const m = { from, kind: "remind", ts, v: CURRENT_SCHEMA_VERSION, trip: TRIP_LOCAL };
  m.remind = answer === "later" ? kind + LATER_SUFFIX : kind;
  m.ackOf = ackOf;
  m.answer = answer === "later" ? "later" : "now";
  if (look.character != null) m.character = look.character;
  if (look.outfit != null) m.outfit = look.outfit;
  return m;
}

/**
 * Reads a `remind` message with `ackOf` as a reply → {kind, answer, late} | null (not a reply / unknown remind value).
 * A receipt without `answer` (v0.10–v0.14.3) is a plain "now"; an unknown answer is "now"; `late` only with "now".
 */
export function decodeReply(msg) {
  if (msg.kind !== "remind" || msg.ackOf == null || typeof msg.remind !== "string") return null;
  const raw = msg.remind;
  if (raw.endsWith(LATER_SUFFIX)) {
    const kind = raw.slice(0, -LATER_SUFFIX.length);
    return REMINDER_KINDS.includes(kind) ? { kind, answer: "later", late: false } : null;
  }
  if (!REMINDER_KINDS.includes(raw)) return null;
  // Swift: answer "later" on a plain kind reads as now; anything unknown / missing → now.
  return { kind: raw, answer: "now", late: msg.late === true };
}

/** The line on my side: 「TA 说马上喝 💧」 etc. */
export function replyLine(reply) {
  const { kind, answer, late } = reply;
  if (late) return kind === "water" ? "TA 终于喝啦 💧" : "TA 终于起来动啦";
  if (answer === "now") return kind === "water" ? "TA 说马上喝 💧" : "TA 说马上起来动动";
  return kind === "water" ? "TA 说等会儿再喝 ⏰" : "TA 说等会儿再动";
}

/** Copy of the bubble for TA's 「叫你喝水 / 起来动动」 (Visits.remindBubble); `sender` = TA's display name. */
export function remindBubble(kind, sender) {
  return kind === "water"
    ? { header: `${sender}说：`, line: `${sender}叫你喝水啦 💧`, comply: "喝了 ✓", snooze: "等会儿" }
    : { header: `${sender}说：`, line: `${sender}叫你起来动动 🧍`, comply: "好的 ✓", snooze: "等会儿" };
}

/** A partner reminder (not a reply) of a known kind: "water" | "stand", else null. */
export function reminderKind(msg) {
  if (msg.kind !== "remind" || msg.ackOf != null) return null;
  return REMINDER_KINDS.includes(msg.remind) ? msg.remind : null;
}

/** A partner reminder that may still be answered 「马上 / 等会儿」 (at most 2 hours old). */
export function isReplyable(msg, now) {
  return reminderKind(msg) !== null && now - msg.ts <= REPLY_WINDOW_MS;
}
