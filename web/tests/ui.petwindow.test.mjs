// 桌宠模式 window geometry (web/js/ui/petwindow-math.js).
import { test } from "node:test";
import assert from "node:assert/strict";
import { layoutFor, petWindowSize, visitExtra, regrow, besideRect, petPopupUrl, popupFeatures } from "../js/ui/petwindow-math.js";

test("layout: pet for the installed app, panel for tabs / phones / when chosen", () => {
  assert.equal(layoutFor({ standalone: true, phone: false, pref: null }), "pet");
  assert.equal(layoutFor({ standalone: true, phone: false, pref: "panel" }), "panel");
  assert.equal(layoutFor({ standalone: false, phone: false, pref: "pet" }), "panel");
  assert.equal(layoutFor({ standalone: true, phone: true, pref: "pet" }), "panel");
  assert.equal(layoutFor({ standalone: false, phone: false, pref: null, dev: "pet" }), "pet");
  assert.equal(layoutFor({ standalone: true, phone: true, dev: "pet" }), "panel");
});

test("pet window size follows the pet size", () => {
  assert.deepEqual(petWindowSize(1), { width: 220, height: 250 });
  const small = petWindowSize(0.75), big = petWindowSize(1.3);
  assert.ok(small.width < 220 && big.width > 220 && big.height > 250);
  assert.deepEqual(petWindowSize(NaN), petWindowSize(1));
  assert.deepEqual(petWindowSize(9), petWindowSize(1.6));
  assert.equal(visitExtra(1), 150);
});

test("regrow keeps the bottom centre (where the pet stands)", () => {
  const r = regrow({ x: 1000, y: 600, width: 220, height: 250 }, { width: 370, height: 250 });
  assert.deepEqual(r, { x: 925, y: 600, width: 370, height: 250 });
  const back = regrow(r, { width: 220, height: 250 });
  assert.deepEqual(back, { x: 1000, y: 600, width: 220, height: 250 });
});

test("regrow stays on screen", () => {
  const avail = { left: 0, top: 25, width: 1440, height: 800 };
  const r = regrow({ x: 1300, y: 570, width: 220, height: 250 }, { width: 370, height: 250 }, avail);
  assert.equal(r.x, 1440 - 370);
  const tall = regrow({ x: 100, y: 100, width: 220, height: 250 }, { width: 390, height: 700 }, avail);
  assert.equal(tall.y, 25);
});

test("the panel window goes left of the pet, or right when there's no room; bottoms aligned", () => {
  const avail = { left: 0, top: 25, width: 1440, height: 800 };
  const left = besideRect({ x: 1196, y: 569, width: 220, height: 250 }, { width: 390, height: 620 }, avail);
  assert.deepEqual(left, { x: 1196 - 10 - 390, y: 569 + 250 - 620, width: 390, height: 620 });
  const right = besideRect({ x: 40, y: 300, width: 220, height: 250 }, { width: 340, height: 252 }, avail);
  assert.equal(right.x, 40 + 220 + 10);
  assert.equal(right.y, 300 + 250 - 252);
  const top = besideRect({ x: 800, y: 30, width: 220, height: 250 }, { width: 390, height: 620 }, avail);
  assert.equal(top.y, 25);
});

test("桌宠小窗: the popup page is always the pet (a phone never gets one)", () => {
  assert.equal(layoutFor({ standalone: false, phone: false, pref: "panel", petWindow: true }), "pet");
  assert.equal(layoutFor({ standalone: false, phone: true, petWindow: true }), "panel");
  assert.equal(layoutFor({ standalone: false, phone: false, pref: null }), "panel");
});

test("桌宠小窗 address keeps dev params, drops ?tab and the hash", () => {
  assert.equal(petPopupUrl("http://127.0.0.1:8810/index.html?dev=fake&tab=tools#x"), "http://127.0.0.1:8810/index.html?dev=fake&window=pet");
  assert.equal(petPopupUrl("http://127.0.0.1:8810/"), "http://127.0.0.1:8810/?window=pet");
});

const feats = (s) => Object.fromEntries(s.split(",").map((kv) => kv.split("=")));
test("桌宠小窗 first placement: bottom-right above the Dock, else the remembered spot, always on screen", () => {
  const avail = { left: 0, top: 33, width: 1512, height: 902 };
  const f = feats(popupFeatures({ scale: 1, avail }));
  assert.equal(f.popup, "yes");
  assert.equal(Number(f.width), 220);
  assert.equal(Number(f.height), 250);
  assert.equal(Number(f.left), 1512 - 220 - 24);
  assert.ok(Number(f.top) + 250 + 62 <= 33 + 902);
  const g = feats(popupFeatures({ scale: 1, saved: { x: 600, y: 300 }, avail }));
  assert.equal(g.left, "600");
  assert.equal(g.top, "300");
  const off = feats(popupFeatures({ scale: 1, saved: { x: 5000, y: -400 }, avail }));
  assert.equal(Number(off.left), 1512 - 220);
  assert.equal(Number(off.top), 33);
});
