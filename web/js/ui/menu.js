// A small popover menu for 🍊 (StatusMenu): items are plain objects, submenus open inline (accordion — the app window
// is narrow, flyouts would fall off the edge). Opens in whichever document asked (main window or PiP).
//   item: {label, onClick, checked?, disabled?, hint?} | {header} | {note} | {separator: true} | {label, submenu: [items]}
// Keyboard: ↑ / ↓ move, → / Enter open a submenu, ← closes it, Esc closes the menu.

import { h } from "./dom.js";

let current = null;

export function closeMenu() {
  if (!current) return;
  const { el, doc, onKey, onDown, restore } = current;
  current = null;
  doc.removeEventListener("keydown", onKey, true);
  doc.removeEventListener("pointerdown", onDown, true);
  el.classList.add("out");
  setTimeout(() => el.remove(), 120);
  restore?.focus?.({ preventScroll: true });
}

export const menuOpen = () => !!current;

/** items: array or () => array (re-evaluated after every click that keeps the menu open). */
export function openMenu(items, { x, y, anchor, doc = document, keepOpen = false } = {}) {
  closeMenu();
  const getItems = typeof items === "function" ? items : () => items;
  const openSubs = new Set();
  const el = doc.createElement("div");
  el.className = "menu";
  el.setAttribute("role", "menu");
  el.setAttribute("aria-label", "噜噜菜单");
  const restore = doc.activeElement;

  function itemEl(it, path) {
    if (it.separator) return h("div.menu-sep", { role: "separator" });
    if (it.header) return h("div.menu-header", it.header);
    if (it.note) return h("div.menu-note", it.note);
    if (it.submenu) {
      const open = openSubs.has(path);
      const btn = h("button.menu-item.has-sub", { type: "button", role: "menuitem", "aria-haspopup": "true", "aria-expanded": String(open), disabled: it.disabled,
        onclick: () => { if (open) openSubs.delete(path); else openSubs.add(path); render(btn.dataset.path); }, dataset: { path } },
      h("span.menu-check", { "aria-hidden": "true" }), h("span.menu-label", it.label), it.hint ? h("span.menu-hint", it.hint) : null, h("span.menu-caret", { "aria-hidden": "true" }, "›"));
      return h("div.menu-group", { class: open ? "open" : null }, btn,
        open ? h("div.menu-sub", { role: "group" }, it.submenu.filter(Boolean).map((s, i) => itemEl(s, `${path}.${i}`))) : null);
    }
    const role = it.checked != null ? (it.radio ? "menuitemradio" : "menuitemcheckbox") : "menuitem";
    return h("button.menu-item", { type: "button", role, "aria-checked": it.checked != null ? String(!!it.checked) : null, disabled: it.disabled, dataset: { path },
      title: it.title ?? null,
      onclick: () => {
        const stay = it.keepOpen ?? keepOpen;
        if (!stay) closeMenu();
        it.onClick?.();
        if (stay) render(path);
      } },
    h("span.menu-check", { "aria-hidden": "true" }, it.checked ? "✓" : ""), h("span.menu-label", it.label), it.hint ? h("span.menu-hint", it.hint) : null);
  }

  function render(focusPath) {
    el.replaceChildren(...getItems().filter(Boolean).map((it, i) => itemEl(it, String(i))));
    if (focusPath != null) el.querySelector(`[data-path="${focusPath}"]`)?.focus({ preventScroll: true });
    place();
  }

  function place() {
    const win = doc.defaultView;
    const W = win.innerWidth, H = win.innerHeight;
    const r = anchor?.getBoundingClientRect();
    const w = Math.min(280, W - 16);
    el.style.width = w + "px";
    el.style.maxHeight = (H - 16) + "px";
    const ax = r ? r.right - w : x ?? 8;
    const ay = r ? r.bottom + 6 : y ?? 8;
    el.style.left = Math.max(8, Math.min(ax, W - w - 8)) + "px";
    const hgt = el.offsetHeight;
    el.style.top = Math.max(8, Math.min(ay, H - hgt - 8)) + "px";
  }

  const focusables = () => [...el.querySelectorAll("button.menu-item:not([disabled])")];
  function onKey(e) {
    const list = focusables();
    const i = list.indexOf(doc.activeElement);
    if (e.key === "Escape") { e.preventDefault(); closeMenu(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); list[(i + 1) % list.length]?.focus(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); list[(i - 1 + list.length) % list.length]?.focus(); }
    else if (e.key === "ArrowRight" && doc.activeElement?.classList.contains("has-sub") && doc.activeElement.getAttribute("aria-expanded") === "false") { e.preventDefault(); doc.activeElement.click(); }
    else if (e.key === "ArrowLeft") {
      const group = doc.activeElement?.closest(".menu-group.open");
      if (group) { e.preventDefault(); group.querySelector(".has-sub").click(); }
    }
  }
  function onDown(e) { if (!el.contains(e.target) && !anchor?.contains(e.target)) closeMenu(); }

  doc.body.append(el);
  current = { el, doc, onKey, onDown, restore };
  doc.addEventListener("keydown", onKey, true);
  doc.addEventListener("pointerdown", onDown, true);
  render();
  focusables()[0]?.focus({ preventScroll: true });
  return { close: closeMenu, refresh: () => render() };
}
