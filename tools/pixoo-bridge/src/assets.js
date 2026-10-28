// Character clips and stickers from web/assets (manifest v2, see web/assets/README.md), cut, trimmed and scaled for
// the 64×64 screen with sharp, cached as raw RGBA in `cacheDir` (local only, gitignored; converted art is never
// committed or published).
//
// Clip: sprite sheet `file`, cells `w`×`h` in rows of `cols`; frame i shows cell seq[i] for delays[i] s. Clips of
// one outfit keep their relative size: drawn height ∝ src[1] / idle.src[1] (README). We trim the transparent border
// (union over the sampled frames) and scale so that the outfit's idle fills the box height.

import sharp from "sharp";
import { readFileSync, mkdirSync, writeFileSync, existsSync } from "node:fs";
import { gunzipSync, gzipSync } from "node:zlib";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { sampleClip, sampleWindow } from "./frames.js";

const CACHE_VERSION = 2;
const ALPHA_MIN = 24;

sharp.concurrency(1);   // a Raspberry Pi: one libvips thread is plenty and keeps the CPU cool

export class AssetStore {
  constructor({ assetsDir, cacheDir, log }) {
    this.dir = assetsDir;
    this.cacheDir = cacheDir;
    this.log = log;
    this.manifest = JSON.parse(readFileSync(join(assetsDir, "manifest.json"), "utf8"));
    this.mem = new Map();          // in-process cache of converted frames
    this.sheets = new Map();       // decoded sheets (small LRU)
    this.bboxes = new Map();
  }

  get characters() { return this.manifest.characters ?? {}; }
  clip(key) { return this.manifest.clips?.[key] ?? null; }
  sticker(id) { return (this.manifest.stickers ?? []).find((s) => s.id === id) ?? null; }

  async decodeSheet(file) {
    if (this.sheets.has(file)) return this.sheets.get(file);
    const { data, info } = await sharp(join(this.dir, file)).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    const sheet = { data, w: info.width, h: info.height };
    this.sheets.set(file, sheet);
    if (this.sheets.size > 4) this.sheets.delete(this.sheets.keys().next().value);
    return sheet;
  }

  /** Union bbox (in cell pixels) of the opaque parts of `cells`. */
  async clipBBox(key, cells) {
    const id = `${key}:${cells.join(",")}`;
    if (this.bboxes.has(id)) return this.bboxes.get(id);
    const c = this.clip(key);
    const sheet = await this.decodeSheet(c.file);
    let x0 = c.w, y0 = c.h, x1 = -1, y1 = -1;
    for (const cell of new Set(cells)) {
      const ox = (cell % c.cols) * c.w, oy = Math.floor(cell / c.cols) * c.h;
      for (let y = 0; y < c.h; y++) {
        const row = ((oy + y) * sheet.w + ox) * 4;
        for (let x = 0; x < c.w; x++) {
          if (sheet.data[row + x * 4 + 3] >= ALPHA_MIN) {
            if (x < x0) x0 = x; if (x > x1) x1 = x;
            if (y < y0) y0 = y; if (y > y1) y1 = y;
          }
        }
      }
    }
    const bb = x1 < 0 ? { x: 0, y: 0, w: c.w, h: c.h } : { x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1 };
    this.bboxes.set(id, bb);
    return bb;
  }

  /**
   * Frames of clip `key`, scaled for a box `boxW`×`boxH`. `refKey` = the outfit's idle clip (size reference).
   * `still` = only the first frame; `window` = the first maxFrames frames at the clip's own pace. → {frames: [{w, h, data RGBA}], frameMs}
   */
  async clipFrames(key, { boxW = 64, boxH = 64, maxFrames = 40, refKey = null, still = false, window = false } = {}) {
    const c = this.clip(key);
    if (!c) throw new Error(`unknown clip ${key}`);
    const sampled = still ? { cells: [c.seq?.[0] ?? 0], frameMs: 1000 } : window ? sampleWindow(c, maxFrames) : sampleClip(c, maxFrames);
    const bb = await this.clipBBox(key, sampled.cells);
    // scale: the reference idle's trimmed height fills boxH; this clip keeps its size relative to it
    let s;
    const ref = refKey && refKey !== key ? this.clip(refKey) : null;
    if (ref) {
      const refBB = await this.clipBBox(refKey, sampleClip(ref, maxFrames).cells);
      const sRef = boxH / refBB.h;
      s = sRef * ((c.src?.[1] ?? c.h) / c.h) / ((ref.src?.[1] ?? ref.h) / ref.h);
    } else {
      s = boxH / bb.h;
    }
    s = Math.min(s, boxH / bb.h, boxW / bb.w);
    const tw = Math.max(1, Math.round(bb.w * s)), th = Math.max(1, Math.round(bb.h * s));
    const ck = cacheKey(["clip", c.file, sampled.cells.join(","), bb.x, bb.y, bb.w, bb.h, tw, th]);
    const cached = this.readCache(ck);
    if (cached) return { frames: cached, frameMs: sampled.frameMs };
    const sheet = await this.decodeSheet(c.file);
    const byCell = new Map();
    for (const cell of new Set(sampled.cells)) {
      const ox = (cell % c.cols) * c.w + bb.x, oy = Math.floor(cell / c.cols) * c.h + bb.y;
      const crop = Buffer.alloc(bb.w * bb.h * 4);
      for (let y = 0; y < bb.h; y++) sheet.data.copy(crop, y * bb.w * 4, ((oy + y) * sheet.w + ox) * 4, ((oy + y) * sheet.w + ox + bb.w) * 4);
      byCell.set(cell, await scaleRGBA(crop, bb.w, bb.h, tw, th));
    }
    const frames = sampled.cells.map((cell) => ({ w: tw, h: th, data: byCell.get(cell) }));
    this.writeCache(ck, frames);
    return { frames, frameMs: sampled.frameMs };
  }

