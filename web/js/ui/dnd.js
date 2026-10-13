// 勿扰 controller (DoNotDisturb, W1 dnd.js). Local key `dnd` = {until (Unix SECONDS; 0 = until I turn it off), mood,
// since} like the Mac's dndUntil / dndSince; finished stretches go into `dndLog` ({start, end, mood} ms, the 记录
// divider). Timed ends fire from the scheduler. presence `dnd` goes out through channel.setDnd (written only while this
// page holds my seat; spec §4.4). Not linked to the Mac (user decision). 勿扰 holds TA's visits only — my own
// reminders still fire (user decision).

import { v2, TZ } from "./deps.js";
import { store } from "./store.js";

export function createDnd({ scheduler, onChange, onEnded }) {
  const D = v2.dnd;
  let state = D.decodeState(store.get("dnd", null));
  let timer = null;
  const nowS = () => Date.now() / 1000;

  function save() {
    if (state.until == null && state.mood === D.DEFAULT_MOOD) store.remove("dnd");
    else store.set("dnd", state);
  }
  function log(span) { if (span) store.set("dndLog", D.appendSpan(store.get("dndLog", []), span)); }
  function arm() {
    if (timer != null) scheduler.clearTimeout(timer);
    timer = null;
    const end = D.endDeadline(state);
    if (end != null) timer = scheduler.setTimeout(expire, Math.max(500, end * 1000 - Date.now() + 250));
  }
  function expire() {
    const wasOn = state.until != null;
    const { state: next, span } = D.expire(state, nowS());
    state = next;
    log(span);
    save();
    arm();
    if (wasOn && state.until == null) { onChange(); onEnded(); }
  }

  expire();
  arm();

  return {
    isOn: () => D.isOn(state, nowS()),
    mood: () => state.mood,
    /** presence `dnd` ({mood, until: ms | 0}) or null. */
    status: () => D.status(state, nowS()),
    turnOn(durationId) { state = D.turnOn(state, durationId, nowS(), TZ); save(); arm(); onChange(); },
    setMood(mood) { state = { ...state, mood }; save(); onChange(); },
    turnOff() {
      const was = state.until != null;
      const { state: next, span } = D.turnOff(state, nowS());
      state = next;
      log(span);
      save();
      arm();
      onChange();
      if (was) onEnded();
    },
    statusLine: () => D.statusLine(state, TZ),
    offTitle: () => D.offTitle(state, TZ),
    /** The sign over my pet: 「😤 生气中」… or 「🔕 勿扰中」. */
    sign: () => D.moodSign(state.mood),
    moods: D.MOODS.map((id) => ({ id, title: D.moodTitle(id) })),
    durations: D.DURATIONS.map((id) => ({ id, title: D.durationTitle(id) })),
  };
}
