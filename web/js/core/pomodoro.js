// 番茄钟 (port of PomodoroConfig / PomodoroState / FocusStatus in Sources/LuluCore/PersonalTools.swift) and the
// 小工具 wording (ToolsCopy.swift). Times are Unix SECONDS like the Mac (`pomodoroState`); presence `focus` is ms.
//   config = {focus: 1500, shortBreak: 300, longBreak: 900, roundsPerLong: 4}
//   state  = {phase: "idle"|"focus"|"shortBreak"|"longBreak", until: s|null, pausedRemaining: s|null, completedFocus}
// Every function returns a new state; inputs are never mutated. A phase end always fires (勿扰 / 专注 never hold
// my own tools).

export const PHASES = ["idle", "focus", "shortBreak", "longBreak"];
export const LAUNCH_GRACE = 600;
export const DEFAULT_CONFIG = Object.freeze({ focus: 1500, shortBreak: 300, longBreak: 900, roundsPerLong: 4 });
export const IDLE = Object.freeze({ phase: "idle", until: null, pausedRemaining: null, completedFocus: 0 });

const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

/** Tolerant config (missing keys = defaults; roundsPerLong ≥ 1). */
export function decodeConfig(obj) {
  const o = isObj(obj) ? obj : {};
  const r = num(o.roundsPerLong);
  return {
    focus: num(o.focus) ?? DEFAULT_CONFIG.focus,
    shortBreak: num(o.shortBreak) ?? DEFAULT_CONFIG.shortBreak,
    longBreak: num(o.longBreak) ?? DEFAULT_CONFIG.longBreak,
    roundsPerLong: Math.max(1, r != null && Number.isInteger(r) ? r : DEFAULT_CONFIG.roundsPerLong),
  };
}

/** Tolerant state; a running phase with neither deadline nor paused remainder is corrupt → idle. */
export function decodeState(obj) {
  const o = isObj(obj) ? obj : {};
  const s = {
    phase: PHASES.includes(o.phase) ? o.phase : "idle",
    until: num(o.until),
    pausedRemaining: num(o.pausedRemaining),
    completedFocus: Number.isInteger(o.completedFocus) ? o.completedFocus : 0,
  };
  if (s.phase !== "idle" && s.until == null && s.pausedRemaining == null) return { ...IDLE };
  return s;
}

export function isPaused(s) {
  return s.phase !== "idle" && s.until == null && s.pausedRemaining != null;
}

/** Seconds left in the running / paused phase; null when idle. */
export function remaining(s, now) {
  if (s.phase === "idle") return null;
  if (s.pausedRemaining != null && s.until == null) return s.pausedRemaining;
  return s.until == null ? null : Math.max(0, s.until - now);
}

/** A phase that ended more than `grace` s ago (page closed / laptop asleep) moves on silently at load. */
export function endedLongAgo(s, now, grace = LAUNCH_GRACE) {
  if (s.phase === "idle" || s.until == null || now < s.until) return false;
  return now - s.until > grace;
}

/** Starts a focus round (also restarts one in progress; the round count is kept, reset after a long break). */
export function start(s, now, config = DEFAULT_CONFIG) {
  return { ...s, completedFocus: s.phase === "longBreak" ? 0 : s.completedFocus, phase: "focus", until: now + config.focus, pausedRemaining: null };
}

export function pause(s, now) {
  if (s.phase === "idle" || isPaused(s) || s.until == null) return s;
  return { ...s, pausedRemaining: Math.max(0, s.until - now), until: null };
}

export function resume(s, now) {
  if (!isPaused(s)) return s;
  return { ...s, until: now + s.pausedRemaining, pausedRemaining: null };
}

/** Back to idle; the round count restarts. */
export function stop() {
  return { ...IDLE };
}

function endBreak(s) {
  return { ...s, completedFocus: s.phase === "longBreak" ? 0 : s.completedFocus, phase: "idle", until: null, pausedRemaining: null };
}

/** Skip a break: idle until the next round is started. */
export function skipBreak(s) {
  return s.phase === "shortBreak" || s.phase === "longBreak" ? endBreak(s) : s;
}

