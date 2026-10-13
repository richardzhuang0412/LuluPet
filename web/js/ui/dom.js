// Tiny DOM builder. Text only ever goes in through textContent / setAttribute (spec §8: no HTML parsing of any string).

/**
 * h("button.btn.primary", {onclick, title, type}, "发送", child…)
 * - selector: tag plus optional .classes and #id
 * - attrs: on* → addEventListener; `dataset` object; booleans toggle attributes; everything else setAttribute
 * - children: strings (as text nodes), nodes, null/false (skipped), arrays (flattened)
 */
export function h(sel, attrs, ...children) {
  const m = /^([a-z0-9-]+)?((?:[.#][\w-]+)*)$/i.exec(sel);
  const el = document.createElement(m[1] || "div");
  for (const part of m[2].match(/[.#][\w-]+/g) || []) {
    if (part[0] === ".") el.classList.add(part.slice(1));
    else el.id = part.slice(1);
  }
  if (attrs && (typeof attrs !== "object" || attrs instanceof Node || Array.isArray(attrs))) {
    children.unshift(attrs);
    attrs = null;
  }
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
    else if (k === "dataset") Object.assign(el.dataset, v);
    else if (k === "class") el.classList.add(...String(v).split(/\s+/).filter(Boolean));
    else if (v === true) el.setAttribute(k, "");
    else el.setAttribute(k, String(v));
  }
  append(el, children);
  return el;
}

export function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

/** Replaces all children. */
export function setChildren(el, ...children) {
  el.replaceChildren();
  return append(el, children);
}

export const $ = (sel, root = document) => root.querySelector(sel);

/** Short toast at the bottom of the main page. */
export function toast(text, ms = 3500) {
  const host = $("#toasts");
  if (!host) return;
  const t = h("div.toast", { role: "status" }, text);
  host.append(t);
  setTimeout(() => t.classList.add("out"), ms);
  setTimeout(() => t.remove(), ms + 400);
}

/** "刚刚" / "12 分钟前" / "3 小时前" / "昨天" / "10月2日" (PartnerBadge.ago). */
export function ago(fromMs, nowMs = Date.now()) {
  const secs = (nowMs - fromMs) / 1000;
  if (secs < 60) return "刚刚";
  if (secs < 3600) return `${Math.floor(secs / 60)} 分钟前`;
  const then = new Date(fromMs), now = new Date(nowMs);
  if (then.toDateString() === now.toDateString() || secs < 6 * 3600) return `${Math.floor(secs / 3600)} 小时前`;
  const y = new Date(nowMs); y.setDate(y.getDate() - 1);
  if (then.toDateString() === y.toDateString()) return "昨天";
  return `${then.getMonth() + 1}月${then.getDate()}日`;
}

export const nameOf = (character) => (character === "lumei" ? "噜妹" : "噜噜");
