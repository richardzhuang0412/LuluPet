// 桌宠模式 background (browsers can't make a see-through window, so we fake it):
//   wallpaper = 「跟桌面壁纸对齐」: the user picks their desktop picture once (kept in this browser's IndexedDB, never
//               uploaded); each window draws the slice of it that lies behind the window (wallpaper-math.js) and
//               follows the window when it moves (a cheap 4×/s check while visible, every frame for a moment after a move)
//   solid     = 「纯色」 (a colour picker; default a soft neutral)
//   scene     = 「柔和渐变」 (the little world's own sky and ground)
// Settings in `lulupet.backdrop` = {kind, color, fit}; kind null = wallpaper when a picture is saved, else solid.

import { store } from "./store.js";
import { wallpaperSlice, viewOrigin, FITS } from "./wallpaper-math.js";

export const KINDS = [{ value: "wallpaper", label: "跟桌面壁纸对齐" }, { value: "solid", label: "纯色" }, { value: "scene", label: "柔和渐变" }];
export const FIT_LABELS = [{ value: "fill", label: "填充屏幕" }, { value: "fit", label: "适合于屏幕" }, { value: "stretch", label: "拉伸" }, { value: "center", label: "居中" }];
export const DEFAULT_COLOR = "#e7e3de";

const DB = "lulupet-backdrop", OS = "files", KEY = "wallpaper";
const isColor = (c) => typeof c === "string" && /^#[0-9a-f]{6}$/i.test(c);

function idb(mode, fn) {
  return new Promise((resolve, reject) => {
    if (!globalThis.indexedDB) return reject(new Error("no IndexedDB"));
    const open = indexedDB.open(DB, 1);
    open.onupgradeneeded = () => open.result.createObjectStore(OS);
    open.onerror = () => reject(open.error);
    open.onsuccess = () => {
      const db = open.result;
      const tx = db.transaction(OS, mode);
      const req = fn(tx.objectStore(OS));
      tx.oncomplete = () => { db.close(); resolve(req?.result); };
      tx.onerror = tx.onabort = () => { db.close(); reject(tx.error); };
    };
  });
}

/** The display a window is on, in the same coordinates as screenX / screenY. */
export function screenOf(win) {
  const s = win.screen;
  const num = (v, d) => (Number.isFinite(v) ? v : d);
  return { left: num(s.left, num(s.availLeft, 0)), top: num(s.top, 0), width: s.width, height: s.height };
}

