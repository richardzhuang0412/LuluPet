// 桌宠模式 (pet-only window: the installed app by default, and the 桌宠小窗 Chrome popup, js/ui/petpopup.js — no install needed): the window shrinks to just the pet on a background
// that pretends to be the desktop (backdrop.js), no title bar (window-controls-overlay), no panel. Like the Mac:
//   drag the pet → the window moves with it · double-click → the panel in its own small window next to the pet
//   (window.open; if popups are blocked, the window grows and shows the panel under the pet) · right-click → 🍊 ·
//   hover → tiny 💬 📌 🍊 · 💬 → the small 传话 window. TA's visits widen the window a little, both sides, and it
//   shrinks back afterwards. Position is remembered (`lulupet.petWindow`), first run = bottom-right above the Dock.
// The panel element is moved (whole, state and all) into the popup and back when it closes, like the PiP does.

import { h } from "./dom.js";
import { store } from "./store.js";

import { PANEL, COMPACT, COMPACT_ALL, petWindowSize, visitExtra, regrow, besideRect } from "./petwindow-math.js";
export { layoutFor } from "./petwindow-math.js";

const availOf = (s) => ({ left: s.availLeft ?? 0, top: s.availTop ?? 0, width: s.availWidth, height: s.availHeight });

/**
 * world (createWorld), panel: the panel element, compose, selectTab(tab), backdrop, scale() → petScale,
 * setDocHost(doc | null) → where sheets / toasts open while the panel window is up.
 */
