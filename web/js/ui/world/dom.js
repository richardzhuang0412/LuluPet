// Document-aware DOM helpers for the world. Nodes are made with the document the world currently lives in (the main
// page or the Document PiP window), never the opener's global `document`. Text only goes in via text nodes.

/** h(doc, "div.a.b", {onclick, title, dataset}, "text", child…) */
export function h(doc, sel, attrs, ...children) {
  const m = /^([a-z0-9-]+)?((?:[.#][\w-]+)*)$/i.exec(sel);
  const el = doc.createElement(m[1] || "div");
  for (const part of m[2].match(/[.#][\w-]+/g) || []) {
    if (part[0] === ".") el.classList.add(part.slice(1));
    else el.id = part.slice(1);
  }
  if (attrs && (typeof attrs !== "object" || attrs.nodeType || Array.isArray(attrs))) {
    children.unshift(attrs);
    attrs = null;
  }
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
    else if (k === "dataset") Object.assign(el.dataset, v);
    else if (v === true) el.setAttribute(k, "");
    else el.setAttribute(k, String(v));
  }
  append(doc, el, children);
  return el;
}

export function append(doc, el, children) {
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c.nodeType ? c : doc.createTextNode(String(c)));
  }
  return el;
}

/** Removes `el` once its CSS animation ends (or after `ms` as a fallback). */
export function removeLater(el, win, ms) {
  let done = false;
  const go = () => { if (!done) { done = true; el.remove(); } };
  el.addEventListener("animationend", go, { once: true });
  win.setTimeout(go, ms);
}

export const nameOf = (character) => (character === "lumei" ? "噜妹" : "噜噜");
