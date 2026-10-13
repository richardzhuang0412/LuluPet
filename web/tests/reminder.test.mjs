import { test } from "node:test";
import assert from "node:assert/strict";
import * as RM from "../js/core/reminder.js";

test("web tick: active counts, inactive (away) starts over", () => {
  let s = RM.newReminder(120);
  let r = RM.tick(s, 0, true); s = r.state; assert.equal(r.due, false);
  r = RM.tick(s, 60, true); s = r.state; assert.equal(s.activeSeconds, 60);
  r = RM.tick(s, 120, true); s = r.state; assert.equal(r.due, true); assert.equal(s.showing, true);
  r = RM.tick(s, 180, true); assert.equal(r.due, false, "no repeat while showing");
  s = RM.snooze(r.state, 181);
  assert.equal(s.snoozeUntil, 781);
  r = RM.tick(s, 240, false); s = r.state;
  assert.equal(s.activeSeconds, 0); assert.equal(s.snoozeUntil, null, "away clears the snooze");
});

test("inputs are not mutated", () => {
  const s = RM.newReminder(60);
  const frozen = Object.freeze({ ...s });
  RM.tick(frozen, 10, true); RM.done(frozen, 1); RM.snooze(frozen, 1); RM.resume(frozen, 1);
  assert.deepEqual(frozen, s);
});

test("sleep gap (tab frozen / laptop closed) is not work", () => {
  let s = RM.newReminder(3600);
  s = RM.tick(s, 0, true).state;
  s = RM.tick(s, 300, true).state;
  assert.equal(s.activeSeconds, 300);
  s = RM.tick(s, 300 + 421, true).state;
  assert.equal(s.activeSeconds, 0);
});

test("status estimate", () => {
  let s = RM.newReminder(600);
  assert.deepEqual(RM.status(s, 0, true), { phase: "counting", left: 600 });
  assert.deepEqual(RM.status(s, 0, false), { phase: "away" });
  s = RM.tick(s, 0, true).state;
  assert.deepEqual(RM.status(s, 100, true), { phase: "counting", left: 500 });
  assert.deepEqual(RM.status({ ...s, activeSeconds: 600 }, 0, true, true), { phase: "waiting", left: 0 });
  assert.deepEqual(RM.status(RM.snooze(s, 10), 70, true), { phase: "snoozed", left: 540 });
  assert.deepEqual(RM.status({ ...s, showing: true }, 0, true), { phase: "showing" });
});

test("tolerant decode and copy", () => {
  assert.deepEqual(RM.decodeReminder(null), RM.newReminder(3600));
  assert.deepEqual(RM.decodeReminder({ interval: 2700, activeSeconds: "x", showing: 1, lastTick: 5 }),
    { interval: 2700, activeSeconds: 0, lastTick: 5, snoozeUntil: null, showing: false });
  assert.deepEqual(RM.DEFAULT_INTERVALS, { water: 3600, stand: 2700 });
  assert.equal(RM.reminderCopy("water").title, "该喝水啦 💧");
  assert.equal(RM.secondsUntilNextCheck({ ...RM.newReminder(3600), activeSeconds: 1800 }), 1800);
});
