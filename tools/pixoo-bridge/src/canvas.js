// 64×64 RGB frames (what the Pixoo takes: 64*64*3 bytes, left→right, top→bottom) and the few drawing operations
// the scenes need. Sprites are RGBA ({w, h, data}) composited over black.

import { icons } from "./icons.js";

export const SIZE = 64;

export function newFrame(size = SIZE) {
  return { w: size, h: size, data: new Uint8Array(size * size * 3) };
}

export function cloneFrame(f) {
  return { w: f.w, h: f.h, data: new Uint8Array(f.data) };
}

/** Alpha-blends RGBA sprite `s` at (x, y); `mul` scales its brightness (0…1). */
export function blit(f, s, x, y, mul = 1) {
  x = Math.round(x); y = Math.round(y);
  for (let sy = 0; sy < s.h; sy++) {
    const dy = y + sy;
    if (dy < 0 || dy >= f.h) continue;
    for (let sx = 0; sx < s.w; sx++) {
      const dx = x + sx;
      if (dx < 0 || dx >= f.w) continue;
      const so = (sy * s.w + sx) * 4;
      const a = s.data[so + 3] / 255;
      if (a <= 0) continue;
      const o = (dy * f.w + dx) * 3;
      for (let k = 0; k < 3; k++) f.data[o + k] = Math.round(f.data[o + k] * (1 - a) + s.data[so + k] * mul * a);
    }
  }
}

export function dim(f, mul) {
  for (let i = 0; i < f.data.length; i++) f.data[i] = Math.round(f.data[i] * mul);
}

export function fillRect(f, x, y, w, h, c) {
  for (let yy = Math.max(0, y); yy < Math.min(f.h, y + h); yy++) {
    for (let xx = Math.max(0, x); xx < Math.min(f.w, x + w); xx++) {
      const o = (yy * f.w + xx) * 3;
      f.data[o] = c[0]; f.data[o + 1] = c[1]; f.data[o + 2] = c[2];
    }
  }
}

/** Draws icon `name` with its top-left at (x, y); `mul` scales brightness. */
export function drawIcon(f, name, x, y, mul = 1) {
  const ic = icons[name];
  x = Math.round(x); y = Math.round(y);
  for (const [px, py, c] of ic.px) {
    const dx = x + px, dy = y + py;
    if (dx < 0 || dy < 0 || dx >= f.w || dy >= f.h) continue;
    const o = (dy * f.w + dx) * 3;
    f.data[o] = Math.round(c[0] * mul); f.data[o + 1] = Math.round(c[1] * mul); f.data[o + 2] = Math.round(c[2] * mul);
  }
}

/** A tiny "Z" of size 3 / 4 / 5 px (Zzz while asleep). */
export function drawZ(f, x, y, size, c) {
  for (let i = 0; i < size; i++) {
    setPx(f, x + i, y, c);
    setPx(f, x + i, y + size - 1, c);
    setPx(f, x + size - 1 - i, y + i, c);
  }
}

export function setPx(f, x, y, c) {
  if (x < 0 || y < 0 || x >= f.w || y >= f.h) return;
  const o = (y * f.w + x) * 3;
  f.data[o] = c[0]; f.data[o + 1] = c[1]; f.data[o + 2] = c[2];
}
