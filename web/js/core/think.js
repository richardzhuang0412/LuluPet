// 想 TA / 偷看 (port of ThinkRules in Sources/LuluCore/ThinkBubble.swift, plus LocalTime.format from Weather.swift).
// Seconds on any monotonic clock for the cooldown; `nowMs` (wall clock) for the pill text.
// reason = "idle" | "hover" | "peek" | "weather:<look>".
// context = {solo, hidden, dnd, focus, quiet, visitActive, bubbleShowing, petBusy} (true = blocks).
// snapshot = weather.js `parseForecast` result; place = {name, timezone, …}.

import { emoji, isStale } from "./weather.js";
import { localParts } from "./tz.js";

export const DURATION = 6;
export const HOVER_DELAY = 1;
export const COOLDOWN = 60;
export const IDLE_RANGE = Object.freeze([20 * 60, 40 * 60]);
export const PEEK_DURATION = 9;
export const PEEK_NEVER_SEEN_TOAST = "还看不到 TA，等 TA 上线吧";
export const PEEK_VISIT_TOAST = "TA 正在你这儿呢";

const blocked = (c) => !!(c.solo || c.hidden || c.dnd || c.focus || c.quiet || c.visitActive || c.bubbleShowing || c.petBusy);

/** Next idle think after 20…40 min of active time (`unit` 0…1). */
export function idleDelay(unit) {
  return IDLE_RANGE[0] + (IDLE_RANGE[1] - IDLE_RANGE[0]) * Math.min(1, Math.max(0, unit));
}

/** → {verdict: "show" | "ignore" | "toast" | "wait", text?}. The user asked: no cooldown / dnd / focus / quiet limits. */
export function peekVerdict(c, partnerEverSeen) {
  if (c.solo || c.hidden) return { verdict: "ignore" };
  if (c.visitActive) return { verdict: "toast", text: PEEK_VISIT_TOAST };
  if (!partnerEverSeen) return { verdict: "toast", text: PEEK_NEVER_SEEN_TOAST };
  if (c.bubbleShowing) return { verdict: "wait" };
  return { verdict: "show" };
}

/** Whether the bubble may show now (weather ignores the 60 s cooldown; a clock gone back never blocks). */
export function shouldShow(reason, c, lastShown, now) {
  if (reason === "peek") return peekVerdict(c, true).verdict === "show";
  if (blocked(c)) return false;
  if (typeof reason === "string" && reason.startsWith("weather:")) return true;
  if (lastShown == null) return true;
  return now < lastShown || now - lastShown >= COOLDOWN;
}

/** TA's look changed → the look to announce (rain / snow / hot), null otherwise or for the first data. */
export function weatherTrigger(previous, hadData, current) {
  if (!hadData || current == null || current === previous) return null;
  return ["rain", "snow", "hot"].includes(current) ? current : null;
}

const HINTS = { rain: "TA 那边下雨啦", snow: "TA 那边下雪啦", hot: "TA 那边好热呀" };
export const hint = (look) => HINTS[look] ?? null;

/** The scene in the cloud: "rain" | "snow" | "sun" | "none". */
export function flourish(s) {
  if (!s) return "none";
  if (["rain", "drizzle", "thunder"].includes(s.condition)) return "rain";
  if (s.condition === "snow") return "snow";
  if (s.condition === "clear") return s.isDay ? "sun" : "none";
  return "none";
}

/** 「下午 3:20」 in `timezone` (LocalTime.format). */
export function localTimeLabel(timezone, nowMs) {
  const { hour: h, minute: m } = localParts(nowMs, timezone);
  const period = h < 6 ? "凌晨" : h < 12 ? "上午" : h < 18 ? "下午" : "晚上";
  return `${period} ${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, "0")}`;
}

const roundHalfAway = (v) => Math.sign(v) * Math.round(Math.abs(v));

/** The pill 「上海 🌧 19° · 晚上 11:42」 (weather reason: the hint leads); null without a city or fresh data. */
export function barText(reason, place, snapshot, nowMs) {
  if (!place || !snapshot || isStale(snapshot.fetchedAt, nowMs / 1000)) return null;
  let lead = place.name;
  if (typeof reason === "string" && reason.startsWith("weather:")) lead = hint(reason.slice(8)) ?? lead;
  return `${lead} ${emoji(snapshot.condition, snapshot.isDay)} ${roundHalfAway(snapshot.temperature)}° · ${localTimeLabel(place.timezone, nowMs)}`;
}

/** A peek's pill; offline: 「TA 不在线」 leads (weather kept when fresh), else just 「TA 不在线」. */
export function peekBarText(online, place, snapshot, nowMs) {
  const normal = barText("peek", place, snapshot, nowMs);
  if (online) return normal;
  if (normal == null || !place) return "TA 不在线";
  return "TA 不在线" + [...normal].slice([...place.name].length).join("");
}
