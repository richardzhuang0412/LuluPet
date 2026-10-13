// 眼药水 controller (spec §2): local mirror `eyedrops` {settings, days (last 14)}, `eyedropsNag`, `eyedropsPending`;
// W1 eyedrops.js decides (plan / progress / merge), W3 tools-sync talks to `tools/{seat}/eyedrops`. Re-plans every
// minute (scheduler: keeps firing in a background tab) and at plan.nextWakeMs. Before every show / re-show it GETs
// that day's check-ins (3 s timeout) so a 滴了 on the Mac stops the nag here. Fires during 勿扰 / 专注 too, with
// sound and notification (user decision).

import { v2, TZ } from "./deps.js";
import { store } from "./store.js";
import { isActive } from "./activity.js";

const SETTINGS_EVERY_MS = 10 * 60_000;
const KEEP_DAYS = 14;
const DEFAULT_COUNT = 4;

/**
 * show({slot, copy:{header,line,done,later}, shown, notify}) — put the bubble up (replacing an older one) and notify.
 * hide() — take bubble + notification away. onChange() — re-render cards / title.
 */
export function createEyedrops({ sync, deviceId, scheduler, show, hide, onChange, log = () => {} }) {
  const E = v2.eyedrops;
  const now = () => Date.now();
  const blank = () => ({ enabled: false, times: [], notify: false, at: 0, device: "" });
  let { settings, days } = E.decodeEyedrops(store.get("eyedrops", null));
  settings = settings ?? blank();
  let nag = E.decodeNag(store.get("eyedropsNag", null), now());
  let pending = Array.isArray(store.get("eyedropsPending", null)) ? store.get("eyedropsPending") : [];
  let timer = null;
  let syncState = "local";      // "ok" | "local" | "failed"
  let showingSlot = null;
  let busy = false;

  const todayKey = () => E.dayKey(now(), TZ);

  function persist() {
    const keep = Object.keys(days).sort().slice(-KEEP_DAYS);
    days = Object.fromEntries(keep.map((k) => [k, days[k]]));
    store.set("eyedrops", { settings: E.settingsJSON(settings), days });
    if (nag) store.set("eyedropsNag", nag); else store.remove("eyedropsNag");
    if (pending.length) store.set("eyedropsPending", pending); else store.remove("eyedropsPending");
    onChange();
  }

  // ---- remote ----
  async function flushPending() {
    if (!sync || !pending.length) return;
    const left = [];
    for (const op of pending) {
      try {
        if (op.op === "settings") await sync.putSettings(E.settingsJSON(settings));
        else if (op.op === "done") await sync.putDone(op.day, op.slot, op.entry);
        else if (op.op === "undo") await sync.deleteDone(op.day, op.slot);
      } catch { left.push(op); }
    }
    pending = left;
    syncState = left.length ? "failed" : "ok";
    persist();
  }
  async function remote(op, fn) {
    if (!sync) return;
    try { await fn(); syncState = "ok"; } catch (e) {
      console.warn("[lulu] eyedrops sync", e);
      if (op.op === "settings") pending = pending.filter((p) => p.op !== "settings");
      pending.push(op);
      syncState = "failed";
    }
    persist();
  }

  async function pullSettings() {
    if (!sync) return;
    try {
      const remoteS = E.decodeSettings(await sync.getSettings());
      const merged = E.mergeSettings(settings, remoteS);
      if (merged !== settings) { settings = merged; persist(); }
      if (settings.at > 0 && settings.at > (remoteS?.at ?? -1)) await sync.putSettings(E.settingsJSON(settings));
      syncState = "ok";
      await flushPending();
    } catch (e) {
      syncState = "failed";
      console.warn("[lulu] eyedrops settings", e);
    }
    onChange();
    replan();
  }

  /** That day's check-ins from the remote; my own not-yet-written ones are kept. */
  async function pullDay(day) {
    if (!sync) return;
    try {
      const got = E.decodeDays({ [day]: await sync.getDay(day, { timeoutMs: 3000 }) })[day] ?? {};
      const mine = days[day] ?? {};
      const unsent = Object.fromEntries(Object.entries(mine).filter(([k]) => !got[k] && pending.some((p) => p.op === "done" && p.day === day && p.slot === k)));
      days[day] = { ...got, ...unsent };
      persist();
    } catch { /* 3 s timeout / offline: go by the local mirror */ }
  }

  // ---- planning ----
  function arm(at) {
    if (timer != null) scheduler.clearTimeout(timer);
    timer = scheduler.setTimeout(replan, Math.max(1000, Math.min(at - now(), 60_000)));
  }
  const planNow = () => E.plan({ settings, today: days, nag: E.decodeNag(nag, now()), now: now(), active: isActive(), tz: TZ });

  async function replan() {
    if (busy) return arm(now() + 5000);
    busy = true;
    try {
      let p = planNow();
      if (showingSlot && p.slot !== showingSlot) { hide(); showingSlot = null; }       // superseded / past its window
      if (p.action === "show") {
        const at = E.parseSlotId(p.slot);
        await pullDay(at.day);
        if (days[at.day]?.[at.key]) {
          log(`eyedrops: skip ${at.key} done-elsewhere`);
          if (showingSlot === p.slot) { hide(); showingSlot = null; }
          nag = E.afterDone(nag);
          persist();
          p = planNow();
        }
      }
      if (p.action === "show") {
        const at = E.parseSlotId(p.slot);
        nag = E.afterShow(nag, p.slot, now());
        persist();
        const index = settings.times.indexOf(at.time) + 1;
        showingSlot = p.slot;
        show({ slot: p.slot, copy: E.bubbleCopy(p.slot, index, settings.times.length), shown: nag.shown, notify: settings.notify });
        log(`eyedrops: shown ${at.key} #${nag.shown}`);
        p = planNow();
      }
      arm(p.nextWakeMs);
    } finally { busy = false; }
  }

  // ---- actions ----
  function markDone(slot) {
    const at = E.parseSlotId(slot);
    if (!at) return;
    const entry = { done: now(), device: deviceId };
    days[at.day] = { ...(days[at.day] ?? {}), [at.key]: entry };
    if (nag?.slot === slot) nag = E.afterDone(nag);
    if (showingSlot === slot) { hide(); showingSlot = null; }
    persist();
    log(`eyedrops: done ${at.key} (${sync ? "remote" : "local"})`);
    remote({ op: "done", day: at.day, slot: at.key, entry }, () => sync.putDone(at.day, at.key, entry));
    replan();
  }

  function undo(slot) {
    const at = E.parseSlotId(slot);
    const e = at ? days[at.day]?.[at.key] : null;
    if (!e || e.device !== deviceId) return false;      // only my own check-ins
    const d = { ...days[at.day] };
    delete d[at.key];
    days[at.day] = d;
    pending = pending.filter((p) => !(p.op === "done" && p.day === at.day && p.slot === at.key));
    persist();
    remote({ op: "undo", day: at.day, slot: at.key }, () => sync.deleteDone(at.day, at.key));
    replan();
    return true;
  }

  /** 等会儿 / dismissed: only the bubble goes (nag.next is already 15 minutes out). */
  function later() {
    if (showingSlot) { hide(); showingSlot = null; }
  }

  function apply(next) {
    settings = { ...settings, ...next, at: now(), device: deviceId };
    if (settings.enabled && !settings.times.length) settings.times = E.suggestedTimes(DEFAULT_COUNT);
    persist();
    remote({ op: "settings" }, () => sync.putSettings(E.settingsJSON(settings)));
    replan();
  }

  const progress = () => E.progress(settings, days, now(), TZ, E.decodeNag(nag, now()));

  setInterval(() => replan(), 60_000);
  setInterval(() => pullSettings(), SETTINGS_EVERY_MS);
  if (sync) pullSettings(); else replan();

  return {
    settings: () => settings,
    progress,
    todaySlot: (time) => E.slotId(todayKey(), time),
    entry: (time) => days[todayKey()]?.[E.slotKey(time)] ?? null,
    /** Today's `time` had already passed when the settings were last changed today (so it isn't reminded today). */
    beforeSetup: (time) => settings.at > 0 && E.dayKey(settings.at, TZ) === todayKey() && E.slotInstant(todayKey(), time, TZ) < settings.at,
    showing: () => showingSlot,
    syncLine: () => (!sync ? "只在这个浏览器" : syncState === "ok" ? "已和家里的 Mac 同步 ✓" : syncState === "failed" ? "同步失败，稍后重试" : "同步中…"),
    /** Title / PiP bar: 「👁️ 2/4」, 「👁️ 该滴了」 while a reminder is up; "" when off. */
    titleBit() {
      if (!settings.enabled) return "";
      return showingSlot ? "👁️ 该滴了" : E.badge(progress());
    },
    markDone, undo, later, apply,
    refresh: () => pullSettings(),
    suggested: (n) => E.suggestedTimes(n),
    validate: (times) => E.validateTimes(times),
    defaultCount: DEFAULT_COUNT,
  };
}
