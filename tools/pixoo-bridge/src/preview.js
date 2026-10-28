// Preview output (no device): each scene as an animated GIF (pixels drawn as LED dots) plus a contact-sheet PNG.

import gifenc from "gifenc";
import sharp from "sharp";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { tokenize, drawLine } from "./font.js";
import { SIZE } from "./canvas.js";

const { GIFEncoder, quantize, applyPalette } = gifenc;

/** 64×64 RGB → (64·scale)² RGBA; with `grid`, each LED is a (scale-1)² dot on black. */
export function upscale(frame, scale = 4, grid = true) {
  const W = SIZE * scale;
  const out = new Uint8Array(W * W * 4);
  for (let y = 0; y < W; y++) {
    for (let x = 0; x < W; x++) {
      const o = (y * W + x) * 4;
      out[o + 3] = 255;
      if (grid && scale >= 3 && (x % scale === scale - 1 || y % scale === scale - 1)) continue;
      const s = (Math.floor(y / scale) * SIZE + Math.floor(x / scale)) * 3;
      out[o] = frame[s]; out[o + 1] = frame[s + 1]; out[o + 2] = frame[s + 2];
    }
  }
  return out;
}

/** The frames a viewer would see, with a delay each: segments looped for min(hold, capMs) (≥ one pass). */
export function timeline(segments, { capMs = 6000, idleMs = 3000 } = {}) {
  const out = [];
  for (const seg of segments) {
    const pass = seg.frames.length * seg.frameMs;
    const want = Number.isFinite(seg.holdMs) ? Math.min(seg.holdMs, capMs) : idleMs;
    const loops = Math.max(1, Math.round(want / pass));
    for (let l = 0; l < loops; l++) for (const f of seg.frames) out.push({ frame: f, delay: seg.frameMs });
  }
  return out;
}

export function writeGif(path, segments, { scale = 4, grid = true, capMs, idleMs } = {}) {
  const gif = GIFEncoder();
  const W = SIZE * scale;
  for (const { frame, delay } of timeline(segments, { capMs, idleMs })) {
    const rgba = upscale(frame, scale, grid);
    const palette = quantize(rgba, 256);
    gif.writeFrame(applyPalette(rgba, palette), W, W, { palette, delay });
  }
  gif.finish();
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, gif.bytes());
}

/**
 * Contact sheet: one row per scene (title + up to `perRow` frames picked evenly over all its segments).
 * rows = [{title, segments}]. Written as PNG, scaled up `scale`× (nearest neighbour).
 */
export async function writeContactSheet(path, rows, font, { perRow = 6, scale = 3 } = {}) {
  const GAP = 4, TITLE = 13, TILE = SIZE;
  const W = GAP + perRow * (TILE + GAP);
  const rowH = TITLE + TILE + GAP;
  const H = GAP + rows.length * rowH;
  const sheet = { w: W, h: H, data: new Uint8Array(W * H * 3).fill(28) };
  rows.forEach((row, r) => {
    const y0 = GAP + r * rowH;
    drawLine(sheet, font, tokenize(font, row.title), GAP, y0 + 10, [230, 230, 235]);
    const all = row.segments.flatMap((s) => s.frames);
    const picks = pickEven(all.length, perRow);
    picks.forEach((idx, k) => {
      const x0 = GAP + k * (TILE + GAP), ty = y0 + TITLE;
      const f = all[idx];
      for (let y = 0; y < SIZE; y++) {
        const src = y * SIZE * 3;
        sheet.data.set(f.subarray(src, src + SIZE * 3), ((ty + y) * W + x0) * 3);
      }
    });
  });
  mkdirSync(dirname(path), { recursive: true });
  await sharp(Buffer.from(sheet.data), { raw: { width: W, height: H, channels: 3 } })
    .resize(W * scale, H * scale, { kernel: "nearest" })
    .png()
    .toFile(path);
}

function pickEven(n, k) {
  if (n <= k) return [...Array(n).keys()];
  return Array.from({ length: k }, (_, i) => Math.floor((i * (n - 1)) / (k - 1)));
}