export function createPetMode({ world, panel, compose, selectTab, backdrop, scale, setDocHost, onPanel }) {
  const home = { parent: panel.parentNode, next: panel.nextSibling };
  let popup = null;           // the panel window
  let popupMode = null;       // "compact" | "full"
  let inline = false;         // popups blocked: the panel shows under the pet in this window
  let visiting = false;
  let shrinkTimer = 0;
  let dragFrom = null;

  const frame = () => ({ w: Math.max(0, window.outerWidth - window.innerWidth), h: Math.max(0, window.outerHeight - window.innerHeight) });
  const outerRect = () => ({ x: window.screenX, y: window.screenY, width: window.outerWidth, height: window.outerHeight });

  /** Resize + move this window so its inside is `inner`, bottom centre kept. Quietly does nothing where not allowed. */
  function setInner(inner) {
    const f = frame();
    const to = { width: inner.width + f.w, height: inner.height + f.h };
    const r = regrow(outerRect(), to, availOf(window.screen));
    try {
      window.resizeTo(r.width, r.height);
      window.moveTo(r.x, r.y);
    } catch { /* a normal tab: the page just lays itself out in whatever size it has */ }
  }

  function wanted() {
    if (inline) return { width: PANEL.width, height: petWindowSize(scale()).height + PANEL.height - 150 };
    const s = petWindowSize(scale());
    return visiting ? { width: s.width + visitExtra(scale()), height: s.height } : s;
  }
  const fit = () => setInner(wanted());

  function remember() {
    if (visiting || inline || dragFrom) return;
    const want = wanted();
    if (Math.abs(window.innerWidth - want.width) > 4 || Math.abs(window.innerHeight - want.height) > 4) return;
    store.set("petWindow", { x: window.screenX, y: window.screenY });
  }

  /** First run: bottom-right above the Dock; later: where it was left. */
  function place(force = false) {
    const s = petWindowSize(scale()), f = frame();
    const saved = store.get("petWindow", null);
    const a = availOf(window.screen);
    const W = s.width + f.w, H = s.height + f.h;
    let x, y;
    if (!force && saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)) ({ x, y } = saved);
    else { x = a.left + a.width - W - 24; y = a.top + a.height - H - 6; }
    try {
      window.resizeTo(W, H);
      window.moveTo(x, y);
    } catch { /* not an app window */ }
    store.set("petWindow", { x, y });
  }

  // ---- drag the pet = move the window --------------------------------------------------------------------------
  function dragWindow({ phase, dx, dy }) {
    if (phase === "start") { dragFrom = { x: window.screenX, y: window.screenY }; return; }
    if (!dragFrom) return;
    try { window.moveTo(Math.round(dragFrom.x + dx), Math.round(dragFrom.y + dy)); } catch { /* not allowed */ }
    if (phase === "end") { dragFrom = null; setTimeout(remember, 300); }
  }

  // ---- the panel window ----------------------------------------------------------------------------------------
  const cssLink = (doc, href) => doc.head.append(Object.assign(doc.createElement("link"), { rel: "stylesheet", href: new URL(href, location.href).href }));

  function popupSize(mode) { return mode === "compact" ? (compose.isExpanded?.() ? COMPACT_ALL : COMPACT) : PANEL; }

  function openPanel(tab = "compose", { compact = false } = {}) {
    const mode = compact ? "compact" : "full";
    selectTab(tab);
    if (inline) { applyMode(mode, document); if (tab === "compose") compose.focus(); return; }
    if (popup && !popup.closed) {
      if (popupMode !== mode) { applyMode(mode, popup.document); resizePopup(); }
      popup.focus();
      if (tab === "compose") compose.focus();
      return;
    }
    const size = popupSize(mode);
    const r = besideRect(outerRect(), size, availOf(window.screen));
    let w = null;
    try { w = window.open("", "lulu-panel", `popup=yes,width=${r.width},height=${r.height},left=${r.x},top=${r.y}`); } catch { w = null; }
    if (!w) return showInline(tab, mode);
    popup = w;
    const doc = w.document;
    doc.title = "噜噜";
    doc.documentElement.lang = "zh-CN";
    doc.head.replaceChildren();
    doc.head.append(Object.assign(doc.createElement("meta"), { name: "viewport", content: "width=device-width, initial-scale=1" }));
    cssLink(doc, "css/app.css");
    doc.body.replaceChildren(panel, h("div#toasts.toasts", { "aria-live": "polite" }));
    doc.body.classList.add("panel-window");
    applyMode(mode, doc);
    setDocHost(doc);
    doc.addEventListener("keydown", (e) => { if (e.key === "Escape" && !e.defaultPrevented && !doc.querySelector(".sheet, .menu")) w.close(); });
    w.addEventListener("pagehide", () => { if (popup === w) restore(); }, { once: true });
    try { w.focus(); } catch { /* ignore */ }
    if (tab === "compose") compose.focus();
    onPanel?.(true);
  }

  function applyMode(mode, doc) {
    popupMode = mode;
    doc.body.classList.toggle("compact-window", mode === "compact");
    compose.setCompact(mode === "compact");
  }

  function resizePopup() {
    if (!popup || popup.closed) return;
    const size = popupSize(popupMode);
    const f = { w: Math.max(0, popup.outerWidth - popup.innerWidth), h: Math.max(0, popup.outerHeight - popup.innerHeight) };
    const W = size.width + f.w, H = size.height + f.h;
    const bottom = popup.screenY + popup.outerHeight;
    try { popup.resizeTo(W, H); popup.moveTo(popup.screenX, Math.max(availOf(window.screen).top, bottom - H)); } catch { /* ignore */ }
  }

  /** 「全部表情 ›」 in the small 传话 window: it grows enough for the grid (and back). */
  function composeExpanded() { if (popupMode === "compact") resizePopup(); }

  function restore() {
    popup = null;
    popupMode = null;
    compose.setCompact(false);
    home.parent.insertBefore(panel, home.next && home.next.parentNode === home.parent ? home.next : null);
    setDocHost(null);
    onPanel?.(false);
  }

  function showInline(tab, mode) {
    inline = true;
    document.body.classList.add("panel-inline");
    applyMode(mode === "compact" ? "full" : mode, document);
    selectTab(tab);
    fit();
    onPanel?.(true);
  }
  function closeInline() {
    if (!inline) return;
    inline = false;
    document.body.classList.remove("panel-inline");
    compose.setCompact(false);
    fit();
    onPanel?.(false);
  }

  /** Double-click on the pet: opens the panel; with the panel under the pet (popups blocked) a second one folds it away. */
  function togglePanel(tab = "compose") {
    if (inline) return closeInline();
    openPanel(tab);
  }

  function closePanel() {
    if (popup && !popup.closed) popup.close();
    closeInline();
  }

  // ---- visits widen the window -----------------------------------------------------------------------------------
  world.on("visit", (on) => {
    clearTimeout(shrinkTimer);
    if (on) { visiting = true; fit(); return; }
    shrinkTimer = setTimeout(() => { visiting = false; fit(); }, 700);   // after the last wave-off
  });

  function start() {
    document.body.classList.add("pet-mode");
    backdrop.attach(window);
    world.setDragWindow(dragWindow);
    place();
    setInterval(remember, 2000);
    window.addEventListener("pagehide", () => { try { popup?.close(); } catch { /* ignore */ } });
    document.addEventListener("keydown", (e) => {   // Esc folds the panel under the pet away (popups blocked)
      if (e.key === "Escape" && inline && !e.defaultPrevented && !document.querySelector(".sheet, .menu")) closeInline();
    });
  }

  return {
    start, openPanel, togglePanel, closePanel, closeInline, fit, place, composeExpanded,
    panelOpen: () => !!(popup && !popup.closed) || inline,
    panelDoc: () => (popup && !popup.closed ? popup.document : null),
  };
}
