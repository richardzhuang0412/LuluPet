// Pixel text: a BDF bitmap font parser (exact pixels, no anti-aliasing), line wrapping and paging for the 64 px
// screen. The default font is Fusion Pixel 10px proportional zh_hans (SIL OFL 1.1), downloaded by
// `npm run fetch-font` (scripts/fetch-font.js), not committed. Colour emoji the font lacks come from icons.js.

import { readFileSync } from "node:fs";
import { icons, EMOJI_ICONS } from "./icons.js";

export class PixelFont {
  /** `bdf` = the BDF file's text. */
  constructor(bdf) {
    this.glyphs = new Map();
    this.ascent = 8;
    this.descent = 2;
    this.defaultChar = null;
    const lines = bdf.split(/\r?\n/);
    let i = 0;
    for (; i < lines.length; i++) {
      const l = lines[i];
      if (l.startsWith("FONT_ASCENT ")) this.ascent = Number(l.slice(12));
      else if (l.startsWith("FONT_DESCENT ")) this.descent = Number(l.slice(13));
      else if (l.startsWith("DEFAULT_CHAR ")) this.defaultChar = Number(l.slice(13));
      else if (l.startsWith("STARTCHAR")) break;
    }
    let g = null, cp = -1, inBitmap = false;
    for (; i < lines.length; i++) {
      const l = lines[i];
      if (inBitmap) {
        if (l === "ENDCHAR") { inBitmap = false; if (cp >= 0) this.glyphs.set(cp, g); g = null; continue; }
        g.rows.push(parseInt(l, 16) || 0);
        continue;
      }
      if (l.startsWith("STARTCHAR")) { g = { dw: 0, w: 0, h: 0, xoff: 0, yoff: 0, bytes: 1, rows: [] }; cp = -1; }
      else if (l.startsWith("ENCODING ")) cp = Number(l.slice(9));
      else if (l.startsWith("DWIDTH ")) g.dw = Number(l.split(" ")[1]);
      else if (l.startsWith("BBX ")) {
        const [, w, h, xo, yo] = l.split(" ").map(Number);
        Object.assign(g, { w, h, xoff: xo, yoff: yo, bytes: Math.max(1, Math.ceil(w / 8)) });
      } else if (l === "BITMAP") inBitmap = true;
    }
    this.lineHeight = this.ascent + this.descent;
  }

  static load(path) {
    return new PixelFont(readFileSync(path, "utf8"));
  }

  glyph(cp) { return this.glyphs.get(cp) ?? null; }

  /** Pixel (x, y) of glyph `g` is set? x/y inside the BBX. */
  static bit(g, x, y) {
    const row = g.rows[y] ?? 0;
    return (row >> (g.bytes * 8 - 1 - x)) & 1;
  }
}

