// W4 polish: 眼药水「一天几次」 keeps hand-edited times and only adds / removes at the end.
import { test } from "node:test";
import assert from "node:assert/strict";
import { resizeTimes } from "../js/ui/eyedrop-times.js";
import { validateTimes } from "../js/core/eyedrops.js";

test("no times yet → the suggested set", () => {
  assert.deepEqual(resizeTimes([], 4), ["08:00", "12:00", "16:00", "20:00"]);
});

test("fewer → the latest go, hand-edited ones stay", () => {
  assert.deepEqual(resizeTimes(["07:45", "12:10", "16:00", "21:20"], 2), ["07:45", "12:10"]);
});

test("more → 22:00 first when there is room, then the widest gap; existing times never move", () => {
  assert.deepEqual(resizeTimes(["07:45", "12:10", "16:00", "20:00"], 5), ["07:45", "12:10", "16:00", "20:00", "22:00"]);
  const six = resizeTimes(["07:45", "12:10", "16:00", "20:00"], 6);
  assert.equal(six.length, 6);
  for (const t of ["07:45", "12:10", "16:00", "20:00", "22:00"]) assert.ok(six.includes(t));
  assert.ok(validateTimes(six).ok, "30-minute gap respected");
  assert.deepEqual(resizeTimes(["09:00"], 2), ["09:00", "22:00"]);
});

test("up to 8, always valid", () => {
  for (const start of [["09:00"], ["21:45"], ["07:00", "22:00"], ["08:00", "08:30", "09:00"]]) {
    for (let n = 1; n <= 8; n++) {
      const r = resizeTimes(start, n);
      assert.ok(r.length <= n && r.length >= Math.min(n, start.length));
      assert.ok(validateTimes(r).ok, `${start} → ${n}: ${r}`);
    }
  }
});
