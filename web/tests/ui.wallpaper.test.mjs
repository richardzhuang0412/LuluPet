// 桌宠模式 「跟桌面壁纸对齐」: the slice of the desktop picture behind the window (web/js/ui/wallpaper-math.js).
import { test } from "node:test";
import assert from "node:assert/strict";
import { pictureRect, viewOrigin, wallpaperSlice, imagePointAt } from "../js/ui/wallpaper-math.js";

const near = (a, b, eps = 0.11) => assert.ok(Math.abs(a - b) <= eps, `${a} ≈ ${b}`);

test("fill screen: a wider picture is scaled to the height and cropped left / right", () => {
  const r = pictureRect(1440, 900, 3200, 1800, "fill");   // 16:9 on 16:10
  near(r.height, 900); near(r.width, 1600); near(r.x, -80); near(r.y, 0);
});

test("fill screen: a taller picture is scaled to the width and cropped top / bottom", () => {
  const r = pictureRect(1440, 900, 1000, 1000, "fill");
  near(r.width, 1440); near(r.height, 1440); near(r.x, 0); near(r.y, -270);
});

test("fit / stretch / center", () => {
  const fit = pictureRect(1440, 900, 1000, 1000, "fit");
  near(fit.width, 900); near(fit.x, 270); near(fit.y, 0);
  assert.deepEqual(pictureRect(1440, 900, 1000, 1000, "stretch"), { x: 0, y: 0, width: 1440, height: 900 });
  const c = pictureRect(1440, 900, 400, 300, "center");
  near(c.x, 520); near(c.y, 300); near(c.width, 400);
});

test("bad sizes fall back to the screen rectangle", () => {
  assert.deepEqual(pictureRect(1440, 900, 0, 0), { x: 0, y: 0, width: 1440, height: 900 });
});

test("view origin: frameless (window-controls-overlay) and with a title bar", () => {
  assert.deepEqual(viewOrigin({ screenX: 100, screenY: 50, outerWidth: 200, outerHeight: 230, innerWidth: 200, innerHeight: 230 }), { x: 100, y: 50 });
  assert.deepEqual(viewOrigin({ screenX: 100, screenY: 50, outerWidth: 202, outerHeight: 260, innerWidth: 200, innerHeight: 230 }), { x: 101, y: 79 });
});

test("the window shows exactly the part of the picture behind it, wherever it is", () => {
  const screen = { left: 0, top: 0, width: 1440, height: 900 };
  const image = { width: 2880, height: 1800 };   // exact 2× of the screen: page pixel (px, py) at screen (vx+px, vy+py)
  for (const view of [{ x: 0, y: 0 }, { x: 1220, y: 640 }, { x: 333, y: 77 }]) {
    const s = wallpaperSlice({ screen, image, view });
    assert.deepEqual(s.size, [1440, 900]);
    assert.deepEqual(s.position, [0 - view.x || 0, 0 - view.y || 0]);
    const p = imagePointAt(s, image, 10, 20);
    near(p.x, (view.x + 10) * 2); near(p.y, (view.y + 20) * 2);
  }
});

test("cropped picture + a second display to the right: page (0,0) maps to the right picture pixel", () => {
  const screen = { left: 1440, top: 0, width: 1920, height: 1080 };
  const image = { width: 1000, height: 1000 };   // fill → 1920×1920, y offset -420
  const view = { x: 1440 + 1700, y: 800 };
  const s = wallpaperSlice({ screen, image, view });
  assert.deepEqual(s.size, [1920, 1920]);
  assert.deepEqual(s.position, [-1700, -420 - 800]);
  const p = imagePointAt(s, image, 0, 0);
  near(p.x, (1700 / 1920) * 1000, 0.1); near(p.y, ((800 + 420) / 1920) * 1000, 0.1);
});

test("unknown fit = fill", () => {
  const screen = { left: 0, top: 0, width: 1440, height: 900 };
  assert.deepEqual(wallpaperSlice({ screen, image: { width: 3200, height: 1800 }, view: { x: 0, y: 0 }, fit: "zoom" }),
    wallpaperSlice({ screen, image: { width: 3200, height: 1800 }, view: { x: 0, y: 0 }, fit: "fill" }));
});
