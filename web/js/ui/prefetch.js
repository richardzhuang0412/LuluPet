// Asset prefetch (spec §5): after the first screen, while the browser is idle, fetch in order: my current outfit →
// TA's current outfit → couple clips → weather clips → everything else. Requests go through sw.js, which keeps
// hashed assets forever, so each file is downloaded once per device. 「下载全部素材」 runs the same list to the end
// with progress. Works with manifest v1 (clips + stickers) and v2 (couples / weather / reactions / toolClips / sounds).

import { getManifest, url } from "./assets.js";

/** Every `file` string anywhere in a manifest subtree, in walk order. */
function files(node, out = []) {
  if (Array.isArray(node)) for (const x of node) files(x, out);
  else if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node)) {
      if (k === "file" && typeof v === "string" && !v.includes("..")) out.push(v);
      else files(v, out);
    }
  }
  return out;
}

function outfitFiles(m, character, outfit) {
  const o = m?.characters?.[character]?.outfits?.[outfit];
  if (!o) return [];
  const ids = [...Object.values(o.actions || {}), ...(o.fidgets || [])];
  const weather = Object.values(o.weather || m.characters[character].weather || {}).flat();
  return files([...ids, ...weather].map((id) => (typeof id === "string" ? m.clips?.[id] : id)));
}

/** looks: [{character, outfit}] (me first, then TA). Ordered, de-duplicated file list; full = also every other outfit. */
export function prefetchList(looks, { full = false } = {}) {
  const m = getManifest();
  if (!m) return [];
  const ordered = [
    ...looks.flatMap((l) => outfitFiles(m, l.character, l.outfit)),
    ...files(m.couples), ...files(m.reactions), ...files(m.toolClips), ...files(m.sounds),
    ...(full ? [...files(m.characters), ...files(m.clips), ...files(m.thumbs), ...files(m.stickers)] : []),
  ];
  return [...new Set(ordered)];
}

const idle = (fn) => (window.requestIdleCallback ? window.requestIdleCallback(fn, { timeout: 5000 }) : setTimeout(fn, 200));

let running = null;

/** onProgress(done, total, bytes); resolves when every file was tried. `background` = one file per idle slot. */
export function prefetch(list, { onProgress, background = false } = {}) {
  if (running && background) return running;
  let done = 0, bytes = 0;
  const one = async (f) => {
    try {
      const r = await fetch(url(f));
      const len = Number(r.headers.get("content-length"));
      if (Number.isFinite(len)) bytes += len;
      await r.arrayBuffer();
    } catch { /* offline: try again next time */ }
    done++;
    onProgress?.(done, list.length, bytes);
  };
  const p = (async () => {
    for (const f of list) {
      if (background) await new Promise((r) => idle(r));
      await one(f);
    }
  })();
  if (background) running = p.finally(() => { running = null; });
  return p;
}
