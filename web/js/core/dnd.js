// 勿扰 (port of DNDMood / DNDDuration / DNDState / DNDSpan / DND in Sources/LuluCore/DoNotDisturb.swift).
// State times are Unix SECONDS like the Mac (`dndUntil` / `dndSince`); presence and spans are ms.
//   state = {until: number|null (0 = until turned off), mood, since: number|null}   (local key `lulupet.dnd`)
//   span  = {start: ms, end: ms, mood}                                               (local key `lulupet.dndLog`)
// 勿扰 holds partner visits (queued, shown as a card when it ends); it never holds my own reminders.

import { partnerDNDLine } from "./presence.js";
import { localParts, localToMs, addDays, dayString, hhmm } from "./tz.js";

export const MOODS = ["angry", "busy", "resting", "unsaid"];
export const DEFAULT_MOOD = "unsaid";
export const DURATIONS = ["thirtyMinutes", "oneHour", "today", "untilOff"];
export const MAX_LOG = 500;

const MOOD_EMOJI = { angry: "😤", busy: "💼", resting: "😴", unsaid: "🤐" };
const MOOD_TITLE = { angry: "😤 生气中", busy: "💼 忙碌中", resting: "😴 休息中", unsaid: "🤐 不说原因" };
const DURATION_TITLE = { thirtyMinutes: "30 分钟", oneHour: "1 小时", today: "今天之内", untilOff: "直到我关掉" };

const knownMood = (m) => (MOODS.includes(m) ? m : null);

export const moodEmoji = (m) => MOOD_EMOJI[m] ?? null;
/** Menu title 「😤 生气中」…「🤐 不说原因」. */
export const moodTitle = (m) => MOOD_TITLE[m] ?? null;
/** What the partner is told; null = no reason (unsaid / unknown). */
export const moodReason = (m) => (knownMood(m) && m !== "unsaid" ? MOOD_TITLE[m] : null);
/** The sign above my pet: the reason, or 「🔕 勿扰中」. */
export const moodSign = (m) => moodReason(m) ?? "🔕 勿扰中";
export const durationTitle = (d) => DURATION_TITLE[d] ?? null;

/** End of a duration in Unix seconds; 0 = until turned off; `today` = the next local midnight in `tz`. */
export function durationUntil(duration, now, tz) {
  switch (duration) {
    case "thirtyMinutes": return now + 30 * 60;
    case "oneHour": return now + 60 * 60;
    case "untilOff": return 0;
    case "today": {
      const tomorrow = addDays(dayString(now * 1000, tz), 1);
      const [y, m, d] = tomorrow.split("-").map(Number);
      return localToMs(y, m, d, 0, 0, tz) / 1000;
    }
    default: return null;
  }
}

export function newState(mood = DEFAULT_MOOD) {
  return { until: null, mood, since: null };
}

const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
/** Tolerant load of `lulupet.dnd` (bad data = off, default mood). */
export function decodeState(obj) {
  const o = obj && typeof obj === "object" ? obj : {};
  return { until: num(o.until), mood: knownMood(o.mood) ?? DEFAULT_MOOD, since: num(o.since) };
}

export function isOn(s, now) {
  return s.until != null && (s.until === 0 || now < s.until);
}

/** When a timed 勿扰 must be closed (also after it passed); null = off / until turned off. */
export function endDeadline(s) {
  return s.until != null && s.until > 0 ? s.until : null;
}

/** 开启 (or re-set the end while on; the start stays). */
export function turnOn(s, duration, now, tz) {
  return { ...s, since: isOn(s, now) ? s.since : now, until: durationUntil(duration, now, tz) };
}

/** 关闭 by hand → {state, span (null when it wasn't on)}. */
export function turnOff(s, now) {
  if (s.until == null) return { state: s, span: null };
  const end = s.until === 0 ? now : Math.min(now, s.until);
  const span = s.since == null ? null
    : { start: Math.trunc(s.since * 1000), end: Math.trunc(Math.max(s.since, end) * 1000), mood: s.mood };
  return { state: { ...s, until: null, since: null }, span };
}

/** A timed 勿扰 whose time is up ends (also after sleeping through it) → {state, span} (span null = nothing ended). */
export function expire(s, now) {
  if (s.until == null || !(s.until > 0) || now < s.until) return { state: s, span: null };
  return turnOff(s, s.until);
}

/** For presence: {mood, until: ms | 0}, null while off. */
export function status(s, now) {
  if (!isOn(s, now)) return null;
  return { mood: s.mood, until: s.until === 0 ? 0 : Math.trunc(s.until * 1000) };
}

function endLabel(s, tz) {
  if (s.until == null || !(s.until > 0)) return "手动关闭";
  const p = localParts(s.until * 1000, tz);
  const hh = p.hour === 0 && p.minute === 0 ? 24 : p.hour;
  return `${String(hh).padStart(2, "0")}:${String(p.minute).padStart(2, "0")} 结束`;
}

/** Menu: 「关闭勿扰（15:10 结束）」 / 「关闭勿扰（手动关闭）」 (「24:00」 for 今天之内). */
export function offTitle(s, tz) {
  return `关闭勿扰（${endLabel(s, tz)}）`;
}

/** Status line: 「🔕 我勿扰中（😤 生气中 · 15:10 结束）」. */
export function statusLine(s, tz) {
  const r = moodReason(s.mood);
  return `🔕 我勿扰中（${r ? `${r} · ` : ""}${endLabel(s, tz)}）`;
}

/** History divider: 「😤 勿扰中 14:05–15:10」 (no reason: 🔕). */
export function spanLabel(span, tz) {
  const e = knownMood(span.mood) && span.mood !== "unsaid" ? MOOD_EMOJI[span.mood] : "🔕";
  return `${e} 勿扰中 ${hhmm(span.start, tz)}–${hhmm(span.end, tz)}`;
}

/** `dndLog` append, keeping the newest 500. */
export function appendSpan(log, span) {
  return [...(Array.isArray(log) ? log : []), span].slice(-MAX_LOG);
}

/** Partner status line 「TA 勿扰中（😤 生气中）」 / 「TA 勿扰中」. */
export const partnerStatusLine = partnerDNDLine;

/** Our pet is back from a partner in 勿扰. */
export function bounceLine(partnerDnd) {
  const r = moodReason(partnerDnd?.mood);
  return r ? `TA 开了勿扰（${r}），先放在 TA 那儿啦` : "TA 开了勿扰，先放在 TA 那儿啦";
}

/** Card when 勿扰 ends. */
export function cardTitle(count) {
  return `你勿扰的时候，TA 来找过你 ${count} 次～`;
}
