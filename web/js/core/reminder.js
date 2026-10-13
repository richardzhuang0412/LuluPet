// My own water / stand reminder (spec §13.4). Port of ActiveTimeReminder in Sources/LuluCore/PersonalTools.swift,
// including the 0.16 rules: a gap between ticks longer than awayThreshold + sleepSlack is sleep (starts over),
// idle ≥ awayThreshold starts over and clears a snooze, `resume` at launch forgets the last tick.
//
// All times are Unix SECONDS (as in LuluCore; pass Date.now() / 1000). Functions never mutate their input; each
// returns a new state. State (JSON-safe, same keys as the Swift Codable):
//   { interval, activeSeconds, lastTick: number|null, snoozeUntil: number|null, showing: boolean }
//
// "Active" on the web = IdleDetector userState "active" && screenState "unlocked" (detector threshold 300 s), or
// without it: the tab is visible or there was input in the last 5 minutes. Inactive is treated as idle ≥ 300 s.

export const AWAY_THRESHOLD = 300;
export const SNOOZE_DELAY = 600;
export const SLEEP_SLACK = 120;
export const DEFAULT_INTERVALS = { water: 3600, stand: 2700 };

export function newReminder(interval) {
  return { interval, activeSeconds: 0, lastTick: null, snoozeUntil: null, showing: false };
}

const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** Tolerant load (missing / bad keys = defaults, like the Swift decoder). */
export function decodeReminder(obj) {
  const o = obj && typeof obj === "object" ? obj : {};
  return {
    interval: num(o.interval) ?? 3600,
    activeSeconds: num(o.activeSeconds) ?? 0,
    lastTick: num(o.lastTick),
    snoozeUntil: num(o.snoozeUntil),
    showing: typeof o.showing === "boolean" ? o.showing : false,
  };
}

/** How long to wait before the next check: 60 s … interval. */
export function secondsUntilNextCheck(s) {
  const upper = Math.max(60, s.interval);
  if (s.showing) return upper;
  const left = s.activeSeconds >= s.interval ? 0 : s.interval - s.activeSeconds;
  return Math.min(upper, Math.max(60, left));
}

/**
 * Exact port of `ActiveTimeReminder.tick(now:idleSeconds:blocked:)` → {state, due}.
 * Adds the active time since the last tick (capped at max(120, 2 × secondsUntilNextCheck)); a gap longer than
 * awayThreshold + sleepSlack (sleep) or idleSeconds ≥ awayThreshold resets the count and the snooze. `due` = the
 * reminder should be shown now (state.showing becomes true); due-but-blocked stays pending.
 */
export function tickIdle(state, now, idleSeconds, blocked = false) {
  const s = { ...state };
  const cap = Math.max(120, 2 * secondsUntilNextCheck(s));
  const gap = s.lastTick == null ? null : Math.max(0, now - s.lastTick);
  const dt = gap == null ? 0 : Math.min(gap, cap);
  s.lastTick = now;
  const slept = (gap ?? 0) > AWAY_THRESHOLD + SLEEP_SLACK;
  if (idleSeconds >= AWAY_THRESHOLD || slept) {
    s.activeSeconds = 0;
    s.snoozeUntil = null;
    return { state: s, due: false };
  }
  s.activeSeconds += dt;
  const isDue = s.snoozeUntil != null ? now >= s.snoozeUntil : s.activeSeconds >= s.interval;
  if (!isDue || blocked || s.showing) return { state: s, due: false };
  s.showing = true;
  return { state: s, due: true };
}

/** Web form: `active` false = away (counts as idle ≥ 300 s). → {state, due}. Tick about once a minute. */
export function tick(state, now, active, blocked = false) {
  return tickIdle(state, now, active ? 0 : AWAY_THRESHOLD, blocked);
}

/** At page load: forget the last tick; if the page was closed longer than a normal gap (or the clock went back), start over. */
export function resume(state, now) {
  const s = { ...state };
  if (s.lastTick != null && (now - s.lastTick > AWAY_THRESHOLD + SLEEP_SLACK || now < s.lastTick)) {
    s.activeSeconds = 0;
    s.snoozeUntil = null;
  }
  s.lastTick = null;
  s.showing = false;
  return s;
}

/** 「喝了 / 好的」 or the notification was dismissed: start over. */
export function done(state, now) {
  return { ...state, activeSeconds: 0, showing: false, snoozeUntil: null, lastTick: now };
}

/** 「等会儿」: ask again after 10 minutes; the active time stays. */
export function snooze(state, now) {
  return { ...state, showing: false, snoozeUntil: now + SNOOZE_DELAY, lastTick: now };
}

/**
 * Where the cycle stands (read-only estimate between ticks) → {phase, left?}:
 * "showing" | "snoozed" (left) | "away" | "waiting" (left 0) | "counting" (left).
 */
export function status(state, now, active, blocked = false) {
  if (state.showing) return { phase: "showing" };
  if (!active) return { phase: "away" };
  if (state.snoozeUntil != null) return { phase: "snoozed", left: Math.max(0, state.snoozeUntil - now) };
  const cap = Math.max(120, 2 * secondsUntilNextCheck(state));
  const active2 = state.activeSeconds + (state.lastTick == null ? 0 : Math.min(Math.max(0, now - state.lastTick), cap));
  const left = Math.max(0, state.interval - active2);
  return left === 0 && blocked ? { phase: "waiting", left: 0 } : { phase: "counting", left };
}

/** Notification copy for my own reminder (PersonalToolsController / ToolsCopy). */
export function reminderCopy(kind) {
  return kind === "water"
    ? { title: "该喝水啦 💧", comply: "喝了", snooze: "等会儿" }
    : { title: "站起来动一动～", comply: "好的", snooze: "等会儿" };
}