export function createBackdrop() {
  let picture = null;          // {url, width, height, average}
  let geomOverride = null;     // dev: a pretend window position / display (automation can't move real windows)
  const geom = (win) => (geomOverride ? { ...geomOverride(win) } : win);
  const attached = new Map();  // surface element → {win, timer, raf, last}
  const listeners = new Set();

  function settings() {
    const s = store.get("backdrop", null) || {};
    const kind = KINDS.some((k) => k.value === s.kind) ? s.kind : null;
    return {
      kind: kind ?? (store.get("hasWallpaper", false) ? "wallpaper" : "solid"),
      chosen: kind,
      color: isColor(s.color) ? s.color : DEFAULT_COLOR,
      fit: FITS.includes(s.fit) ? s.fit : "fill",
    };
  }
  function set(patch) {
    const cur = store.get("backdrop", null) || {};
    store.set("backdrop", { ...cur, ...patch });
    applyAll();
  }

  async function decode(blob) {
    const url = URL.createObjectURL(blob);
    let width = 0, height = 0, average = null;
    try {
      const bmp = await createImageBitmap(blob);
      width = bmp.width; height = bmp.height;
      try {   // its average colour: shown while the slice loads, and around a 「适合于屏幕」 picture
        const c = new OffscreenCanvas(1, 1), g = c.getContext("2d");
        g.drawImage(bmp, 0, 0, 1, 1);
        const d = g.getImageData(0, 0, 1, 1).data;
        average = "#" + [d[0], d[1], d[2]].map((v) => v.toString(16).padStart(2, "0")).join("");
      } catch { /* no OffscreenCanvas */ }
      bmp.close?.();
    } catch { URL.revokeObjectURL(url); throw new Error("这张图片打不开，换一张试试"); }
    return { url, width, height, average };
  }

  async function load() {
    if (!store.get("hasWallpaper", false)) return;
    try {
      const blob = await idb("readonly", (os) => os.get(KEY));
      if (blob instanceof Blob) picture = await decode(blob);
      else store.set("hasWallpaper", false);
    } catch (e) { console.warn("wallpaper:", e?.message || e); }
    applyAll();
  }

  /** A picked file (image/*): kept locally, used right away. */
  async function setWallpaper(file) {
    if (!(file instanceof Blob) || !/^image\//.test(file.type)) throw new Error("请选一张图片（jpg / png / heic 转出来的 jpg）");
    const next = await decode(file);
    await idb("readwrite", (os) => os.put(file, KEY));
    if (picture) URL.revokeObjectURL(picture.url);
    picture = next;
    store.set("hasWallpaper", true);
    const cur = store.get("backdrop", null) || {};
    store.set("backdrop", { ...cur, kind: "wallpaper" });
    applyAll();
  }
  async function clearWallpaper() {
    try { await idb("readwrite", (os) => os.delete(KEY)); } catch { /* gone anyway */ }
    if (picture) URL.revokeObjectURL(picture.url);
    picture = null;
    store.set("hasWallpaper", false);
    const cur = store.get("backdrop", null) || {};
    if (cur.kind === "wallpaper") store.set("backdrop", { ...cur, kind: null });
    applyAll();
  }

  /** Paints one surface (a window's body, or the ?dev=pip box) for the current setting; the wallpaper slice behind it right now. */
  function paint(el) {
    const a = attached.get(el);
    if (!a) return;
    const win = a.win;
    const s = settings();
    const kind = s.kind === "wallpaper" && !picture ? "solid" : s.kind;
    el.dataset.backdrop = kind;
    const st = el.style;
    if (kind === "wallpaper") {
      const g = geom(win);
      const view = viewOrigin(g);
      if (el !== win.document.body) { const r = el.getBoundingClientRect(); view.x += r.left; view.y += r.top; }
      const slice = wallpaperSlice({ screen: screenOf(g), image: { width: picture.width, height: picture.height }, view, fit: s.fit });
      st.backgroundColor = picture.average || s.color;
      st.backgroundImage = `url("${picture.url}")`;
      st.backgroundRepeat = "no-repeat";
      st.backgroundSize = `${slice.size[0]}px ${slice.size[1]}px`;
      st.backgroundPosition = `${slice.position[0]}px ${slice.position[1]}px`;
    } else {
      st.backgroundImage = st.backgroundSize = st.backgroundPosition = st.backgroundRepeat = "";
      st.backgroundColor = kind === "solid" ? s.color : "";
    }
    a.last = where(win);
  }
  const where = (win) => { const g = geom(win); return `${g.screenX},${g.screenY},${g.outerWidth},${g.outerHeight},${g.innerWidth},${g.innerHeight},${g.screen.width}`; };

  /** Starts drawing into a window (the pet window or the PiP; el = its body unless given); follows it while it moves. */
  function attach(win, el = win.document.body) {
    if (attached.has(el)) { paint(el); return; }
    const a = { win, timer: 0, raf: 0, fastUntil: 0, last: "" };
    attached.set(el, a);
    const tick = () => {
      if (!attached.has(el)) return;
      if (win.document.hidden || settings().kind !== "wallpaper" || !picture) return;
      if (where(win) !== a.last) { paint(el); a.fastUntil = Date.now() + 1500; follow(); }
    };
    const follow = () => {   // every frame while the window is being dragged, then back to the slow check
      if (a.raf) return;
      const step = () => {
        a.raf = 0;
        if (!attached.has(el)) return;
        if (where(win) !== a.last) { paint(el); a.fastUntil = Date.now() + 1500; }
        if (Date.now() < a.fastUntil) a.raf = win.requestAnimationFrame(step);
      };
      a.raf = win.requestAnimationFrame(step);
    };
    a.timer = win.setInterval(tick, 250);
    a.onResize = () => paint(el);
    a.onVis = () => { if (!win.document.hidden) paint(el); };
    win.addEventListener("resize", a.onResize);
    win.document.addEventListener("visibilitychange", a.onVis);
    paint(el);
  }
  function detach(win, el = win.document.body) {
    const a = attached.get(el);
    if (!a) return;
    attached.delete(el);
    try {
      win.clearInterval(a.timer);
      if (a.raf) win.cancelAnimationFrame(a.raf);
      win.removeEventListener("resize", a.onResize);
      win.document.removeEventListener("visibilitychange", a.onVis);
      const st = el.style;
      st.backgroundImage = st.backgroundColor = st.backgroundSize = st.backgroundPosition = st.backgroundRepeat = "";
      delete el.dataset.backdrop;
    } catch { /* the window is gone */ }
  }

  function applyAll() {
    for (const el of attached.keys()) paint(el);
    for (const fn of listeners) fn();
  }

  return {
    load, settings, set, setWallpaper, clearWallpaper, attach, detach,
    hasWallpaper: () => !!picture,
    /** Dev only: fn(win) → {screenX, screenY, outerWidth, outerHeight, innerWidth, innerHeight, screen}; null = the real window. */
    devGeometry(fn) { geomOverride = typeof fn === "function" ? fn : null; for (const el of attached.keys()) paint(el); },
    pictureSize: () => (picture ? { width: picture.width, height: picture.height } : null),
    onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); },
  };
}
