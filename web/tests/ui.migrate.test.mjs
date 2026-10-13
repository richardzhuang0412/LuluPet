// W4: v1 → v2 local key migration (spec §4.6) — js/ui/migrate.js is pure over a {get, set, remove} store.
import { test } from "node:test";
import assert from "node:assert/strict";
import { migrateV1, DEFAULT_TOOLS } from "../js/ui/migrate.js";

function mem(init) {
  const m = new Map(Object.entries(init).map(([k, v]) => [k, JSON.stringify(v)]));
  return {
    get: (k, d = null) => (m.has(k) ? JSON.parse(m.get(k)) : d),
    set: (k, v) => m.set(k, JSON.stringify(v)),
    remove: (k) => m.delete(k),
    keys: () => [...m.keys()].sort(),
  };
}

test("v1 reminders + reminderState → toolsSettings + reminder.<kind>", () => {
  const st = { interval: 2700, activeSeconds: 120, lastTick: 1790000000, snoozeUntil: null, showing: false };
  const s = mem({ reminders: { water: { on: true, minutes: 30 }, stand: { on: false, minutes: 45 } }, reminderState: { stand: st } });
  assert.deepEqual(migrateV1(s), ["toolsSettings", "reminder.stand"]);
  assert.deepEqual(s.get("toolsSettings"), { ...DEFAULT_TOOLS, waterEnabled: true, waterInterval: 1800, standInterval: 2700 });
  assert.deepEqual(s.get("reminder.stand"), st);
  assert.deepEqual(s.keys(), ["reminder.stand", "toolsSettings"]);
});

test("bad v1 values fall back to the defaults; nothing to do → nothing written", () => {
  const s = mem({ reminders: { water: { on: "yes", minutes: 3 } } });
  migrateV1(s);
  assert.deepEqual(s.get("toolsSettings"), DEFAULT_TOOLS);
  const empty = mem({});
  assert.deepEqual(migrateV1(empty), []);
  assert.deepEqual(empty.keys(), []);
});

test("an existing v2 key is never overwritten; old keys still removed", () => {
  const mine = { ...DEFAULT_TOOLS, standEnabled: true };
  const s = mem({ toolsSettings: mine, reminders: { water: { on: true, minutes: 30 } }, reminderState: "garbage" });
  assert.deepEqual(migrateV1(s), []);
  assert.deepEqual(s.get("toolsSettings"), mine);
  assert.deepEqual(s.keys(), ["toolsSettings"]);
});
