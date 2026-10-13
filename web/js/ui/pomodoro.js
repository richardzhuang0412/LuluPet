// 番茄钟 controller (PomodoroState, W1 pomodoro.js; times in Unix seconds like the Mac's `pomodoroState`). Phase ends
// are checked by the scheduler (fires in a background tab); a phase that ended > 10 min ago (page was closed) moves
// on silently. The presence `focus` field comes from focusStatus() and goes out through channel.setFocus (only
// written while this page holds my seat — the channel decides). Phase ends always fire, 勿扰 / 专注 or not.

import { v2 } from "./deps.js";
import { store } from "./store.js";

/** onEvent(event) — {type:"focusDone", next, breakMinutes} | {type:"breakDone"}; onChange(state). */
export function createPomodoro({ scheduler, config, onEvent, onChange }) {
  const P = v2.pomodoro;
  let state = P.decodeState(store.get("pomodoroState", null));
  let timer = null;
  const nowS = () => Date.now() / 1000;
  const cfg = () => P.decodeConfig(config());

  function set(next, quiet = false) {
    state = next;
    if (state.phase === "idle" && !state.completedFocus) store.remove("pomodoroState");
    else store.set("pomodoroState", state);
    arm();
    if (!quiet) onChange(state);
  }

  function arm() {
    if (timer != null) scheduler.clearTimeout(timer);
    timer = null;
    if (state.phase === "idle" || state.until == null) return;
    timer = scheduler.setTimeout(check, Math.max(500, (state.until - nowS()) * 1000 + 250));
  }

  function check(launch = false) {
    const late = launch && P.endedLongAgo(state, nowS());
    const { state: next, event } = P.advance(state, nowS(), cfg());
    if (!event) return arm();
    set(next);
    if (late) return;
    if (event.type === "focusDone") {
      const c = cfg();
      onEvent({ ...event, breakMinutes: P.minutes(event.next === "longBreak" ? c.longBreak : c.shortBreak) });
    } else onEvent(event);
  }

  check(true);

  return {
    state: () => state,
    start() { set(P.start(state, nowS(), cfg())); },
    pauseResume() { set(P.isPaused(state) ? P.resume(state, nowS()) : P.pause(state, nowS())); },
    skipBreak() { set(P.skipBreak(state)); },
    stop() { set(P.stop()); },
    /** presence `focus` {phase:"focus", until: ms} while a focus round runs (not paused), else null. */
    focus: () => P.focusStatus(state),
    focusing: () => state.phase === "focus" && !P.isPaused(state),
    stateLine: () => P.pomodoroStateLine(state, nowS()),
    durations: () => P.pomodoroDurations(cfg()),
    /** Minutes left (rounded up) for the 🍅 sign under the pet. */
    minutesLeft() { const r = P.remaining(state, nowS()); return r == null ? null : Math.max(1, Math.ceil(r / 60)); },
    isPaused: () => P.isPaused(state),
  };
}