/**
 * Moves on when the phase is over → {state, event}: focus → short / long break (event {type: "focusDone", next}),
 * break → idle ({type: "breakDone"}). event null when not due / paused / idle. Phases missed while asleep advance
 * ONE step; the next phase counts from `now`.
 */
export function advance(s, now, config = DEFAULT_CONFIG) {
  if (s.phase === "idle" || s.until == null || now < s.until) return { state: s, event: null };
  if (s.phase === "focus") {
    const completedFocus = s.completedFocus + 1;
    const next = completedFocus >= config.roundsPerLong ? "longBreak" : "shortBreak";
    return {
      state: { ...s, completedFocus, phase: next, until: now + (next === "longBreak" ? config.longBreak : config.shortBreak) },
      event: { type: "focusDone", next },
    };
  }
  return { state: endBreak(s), event: { type: "breakDone" } };
}

/** Presence `focus` while focusing and not paused: {phase: "focus", until: ms}; else null. */
export function focusStatus(s) {
  if (s.phase !== "focus" || s.until == null) return null;
  return { phase: "focus", until: Math.round(s.until * 1000) };
}

// ---- ToolsCopy

/** Whole minutes of a seconds value. */
export const minutes = (seconds) => Math.round(seconds / 60);
export const reminderName = (kind) => (kind === "water" ? "喝水提醒" : "站立提醒");
export const reminderEmoji = (kind) => (kind === "water" ? "💧" : "🧍");

/** 「喝水提醒 💧（每用电脑 60 分钟）」. */
export function menuTitle(kind, interval) {
  return `${reminderName(kind)} ${reminderEmoji(kind)}（每用电脑 ${minutes(interval)} 分钟）`;
}

/** The full explanation (Mac wording, ToolsCopy.explanation). */
export function explanation(kind, interval) {
  const act = kind === "water" ? "喝水" : "起来动一动";
  const tail = kind === "water" ? "点「喝了」记一杯；" : "点「好的」收到；";
  return `开着的话，你用电脑累计满 ${minutes(interval)} 分钟，宠物会跑出来提醒你${act}。${tail}「等会儿」10 分钟后再提醒。`
    + "离开电脑 5 分钟以上会重新计时；全屏或隐藏时先等等；勿扰、专注时照常提醒。";
}

export function menuHint(kind) {
  return kind === "water" ? "累计用电脑满间隔，宠物来提醒你喝水" : "累计用电脑满间隔，宠物来提醒你起来动动";
}

export const POMODORO_HINT = "专注一段时间，到点宠物提醒你休息；专注中宠物安静（喝水、站立、眼药水提醒照常）";

/** 「25 分钟专注 / 5 分钟休息」. */
export function pomodoroDurations(c) {
  return `${minutes(c.focus)} 分钟专注 / ${minutes(c.shortBreak)} 分钟休息`;
}

/** 没在专注 / 专注中 还剩 N 分钟 / 已暂停（…）/ 休息中 还剩 N 分钟. */
export function pomodoroStateLine(s, now) {
  const r = remaining(s, now);
  const left = r == null ? 0 : Math.max(1, Math.ceil(r / 60));
  if (s.phase === "idle") return "没在专注";
  if (s.phase === "focus") return isPaused(s) ? `已暂停（专注还剩 ${left} 分钟）` : `专注中 还剩 ${left} 分钟`;
  return isPaused(s) ? `已暂停（休息还剩 ${left} 分钟）` : `休息中 还剩 ${left} 分钟`;
}

/** The live line under a reminder; `status` = reminder.js `status()` → {phase, left?}. */
export function cycleLine(kind, status) {
  const what = kind === "water" ? "喝水" : "起来动动";
  const mins = (t) => Math.max(1, Math.ceil(t / 60));
  switch (status.phase) {
    case "showing": return `正在提醒你${what} ⏰`;
    case "snoozed": return `「等会儿」：${mins(status.left)} 分钟后再提醒`;
    case "away": return "你离开电脑了，回来后重新计时";
    case "waiting": return "到点啦，等宠物出来就提醒";
    default: return status.left <= 0 ? `马上提醒你${what}` : `还差约 ${mins(status.left)} 分钟提醒你${what}（只算用电脑的时间）`;
  }
}