  /** Sticker `id` (animated WebP) scaled into `boxW`×`boxH`. → {frames, frameMs} */
  async stickerFrames(id, { boxW = 64, boxH = 64, maxFrames = 40 } = {}) {
    const st = this.sticker(id);
    if (!st) throw new Error(`unknown sticker ${id}`);
    const path = join(this.dir, st.file);
    const meta = await sharp(path, { animated: true }).metadata();
    const pages = meta.pages ?? 1;
    const pageH = meta.pageHeight ?? meta.height;
    const delays = Array.from({ length: pages }, (_, i) => (meta.delay?.[i] ?? 100) / 1000);
    const sampled = sampleClip({ seq: [...Array(pages).keys()], delays }, maxFrames);
    const ck = cacheKey(["sticker", st.file, sampled.cells.join(","), boxW, boxH]);
    const cached = this.readCache(ck);
    if (cached) return { frames: cached, frameMs: sampled.frameMs };
    const { data, info } = await sharp(path, { animated: true }).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    const W = info.width;
    // union bbox over the sampled pages
    let x0 = W, y0 = pageH, x1 = -1, y1 = -1;
    for (const p of new Set(sampled.cells)) {
      for (let y = 0; y < pageH; y++) for (let x = 0; x < W; x++) {
        if (data[((p * pageH + y) * W + x) * 4 + 3] >= ALPHA_MIN) {
          if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
        }
      }
    }
    const bb = x1 < 0 ? { x: 0, y: 0, w: W, h: pageH } : { x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1 };
    const s = Math.min(boxW / bb.w, boxH / bb.h);
    const tw = Math.max(1, Math.round(bb.w * s)), th = Math.max(1, Math.round(bb.h * s));
    const byPage = new Map();
    for (const p of new Set(sampled.cells)) {
      const crop = Buffer.alloc(bb.w * bb.h * 4);
      for (let y = 0; y < bb.h; y++) {
        const src = ((p * pageH + bb.y + y) * W + bb.x) * 4;
        data.copy(crop, y * bb.w * 4, src, src + bb.w * 4);
      }
      byPage.set(p, await scaleRGBA(crop, bb.w, bb.h, tw, th));
    }
    const frames = sampled.cells.map((p) => ({ w: tw, h: th, data: byPage.get(p) }));
    this.writeCache(ck, frames);
    return { frames, frameMs: sampled.frameMs };
  }

  readCache(key) {
    if (this.mem.has(key)) return this.mem.get(key);
    const base = join(this.cacheDir, key);
    if (!existsSync(base + ".json") || !existsSync(base + ".bin")) return null;
    try {
      const meta = JSON.parse(readFileSync(base + ".json", "utf8"));
      const raw = gunzipSync(readFileSync(base + ".bin"));
      let off = 0;
      const frames = meta.frames.map(([w, h]) => {
        const len = w * h * 4;
        const f = { w, h, data: new Uint8Array(raw.buffer, raw.byteOffset + off, len) };
        off += len;
        return f;
      });
      if (off !== raw.length) return null;
      this.remember(key, frames);
      return frames;
    } catch (e) {
      this.log?.warn("cache read failed, converting again:", key, e.message);
      return null;
    }
  }

  writeCache(key, frames) {
    this.remember(key, frames);
    try {
      mkdirSync(this.cacheDir, { recursive: true });
      const base = join(this.cacheDir, key);
      writeFileSync(base + ".bin", gzipSync(Buffer.concat(frames.map((f) => Buffer.from(f.data.buffer, f.data.byteOffset, f.data.length)))));
      writeFileSync(base + ".json", JSON.stringify({ v: CACHE_VERSION, frames: frames.map((f) => [f.w, f.h]) }));
    } catch (e) {
      this.log?.warn("cache write failed:", e.message);
    }
  }

  remember(key, frames) {
    this.mem.set(key, frames);
    if (this.mem.size > 64) this.mem.delete(this.mem.keys().next().value);
  }
}

async function scaleRGBA(buf, w, h, tw, th) {
  const out = await sharp(buf, { raw: { width: w, height: h, channels: 4 } })
    .resize(tw, th, { kernel: "lanczos3", fit: "fill" })
    .raw()
    .toBuffer();
  return new Uint8Array(out.buffer, out.byteOffset, out.length);
}

function cacheKey(parts) {
  return createHash("sha1").update(JSON.stringify([CACHE_VERSION, ...parts])).digest("hex").slice(0, 24);
}
