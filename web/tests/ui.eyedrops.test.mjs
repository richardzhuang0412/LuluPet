// 眼药水 controller (web/js/ui/eyedrops.js): a 滴了 from another device closes the bubble on the next once-a-minute
// replan, not only at the next 15-minute nag. Node with a localStorage stub, mocked timers / Date and a fake sync.
import { test, mock } from "node:test";
import assert from "node:assert/strict";

const mem = new Map();
globalThis.localStorage = { getItem: (k) => (mem.has(k) ? mem.get(k) : null), setItem: (k, v) => mem.set(k, String(v)), removeItem: (k) => mem.delete(k) };
globalThis.document ??= { hidden: false };
globalThis.location ??= { search: "" };

const { createEyedrops } = await import("../js/ui/eyedrops.js");
const { TZ } = await import("../js/ui/deps.js");
const E = await import("../js/core/eyedrops.js");

const flush = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

test("a check-in from the Mac closes the bubble and 「👁️ 该滴了」 within a minute", async () => {
  const day = "2026-10-12";
  const t0 = E.slotInstant(day, "12:00", TZ) + 60_000;
  mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: t0 });
  try {
    const settings = { enabled: true, times: ["08:00", "12:00"], notify: false, at: E.slotInstant("2026-10-01", "09:00", TZ), device: "mac-1" };
    let remoteDay = null;
    const gets = [];
    const sync = {
      getSettings: async () => settings,
      putSettings: async () => {},
      getDay: async (d) => { gets.push(d); return remoteDay; },
      putDone: async () => {}, deleteDone: async () => {},
    };
    const shown = [], hidden = [];
    const ed = createEyedrops({
      sync, deviceId: "web-test", scheduler: { setTimeout, clearTimeout },
      show: (x) => shown.push(x.slot), hide: () => hidden.push(Date.now()), onChange: () => {},
    });
    await flush();
    assert.deepEqual(shown, [E.slotId(day, "12:00")]);
    assert.equal(ed.titleBit(), "👁️ 该滴了");

    // a minute later, nothing checked in yet: still up, no new bubble
    mock.timers.tick(60_000); await flush();
    assert.equal(shown.length, 1);
    assert.equal(hidden.length, 0);
    assert.equal(ed.titleBit(), "👁️ 该滴了");

    // the Mac checks in → the next once-a-minute replan closes it (long before the 15-minute nag)
    remoteDay = { "1200": { done: Date.now(), device: "mac-1" } };
    const before = gets.length;
    mock.timers.tick(60_000); await flush();
    assert.ok(gets.length > before, "asked the remote while the bubble was up");
    assert.equal(hidden.length, 1);
    assert.equal(ed.showing(), null);
    assert.equal(ed.titleBit(), "👁️ 1/2");
    assert.equal(ed.entry("12:00").device, "mac-1");

    // and it stays closed
    mock.timers.tick(20 * 60_000); await flush();
    assert.equal(shown.length, 1);
  } finally {
    mock.timers.reset();
  }
});
