// W3's web/assets/manifest.json (spec §6.2): clips → sprite sheets, outfits per character, stickers + thumbnail atlas.
// Ids from the wire (outfit / stickerId) are only ever looked up in the manifest, never used to build a path.

import { assetsBase } from "./deps.js";

let base = "";
let manifest = null;
const images = new Map();   // file → Promise<HTMLImageElement>

export async function loadManifest() {
  base = await assetsBase();
  const r = await fetch(base + "manifest.json", { cache: "no-cache" });
  if (!r.ok) throw new Error("manifest " + r.status);
  manifest = await r.json();
  return manifest;
}

export const url = (file) => base + file;

/** A sprite sheet image, fetched once. */
export function image(file) {
  if (!images.has(file)) {
    images.set(file, new Promise((resolve, reject) => {
      const img = new Image();
      img.decoding = "async";
      img.onload = () => resolve(img);
      img.onerror = () => { images.delete(file); reject(new Error("image " + file)); };
      img.src = url(file);
    }));
  }
  return images.get(file);
}

const cleanId = (s) => (typeof s === "string" && s.length > 0 && s.length <= 64 && !s.includes("/") && !s.includes("..") ? s : null);

export function characterOf(c) { return manifest?.characters?.[c] ? c : "lulu"; }

/** The outfit to draw: `wanted` if this build has it, else the character's default (order[0]). */
export function outfitOf(character, ...wanted) {
  const ch = manifest?.characters?.[characterOf(character)];
  if (!ch) return null;
  for (const w of wanted) {
    const id = cleanId(w);
    if (id && Object.prototype.hasOwnProperty.call(ch.outfits, id)) return id;
  }
  return ch.order[0];
}

/** [{id, season}] of a character, in the manifest's order. */
export function outfitIds(character) {
  const ch = manifest?.characters?.[characterOf(character)];
  return ch ? ch.order.map((id) => ({ id, season: ch.outfits[id]?.season ?? null })) : [];
}

/** The raw manifest (handed to W5's createWorld). */
export const getManifest = () => manifest;

export function outfitLabel(character, outfit) {
  return manifest?.characters?.[characterOf(character)]?.outfits?.[outfit]?.label ?? "";
}

/**
 * One outfit's clips. action(name) → clip meta or null (no fallback: the pet decides, e.g. no sleep → still idle + Zzz);
 * idleHeight = idle's source frame height, the 1.0 reference so every clip is drawn at src[1] / idleHeight × the
 * idle display height (sizes stay consistent, like the Mac).
 */
export function outfitClips(character, outfit) {
  const o = manifest.characters[characterOf(character)].outfits[outfit];
  const clip = (hash) => (hash && manifest.clips[hash]) || null;
  const idle = clip(o.actions.idle);
  return {
    action: (name) => clip(o.actions[name]),
    idle,
    idleHeight: idle?.src?.[1] || idle?.h || 200,
    fidgets: (o.fidgets || []).map(clip).filter(Boolean),
  };
}

/** Sticker groups in display order: [{id, title}]. */
export function stickerGroups() { return manifest?.stickerGroups ?? []; }

export function stickerList() { return manifest?.stickers ?? []; }
export function stickerById(id) {
  const c = cleanId(id);
  return c ? stickerList().find((s) => s.id === c) || null : null;
}
export function defaultFavorites() { return manifest?.defaultFavorites ?? null; }

/** Thumbnail atlas: thumb i at ((i % cols) × size, floor(i / cols) × size). */
export function thumbs() {
  const t = manifest?.thumbs || {};
  return { file: t.file || "stickers/thumbs.webp", size: t.size || 72, cols: t.cols || 10 };
}

/** A sticker thumbnail element (a div with the atlas as background, CSSOM only → CSP-safe). */
export function thumbEl(sticker, px = 44, doc = document) {
  const t = thumbs();
  const el = doc.createElement("span");
  el.className = "thumb";
  const scale = px / t.size;
  const col = sticker.thumb % t.cols, row = Math.floor(sticker.thumb / t.cols);
  el.style.width = el.style.height = px + "px";
  el.style.backgroundImage = `url("${url(t.file)}")`;
  el.style.backgroundSize = `${t.cols * px}px auto`;
  el.style.backgroundPosition = `${-col * t.size * scale}px ${-row * t.size * scale}px`;
  return el;
}
