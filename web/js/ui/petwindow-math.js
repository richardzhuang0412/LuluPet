// 桌宠模式 window geometry (pure, no DOM; js/ui/petmode.js uses it): which layout, how big the pet window is,
// how it grows for a visit, where the panel window goes.

export const PANEL = { width: 390, height: 620 };
export const COMPACT = { width: 340, height: 214 };
export const COMPACT_ALL = { width: 360, height: 520 };

/**
 * Which layout this window uses: "pet" | "panel". The 桌宠小窗 popup (petWindow) is always the pet; phones and plain
 * tabs keep the panel layout; the installed app follows its 设置 choice.
 */
export function layoutFor({ standalone, phone, pref, dev, petWindow = false }) {
  if (phone) return "panel";
  if (dev === "pet" || dev === "panel") return dev;
  if (petWindow) return "pet";
  if (!standalone) return "panel";
  return pref === "panel" ? "panel" : "pet";
}

/** The pet window's inner size for a pet size (petScale 0.6…1.6): ≈ 220×250 at standard, room for a bubble above. */
export function petWindowSize(scale = 1) {
  const s = Number.isFinite(scale) ? Math.min(1.6, Math.max(0.6, scale)) : 1;
  const f = 0.55 + 0.45 * s;
  return { width: Math.round(220 * f), height: Math.round(250 * f) };
}

/** Extra width while TA's pet visits (it walks in from the edge and stands beside mine). */
export const visitExtra = (scale = 1) => Math.round(150 * (Number.isFinite(scale) ? Math.min(1.6, Math.max(0.6, scale)) : 1));

/**
 * New outer rectangle when the inner size changes from `from` to `to`, keeping the bottom centre where it is (the pet
 * stands there), clamped to the available screen area. All {x, y, width, height} in screen px; avail = {left, top, width, height}.
 */
export function regrow(rect, to, avail) {
  const cx = rect.x + rect.width / 2, bottom = rect.y + rect.height;
  let x = Math.round(cx - to.width / 2), y = Math.round(bottom - to.height);
  if (avail) {
    x = Math.max(avail.left, Math.min(x, avail.left + avail.width - to.width));
    y = Math.max(avail.top, Math.min(y, avail.top + avail.height - to.height));
  }
  return { x, y, width: to.width, height: to.height };
}

/** Where a side window goes: left of the pet window if it fits, else right; bottoms aligned; on screen. */
export function besideRect(pet, size, avail) {
  const gap = 10;
  let x = pet.x - size.width - gap;
  if (x < avail.left) x = pet.x + pet.width + gap;
  x = Math.max(avail.left, Math.min(x, avail.left + avail.width - size.width));
  const y = Math.max(avail.top, Math.min(pet.y + pet.height - size.height, avail.top + avail.height - size.height));
  return { x: Math.round(x), y: Math.round(y), width: size.width, height: size.height };
}

// ---- 桌宠小窗 (a Chrome popup, js/ui/petpopup.js) ----

const CHROME_H = 62;   // a Chrome popup's title bar + address strip (estimate; petmode.js measures the real one)

/** This page's address with window=pet (keeps ?dev=… for testing; drops ?tab=). */
export function petPopupUrl(href) {
  const u = new URL(href);
  u.searchParams.delete("tab");
  u.searchParams.set("window", "pet");
  u.hash = "";
  return u.href;
}

/** Where the popup first appears: the remembered spot, else bottom-right above the Dock. Pure. */
export function popupFeatures({ scale = 1, saved = null, avail }) {
  const s = petWindowSize(scale);
  let left, top;
  if (saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)) ({ x: left, y: top } = saved);
  else {
    left = avail.left + avail.width - s.width - 24;
    top = avail.top + avail.height - s.height - CHROME_H - 6;
  }
  left = Math.max(avail.left, Math.min(left, avail.left + avail.width - s.width));
  top = Math.max(avail.top, Math.min(top, avail.top + avail.height - s.height - CHROME_H));
  return `popup=yes,width=${s.width},height=${s.height},left=${Math.round(left)},top=${Math.round(top)}`;
}