let segmenter = null;
const graphemes = (s) => {
  segmenter ??= new Intl.Segmenter("zh", { granularity: "grapheme" });
  return Array.from(segmenter.segment(s), (x) => x.segment);
};
const PICTO = /\p{Extended_Pictographic}/u;
const WORDCH = /[A-Za-z0-9'’]/;

/**
 * Text → items: {type: "glyph", cp, adv} | {type: "icon", name, adv} | {type: "space", adv} | {type: "br"}.
 * Variation selectors / ZWJ sequences collapse to their first code point; emoji with an icon are drawn in colour;
 * other emoji are dropped; characters the font lacks use its default glyph (a box).
 */
export function tokenize(font, text) {
  const out = [];
  for (const gph of graphemes(String(text ?? ""))) {
    if (gph === "\n" || gph === "\r\n" || gph === "\r") { out.push({ type: "br" }); continue; }
    const cps = [...gph].map((c) => c.codePointAt(0)).filter((c) => c !== 0xfe0f && c !== 0xfe0e);
    if (!cps.length) continue;
    const cp = cps[0];
    const icon = EMOJI_ICONS.get(cp);
    if (icon) { out.push({ type: "icon", name: icon, adv: icons[icon].w + 1 }); continue; }
    if (cp === 0x20 || cp === 0x3000 || cp === 0x09) {
      const sp = font.glyph(0x20);
      out.push({ type: "space", adv: cp === 0x3000 ? 10 : (sp?.dw || 4) });
      continue;
    }
    const g = font.glyph(cp);
    if (g) { out.push({ type: "glyph", cp, adv: g.dw, ch: gph }); continue; }
    if (PICTO.test(gph)) continue;
    if (font.defaultChar != null && font.glyph(font.defaultChar)) out.push({ type: "glyph", cp: font.defaultChar, adv: font.glyph(font.defaultChar).dw });
  }
  return out;
}

export const width = (items) => items.reduce((a, it) => a + (it.adv ?? 0), 0);

/** Greedy wrap to `maxWidth` px. Latin words that fit on a line are not split; CJK breaks anywhere. */
export function wrap(items, maxWidth) {
  const lines = [];
  let line = [], w = 0;
  const flush = () => { while (line.length && line[line.length - 1].type === "space") { w -= line.pop().adv; } lines.push(line); line = []; w = 0; };
  let i = 0;
  while (i < items.length) {
    const it = items[i];
    if (it.type === "br") { flush(); i++; continue; }
    if (it.type === "space" && line.length === 0) { i++; continue; }
    // a latin word: take it whole when it fits on an empty line
    if (it.type === "glyph" && it.ch && WORDCH.test(it.ch)) {
      let j = i, ww = 0;
      while (j < items.length && items[j].type === "glyph" && items[j].ch && WORDCH.test(items[j].ch)) { ww += items[j].adv; j++; }
      if (w + ww > maxWidth && ww <= maxWidth && line.length) { flush(); continue; }
      if (ww <= maxWidth) { for (let k = i; k < j; k++) line.push(items[k]); w += ww; i = j; continue; }
    }
    if (w + it.adv > maxWidth && line.length) { flush(); continue; }
    line.push(it); w += it.adv; i++;
  }
  if (line.length) flush();
  return lines;
}

/**
 * Lines → pages of `perPage` lines, at most `maxPages`; when cut, the last line ends with "…" (fitted into maxWidth).
 * → {pages: [[line…]…], truncated}
 */
export function paginate(font, lines, perPage, maxPages, maxWidth) {
  const pages = [];
  for (let i = 0; i < lines.length; i += perPage) pages.push(lines.slice(i, i + perPage));
  if (!pages.length) pages.push([[]]);
  if (pages.length <= maxPages) return { pages, truncated: false };
  const kept = pages.slice(0, maxPages);
  const last = kept[kept.length - 1];
  const ell = tokenize(font, font.glyph(0x2026) ? "…" : "..");
  let line = last[last.length - 1].slice();
  while (line.length && width(line) + width(ell) > maxWidth) line.pop();
  last[last.length - 1] = [...line, ...ell];
  return { pages: kept, truncated: true };
}

/** Text → pages, one call. */
export function layoutPages(font, text, { maxWidth = 62, perPage = 2, maxPages = 12 } = {}) {
  return paginate(font, wrap(tokenize(font, text), maxWidth), perPage, maxPages, maxWidth);
}

/**
 * Draws one line of items into an RGB frame (`fb` = {w, h, data}); `baseline` = y of the font baseline.
 * `color` = [r, g, b]. Pixels outside the frame are clipped.
 */
export function drawLine(fb, font, items, x, baseline, color) {
  let cx = x;
  for (const it of items) {
    if (it.type === "glyph") {
      const g = font.glyph(it.cp);
      if (g) {
        const top = baseline - g.yoff - g.h;
        for (let gy = 0; gy < g.h; gy++) for (let gx = 0; gx < g.w; gx++) {
          if (PixelFont.bit(g, gx, gy)) setPx(fb, cx + g.xoff + gx, top + gy, color);
        }
      }
    } else if (it.type === "icon") {
      const ic = icons[it.name];
      const top = baseline + 1 - ic.h;
      for (const [px, py, c] of ic.px) setPx(fb, cx + px, top + py, c);
    }
    cx += it.adv ?? 0;
  }
  return cx;
}

function setPx(fb, x, y, c) {
  if (x < 0 || y < 0 || x >= fb.w || y >= fb.h) return;
  const o = (y * fb.w + x) * 3;
  fb.data[o] = c[0]; fb.data[o + 1] = c[1]; fb.data[o + 2] = c[2];
}
