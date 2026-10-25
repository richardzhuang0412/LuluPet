// 极简模式: the inline cards that stand in for the pet's bubbles — my own reminders (喝了 / 等会儿), eye drops
// (滴了 / 等会儿), the pomodoro, and TA's reminders (马上 / 等会儿). One card per tag; a newer one with the same tag
// replaces the old one. add() resolves with the index of the button pressed, or null when the card was closed.

import { h } from "../dom.js";

/** onAdd() after a card appears (the narrow panel folds 小工具 away to make room). */
export function createNotices({ onAdd = () => {} } = {}) {
  const el = h("div.mi-notices", { role: "region", "aria-label": "提醒", "aria-live": "polite" });
  const cards = new Map();   // tag → {node, resolve}

  function close(tag, value = null) {
    const c = cards.get(tag);
    if (!c) return;
    cards.delete(tag);
    c.node.remove();
    c.resolve(value);
    el.hidden = cards.size === 0;
  }

  /** {tag, tone: "own" | "ta", title, line, buttons: [{title, primary}], closable} */
  function add({ tag, tone = "own", title, line, buttons = [], closable = false }) {
    close(tag);
    let resolve;
    const done = new Promise((r) => { resolve = r; });
    const node = h("div.mi-card", { dataset: { tone }, role: "group", "aria-label": title },
      h("div.mi-card-text", h("div.mi-card-title", title), line ? h("div.mi-card-line", line) : null),
      h("div.mi-card-actions",
        buttons.map((b, i) => h(b.primary ? "button.mi-btn.primary" : "button.mi-btn", { type: "button", onclick: () => close(tag, i) }, b.title)),
        closable || !buttons.length ? h("button.mi-btn.ghost", { type: "button", "aria-label": "关掉", onclick: () => close(tag) }, "知道了") : null));
    cards.set(tag, { node, resolve });
    el.append(node);
    el.hidden = false;
    onAdd();
    return done;
  }

  el.hidden = true;
  return { el, add, close, has: (tag) => cards.has(tag) };
}
