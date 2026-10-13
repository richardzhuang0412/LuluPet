// Hand-checked eye-drop rules (spec §2.4), independent of the generated vectors; plus presence.js v1 byte identity.
import { test } from "node:test";
import assert from "node:assert/strict";
import * as E from "../js/core/eyedrops.js";
import * as TZ from "../js/core/tz.js";
import * as P from "../js/core/presence.js";

const LA = "America/Los_Angeles";
const at = (d, hm, tz = LA) => E.slotInstant(d, hm, tz);
const D = "2026-10-12";
const MIN = 60_000;
const settings = { enabled: true, times: ["08:00", "12:00", "16:00", "21:00"], notify: false, at: at("2026-10-01", "09:00"), device: "mac-1" };

test("wall clock: fixed instants and DST edges (America/Los_Angeles)", () => {
  assert.equal(at(D, "08:00"), Date.UTC(2026, 9, 12, 15, 0)); // PDT = UTC−7
  assert.equal(at("2026-12-01", "08:00"), Date.UTC(2026, 11, 1, 16, 0)); // PST = UTC−8
  assert.equal(at("2026-03-08", "02:30"), Date.UTC(2026, 2, 8, 10, 0), "skipped 02:30 → the jump (03:00 PDT)");
  assert.equal(at("2026-11-01", "01:30"), Date.UTC(2026, 10, 1, 8, 30), "repeated 01:30 → first (PDT)");
  assert.equal(E.dayKey(at(D, "00:00") - 1, LA), "2026-10-11");
  assert.equal(at(D, "08:00", "Asia/Shanghai"), Date.UTC(2026, 9, 12, 0, 0));
  assert.equal(TZ.addDays("2026-12-31", 1), "2027-01-01");
  assert.equal(TZ.parseDay("2026-02-30"), null);
});

test("settings helpers", () => {
  assert.deepEqual(E.suggestedTimes(4), ["08:00", "12:00", "16:00", "20:00"]);
  assert.deepEqual(E.suggestedTimes(5), ["08:00", "11:30", "15:00", "18:30", "22:00"]);
  assert.equal(E.validateTimes(["08:00", "08:20"]).error, E.ERRORS.gap);
  assert.deepEqual(E.validateTimes(["21:00", "09:00"]), { ok: true, times: ["09:00", "21:00"], error: null });
  assert.equal(E.slotKey("08:00"), "0800");
  assert.equal(E.slotTime("0800"), "08:00");
  assert.deepEqual(E.parseSlotId(`${D}/1400`), { day: D, key: "1400", time: "14:00" });
  assert.deepEqual(E.settingsJSON(settings), settings);
  assert.equal(E.mergeSettings(settings, { ...settings, at: settings.at + 1, times: [] }).times.length, 0);
});

test("a day never answered: each slot shows exactly 3 times at +0 / +15 / +30", () => {
  let nag = null;
  const shows = {};
  for (let t = at(D, "00:00"); t < at("2026-10-13", "00:00"); t += MIN) {
    const p = E.plan({ settings, today: {}, nag, now: t, active: true, tz: LA });
    assert.ok(p.nextWakeMs > t);
    if (p.action === "show") {
      (shows[p.slot] ??= []).push((t - at(D, E.parseSlotId(p.slot).time)) / MIN);
      nag = E.afterShow(nag, p.slot, t);
    }
  }
  assert.deepEqual(shows, { [`${D}/0800`]: [0, 15, 30], [`${D}/1200`]: [0, 15, 30], [`${D}/1600`]: [0, 15, 30], [`${D}/2100`]: [0, 15, 30] });
  const p = E.progress(settings, {}, at(D, "23:59"), LA, nag);
  assert.deepEqual(p.slots.map((s) => s.state), ["missed", "missed", "missed", "unconfirmed"]);
});

test("checked in on the other device before the next nag: no more shows", () => {
  const nag = { slot: `${D}/1200`, shown: 1, next: at(D, "12:15") };
  const today = { [D]: { "1200": { done: at(D, "12:03"), device: "web-abc" } } };
  assert.equal(E.plan({ settings, today, nag, now: at(D, "12:15"), active: true, tz: LA }).action, "none");
  assert.equal(E.afterDone(nag), null);
  const p = E.progress(settings, today, at(D, "12:15"), LA);
  assert.deepEqual(p.slots[1], { time: "12:00", state: "done", device: "web-abc" });
  assert.equal(E.badge(p), "👁️ 1/4");
});

test("away / asleep: wait inside the window, missed after it", () => {
  assert.deepEqual(E.plan({ settings, today: {}, nag: null, now: at(D, "16:10"), active: false, tz: LA }),
    { action: "wait", slot: `${D}/1600`, nextWakeMs: at(D, "16:11") });
  assert.equal(E.plan({ settings, today: {}, nag: null, now: at(D, "17:59"), active: true, tz: LA }).action, "show");
  assert.equal(E.plan({ settings, today: {}, nag: null, now: at(D, "18:00"), active: true, tz: LA }).action, "none");
});

test("changing the settings today does not catch up passed slots", () => {
  const s = { ...settings, at: at(D, "12:30") };
  assert.equal(E.plan({ settings: s, today: {}, nag: null, now: at(D, "12:31"), active: true, tz: LA }).action, "none");
  assert.equal(E.plan({ settings: s, today: {}, nag: null, now: at(D, "16:00"), active: true, tz: LA }).action, "show");
});

test("bubble copy", () => {
  assert.deepEqual(E.bubbleCopy(`${D}/1400`, 3, 4), { header: "👁️💧 眼药水", line: "该滴眼药水啦（14:00 · 今天第 3 次）", done: "滴了 ✓", later: "等会儿" });
});

test("presence.js: v2 arguments absent → v1 bodies byte for byte", () => {
  const place = { name: "上海", latitude: 31.23, longitude: 121.47, timezone: "Asia/Shanghai" };
  const id = { character: "lulu", mode: "couple", device: "web-aaaa", outfit: "classic", place };
  assert.equal(JSON.stringify(P.heartbeatPayload(id, 5)),
    JSON.stringify({ lastSeen: 5, character: "lulu", mode: "couple", device: "web-aaaa", client: "web", outfit: "classic", place, pose: "idle" }));
  assert.equal(JSON.stringify(P.signOffPayload(id)),
    JSON.stringify({ lastSeen: 0, character: "lulu", mode: "couple", device: "web-aaaa", client: "web", outfit: "classic", place }));
  const v2 = P.heartbeatPayload(id, 5, { dnd: { mood: "busy", until: 0 }, focus: null, pose: "dnd" });
  assert.deepEqual(v2.dnd, { mood: "busy", until: 0 });
  assert.equal(v2.focus, undefined);
  assert.equal(v2.pose, "dnd");
  assert.equal(v2.app, undefined);
});
