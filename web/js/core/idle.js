// Idle behaviour of my pet (port of IdleRules / DozeClock / RestPose in Sources/LuluCore/Idle.swift).
// Seconds on any monotonic clock. `roll(n)` → a random integer in 0..<n.

export const DOZE_AFTER = 15 * 60;
export const QUIET_AFTER = 120;
export const FIDGET_INTERVAL = Object.freeze([45, 120]);
export const RETRY = 5;

/** Seconds to the next fidget: `fixed` (≥ 0.5) if given, else 45…120 at `unit` (0…1). */
export function fidgetDelay(fixed, unit, range = FIDGET_INTERVAL) {
  if (fixed != null) return Math.max(0.5, fixed);
  const u = Math.min(1, Math.max(0, unit));
  return range[0] + (range[1] - range[0]) * u;
}

/** Index of the next fidget out of `count`, never `last` again when there is a choice; null when none. */
export function pickFidget(count, last, roll) {
  if (count <= 0) return null;
  const candidates = [...Array(count).keys()].filter((i) => i !== last || count === 1);
  return candidates[Math.min(Math.max(0, roll(candidates.length)), candidates.length - 1)];
}

/** Last interaction + dozing. state = {threshold, lastActivity, dozing}. */
export function newDozeClock(now, threshold = DOZE_AFTER) {
  return { threshold, lastActivity: now, dozing: false };
}

/** An interaction / incoming visit → {state, wokeUp}. */
export function dozeActivity(c, now) {
  return { state: { ...c, lastActivity: now, dozing: false }, wokeUp: c.dozing };
}

/** Dozing or about to: fidgets hold off. */
export function dozeIsDue(c, now) {
  return c.dozing || now >= c.lastActivity + c.threshold;
}

/** Timer check → {state, step: {type: "wait", seconds} | {type: "doze"} | {type: "none"}}. `blocked` = pet busy. */
export function dozeCheck(c, now, blocked) {
  if (c.dozing) return { state: c, step: { type: "none" } };
  const rem = c.lastActivity + c.threshold - now;
  if (rem > 0) return { state: c, step: { type: "wait", seconds: rem } };
  if (blocked) return { state: c, step: { type: "wait", seconds: RETRY } };
  return { state: { ...c, dozing: true }, step: { type: "doze" } };
}

/** "idle" | "quiet" | "doze": dozing wins; 勿扰 is always quiet; else quiet mode after QUIET_AFTER. */
export function restPose(dozing, quiet, dnd) {
  if (dozing) return "doze";
  return quiet || dnd ? "quiet" : "idle";
}

export const allowsFidgets = (pose) => pose === "idle";
