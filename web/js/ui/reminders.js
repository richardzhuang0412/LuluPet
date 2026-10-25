// My own water / stand reminders (ActiveTimeReminder port, W1 reminder.js). v2 keys in the Mac format (spec §4.6):
// `toolsSettings` (waterEnabled / waterInterval … seconds), `reminder.water` / `reminder.stand` (cycle state),
// `waterLog` {day, cups}. Ticks once a minute. 勿扰 / 专注 never hold them on the web (user decision, 2026-10-12): only
// TA's messages wait; my own reminders come with sound and notification.
// Also the 「等会儿」 follow-up for TA's reminders (`remindSnooze.<kind>` = {ackOf, at (Unix s)}): 10 minutes after I
// answered 等会儿 the pet asks again; 喝了 / 好的 within 2 h sends TA a 「终于做到了」 (late) reply.

import { reminders as R, reminderStatus, v2 } from "./deps.js";
import { store } from "./store.js";
import { isActive } from "./activity.js";

const TICK_MS = 60_000;
const SNOOZE_S = 600;
const LATE_WINDOW_S = 2 * 3600;

const today = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};

const posInt = (v, d) => (Number.isFinite(v) && v > 0 ? v : d);
/** `toolsSettings` (Mac format, seconds; missing / bad keys = defaults, reminders off). */
export function decodeTools(o) {
  const x = o && typeof o === "object" && !Array.isArray(o) ? o : {};
  return {
    pomodoro: v2.pomodoro.decodeConfig(x.pomodoro),
    waterEnabled: x.waterEnabled === true, standEnabled: x.standEnabled === true,
    waterInterval: posInt(x.waterInterval, R.defaults.water), standInterval: posInt(x.standInterval, R.defaults.stand),
  };
}
export function loadTools() { return decodeTools(store.get("toolsSettings", null)); }

/**
 * The 小工具 wording (W1 ToolsCopy) with the web's behaviour: 勿扰 / 专注 never hold my own reminders here, and the
 * web can't see full screen. The Mac copy is changed separately.
 */
export const toolsCopy = {
  name: (k) => v2.pomodoro.reminderName(k),
  emoji: (k) => v2.pomodoro.reminderEmoji(k),
  pomodoroHint: "专注一段时间，到点宠物提醒你休息；专注中宠物安静，TA 的消息先攒着，喝水 / 站立 / 眼药水照常提醒",
  explanation(k, interval) {
    const act = k === "water" ? "喝水" : "起来动一动";
    const tail = k === "water" ? "点「喝了」记一杯；" : "点「好的」收到；";
    return `开着的话，你用电脑累计满 ${v2.pomodoro.minutes(interval)} 分钟，宠物会跑出来提醒你${act}。${tail}「等会儿」10 分钟后再提醒。`
      + "离开电脑 5 分钟以上会重新计时；勿扰、专注时也照常提醒。";
  },
  cycleLine(k, status) {
    if (status?.phase === "waiting") return `到点啦，马上提醒你${k === "water" ? "喝水" : "起来动动"}`;
    return v2.pomodoro.cycleLine(k, status);
  },
};

/** onFire(kind, {partnerAck}) — show the reminder (partnerAck = the TA reminder key when this is the 等会儿 follow-up). */
export function createReminders({ onFire }) {
  const isBlocked = () => false;
  let settings = loadTools();
  const states = {};
  const nowS = () => Date.now() / 1000;
  const enabled = (k) => settings[k + "Enabled"];
  const interval = (k) => settings[k + "Interval"];

  function build(kind) {
    if (!enabled(kind)) { delete states[kind]; store.remove("reminder." + kind); return; }
    if (states[kind]) { states[kind] = { ...states[kind], interval: interval(kind) }; return; }
    const saved = store.get("reminder." + kind, null);
    const loaded = saved ? R.load(saved) : R.fresh(interval(kind));
    states[kind] = R.resume({ ...loaded, interval: interval(kind) }, nowS());
  }
  const save = (kind) => { if (states[kind]) store.set("reminder." + kind, states[kind]); };

  function snoozeFollowUp(kind, now) {
    const s = store.get("remindSnooze." + kind, null);
    if (!s || typeof s.ackOf !== "string" || !Number.isFinite(s.at)) return;
    if (now - s.at > LATE_WINDOW_S) { store.remove("remindSnooze." + kind); return; }
    if (s.fired || now - s.at < SNOOZE_S || isBlocked() || !isActive()) return;
    store.set("remindSnooze." + kind, { ...s, fired: true });
    onFire(kind, { partnerAck: s.ackOf });
  }

  function tick() {
    const now = nowS();
    const active = isActive();
    const blocked = isBlocked();
    for (const kind of ["water", "stand"]) {
      snoozeFollowUp(kind, now);
      if (!states[kind]) continue;
      const { state, due } = R.tick(states[kind], now, active, blocked);
      states[kind] = state;
      save(kind);
      if (due) onFire(kind, {});
    }
  }

  build("water");
  build("stand");
  setInterval(tick, TICK_MS);

  function countCup() {
    const log = store.get("waterLog", null);
    const cups = log?.day === today() && Number.isInteger(log.cups) ? log.cups : 0;
    store.set("waterLog", { day: today(), cups: cups + 1 });
  }

  return {
    settings: () => settings,
    /** next = the whole toolsSettings object (pomodoro included). */
    update(next) {
      settings = decodeTools(next);
      store.set("toolsSettings", settings);
      build("water");
      build("stand");
      save("water");
      save("stand");
    },
    /** 喝了 / 好的. Returns the TA reminder key to answer 「终于做到了」, if this closes a 等会儿 follow-up. */
    done(kind) {
      if (states[kind]) { states[kind] = R.done(states[kind], nowS()); save(kind); }
      if (kind === "water") countCup();
      const s = store.get("remindSnooze." + kind, null);
      store.remove("remindSnooze." + kind);
      return s && typeof s.ackOf === "string" && nowS() - s.at <= LATE_WINDOW_S ? s.ackOf : null;
    },
    snooze(kind) {
      if (states[kind]) { states[kind] = R.snooze(states[kind], nowS()); save(kind); }
      const s = store.get("remindSnooze." + kind, null);
      if (s) store.set("remindSnooze." + kind, { ackOf: s.ackOf, at: nowS() });   // asks again in 10 minutes
    },
    /** I answered TA's reminder 等会儿: remember it for the follow-up (Mac `remindSnooze` format). */
    partnerSnoozed(kind, ackOf) { store.set("remindSnooze." + kind, { ackOf, at: nowS() }); },
    partnerDone(kind) { store.remove("remindSnooze." + kind); if (kind === "water") countCup(); },
    cups() {
      const log = store.get("waterLog", null);
      return log?.day === today() && Number.isInteger(log.cups) ? log.cups : 0;
    },
    /** 小工具 card line: ToolsCopy.cycleLine. */
    cycleLine(kind) {
      if (!states[kind]) return "";
      return toolsCopy.cycleLine(kind, reminderStatus(states[kind], nowS(), isActive(), isBlocked()));
    },
    /** Raw status {phase, left?} (null when off) — the 极简模式 strip. */
    status(kind) { return states[kind] ? reminderStatus(states[kind], nowS(), isActive(), isBlocked()) : null; },
    copy: (kind) => R.copy(kind),
  };
}
