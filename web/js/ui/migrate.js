// v1 → v2 local keys (spec §4.6), run once at start before anything reads them. Pure over a {get, set, remove} store
// so web/tests can check it without a browser.
//
// v1 `reminders` = {water: {on, minutes}, stand: {on, minutes}}       → v2 `toolsSettings` (Mac format, seconds)
// v1 `reminderState` = {water: ReminderState, stand: ReminderState}   → v2 `reminder.water` / `reminder.stand`
// The pomodoro part of toolsSettings keeps the Mac defaults. Old keys are removed after the copy. An existing v2 key
// is never overwritten (a v2 page already ran).

const DEFAULT_TOOLS = {
  pomodoro: { focus: 1500, shortBreak: 300, longBreak: 900, roundsPerLong: 4 },
  waterEnabled: false, standEnabled: false, waterInterval: 3600, standInterval: 2700,
};

const minutesOk = (m) => Number.isInteger(m) && m >= 5 && m <= 240;

export function migrateV1(store) {
  const done = [];
  const old = store.get("reminders", null);
  if (old && typeof old === "object" && store.get("toolsSettings", null) == null) {
    const t = structuredClone(DEFAULT_TOOLS);
    for (const kind of ["water", "stand"]) {
      const o = old[kind];
      if (!o || typeof o !== "object") continue;
      if (typeof o.on === "boolean") t[kind + "Enabled"] = o.on;
      if (minutesOk(o.minutes)) t[kind + "Interval"] = o.minutes * 60;
    }
    store.set("toolsSettings", t);
    done.push("toolsSettings");
  }
  if (old !== null) store.remove("reminders");

  const st = store.get("reminderState", null);
  if (st && typeof st === "object") {
    for (const kind of ["water", "stand"]) {
      if (st[kind] && typeof st[kind] === "object" && store.get("reminder." + kind, null) == null) {
        store.set("reminder." + kind, st[kind]);
        done.push("reminder." + kind);
      }
    }
  }
  if (st !== null) store.remove("reminderState");
  return done;
}

export { DEFAULT_TOOLS };
