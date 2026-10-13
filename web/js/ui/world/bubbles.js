// Speech bubbles over the pets (port of BubbleWindow + AckQueue): one bubble at a time, the rest wait (「还有 N 条」),
// cards go before ordinary bubbles. Text / sticker bubbles stay until acknowledged (「收到 ❤️」 or a click on the
// bubble); a bubble with buttons closes through them; `autoHide` ones go by themselves. Only an acknowledged item
// is handed to onDismiss (→ marked read); `leaveAllForHost` (the visitor's time is up) keeps everything, unread.
//
// item = {header, text?, sticker?: {url, caption}, card?: {lines, preview, button}, buttons?: [{title, primary}],
//         autoHide?: ms, atHome?, tag?, msg?, alsoRead?: [msg], onButton?(i), onClose?(), onShown?()}

import { h } from "./dom.js";
import { VISITS } from "./rules.js";

export function wantsAck(item) {
  return item.autoHide == null && !(item.buttons?.length) && !item.card;
}

/** AckQueue with card priority and tag lookups; pure (tested in web/tests/world.test.mjs). */
export class BubbleQueue {
  constructor() { this.current = null; this.waiting = []; }
  get count() { return (this.current ? 1 : 0) + this.waiting.length; }
  get all() { return (this.current ? [this.current] : []).concat(this.waiting); }
  /** → true when it became the current bubble. */
  enqueue(item) {
    if (!this.current) { this.current = item; return true; }
    if (item.card) {
      const i = this.waiting.findIndex((w) => !w.card);
      if (i < 0) this.waiting.push(item); else this.waiting.splice(i, 0, item);
    } else this.waiting.push(item);
    return false;
  }
  /** My own reminder (urgent): shown now; the bubble it pushes aside comes right back after it. Behind other urgent ones. */
  preempt(item) {
    if (!this.current) { this.current = item; return true; }
    if (this.current.urgent) {
      const i = this.waiting.findIndex((w) => !w.urgent);
      if (i < 0) this.waiting.push(item); else this.waiting.splice(i, 0, item);
      return false;
    }
    this.waiting.unshift(this.current);
    this.current = item;
    return true;
  }
  acknowledge() {
    const done = this.current;
    if (!done) return null;
    this.current = this.waiting.shift() || null;
    return done;
  }
  /** Replaces the item with `tag` in place → "current" | "waiting" | null (not found). */
  replace(tag, item) {
    if (this.current?.tag === tag) { this.current = item; return "current"; }
    const i = this.waiting.findIndex((w) => w.tag === tag);
    if (i >= 0) { this.waiting[i] = item; return "waiting"; }
    return null;
  }
  /** Removes the item with `tag` → "current" | "waiting" | null. Removing the current one promotes the next. */
  remove(tag) {
    if (tag != null && this.current?.tag === tag) { this.acknowledge(); return "current"; }
    const i = this.waiting.findIndex((w) => w.tag === tag);
    if (i >= 0) { this.waiting.splice(i, 1); return "waiting"; }
    return null;
  }
  leaveAll(fn) { for (const it of this.all) fn(it); }
  clear() { const all = this.all; this.current = null; this.waiting = []; return all; }
}

export function createBubbles(world, { anchorFor, onShow, onDismiss }) {
  const q = new BubbleQueue();
  let el = null;
  let autoTimer = 0;
  let clearTimer = 0;

  function node() {
    if (!el) el = h(world.doc, "div.lw-bubble", { role: "status", "aria-live": "polite" });
    if (el.ownerDocument !== world.doc || !el.isConnected) world.layer.append(el);
    return el;
  }

  function render() {
    const item = q.current;
    world.timers.cancel(autoTimer);
    world.timers.cancel(clearTimer);
    if (!item || world.suspended) { hide(); return; }
    const doc = world.doc;
    const b = node();
    b.inert = false;
    const kids = [];
    if (item.header) kids.push(h(doc, "div.lw-b-head", item.header));
    if (item.card) {
      kids.push(h(doc, "div.lw-b-lines", item.card.lines.map((l) => h(doc, "div", l))));
      if (item.card.preview) kids.push(h(doc, "div.lw-b-preview", `“${item.card.preview}”`));
    } else if (item.sticker) {
      kids.push(item.sticker.url
        ? h(doc, "img.lw-b-sticker", { src: item.sticker.url, alt: item.sticker.caption || "", draggable: "false" })
        : h(doc, "div.lw-b-sticker.lw-b-missing", { "aria-hidden": "true" }, "🍊"));
      if (item.sticker.caption) kids.push(h(doc, "div.lw-b-caption", item.sticker.caption));
      if (item.sticker.note) kids.push(h(doc, "div.lw-b-note", item.sticker.note));
    } else if (item.text != null) kids.push(h(doc, "div.lw-b-text", item.text));
    const row = [];
    const pending = q.waiting.length;
    if (pending) row.push(h(doc, "span.lw-b-more", `（还有 ${pending} 条）`));
    const stop = (fn) => (e) => { e.stopPropagation(); fn(); };
    if (item.card) {
      row.push(h(doc, "button.lw-pill-btn.primary", { type: "button", onclick: stop(() => pressCard()) }, item.card.button || "看看"));
    } else if (item.buttons?.length) {
      item.buttons.slice(0, 2).forEach((bt, i) =>
        row.push(h(doc, "button.lw-pill-btn" + (bt.primary || i === 0 ? ".primary" : ""), { type: "button", onclick: stop(() => pressButton(i)) }, bt.title)));
    } else if (wantsAck(item)) {
      row.push(h(doc, "button.lw-pill-btn.small", { type: "button", onclick: stop(() => dismiss()) }, VISITS.ackTitle));
    }
    if (row.length) kids.push(h(doc, "div.lw-b-row", row));
    b.replaceChildren(...kids);
    b.classList.toggle("card", !!item.card);
    b.classList.toggle("sticker", !!item.sticker);
    b.classList.add("show");
    b.onclick = () => dismiss();
    layout();
    if (item.autoHide != null) autoTimer = world.timers.after(item.autoHide, () => { if (q.current === item) dismiss(); });
  }

  /** Fades the bubble out; it leaves the live region / focus order at once and the DOM once the fade is over. */
  function hide() {
    if (!el) return;
    el.classList.remove("show");
    el.inert = true;   // out of the accessibility tree and focus order at once (a focused 收到 lets go too)
    el.onclick = null;
    clearTimer = world.timers.after(220, () => { if (!el.classList.contains("show")) el.replaceChildren(); });
  }

  /**
   * Puts the bubble over its pet, inside the stage, out of the corner buttons' way (world.insets = the top-right
   * box the page keeps for 📌 / 🍊): slid left of them when it fits, else pushed down below them.
   */
  function layout() {
    const item = q.current;
    if (!el || !item || !el.classList.contains("show")) return;
    const a = anchorFor(item);
    const W = world.width, H = world.height;
    const bw = el.offsetWidth, bh = el.offsetHeight;
    const cx = a ? a.liveX : W / 2;
    let left = Math.min(Math.max(4, cx - bw / 2), Math.max(4, W - bw - 4));
    const want = (a ? a.height : 100) + 6;
    let bottom = Math.max(4, Math.min(want, H - bh - 4));
    const ins = world.insets || { top: 0, right: 0 };
    if (ins.top > 0 && ins.right > 0 && H - bottom - bh < ins.top && left + bw > W - ins.right) {
      const slid = W - ins.right - bw - 2;
      if (slid >= 4 && cx <= slid + bw + 24) left = slid;       // the tail still points at the pet
      else bottom = Math.max(4, Math.min(bottom, H - ins.top - bh - 2));
    }
    el.style.left = left.toFixed(0) + "px";
    el.style.bottom = bottom.toFixed(0) + "px";
    el.style.setProperty("--tail", Math.min(Math.max(16, cx - left), bw - 16).toFixed(0) + "px");
  }

  function shown(item) { onShow?.(item); item.onShown?.(); }

  /** Acknowledge the current bubble (click / 收到 / auto-hide). */
  function dismiss(viaButton = false) {
    const done = q.acknowledge();
    if (!done) return;
    if (!viaButton) done.onClose?.();
    onDismiss?.(done);
    render();
    if (q.current) shown(q.current);
  }
  function pressButton(i) {
    const item = q.current;
    if (!item) return;
    dismiss(true);
    item.onButton?.(i);
  }
  function pressCard() {
    const item = q.current;
    if (!item) return;
    dismiss(true);
    item.card?.onClick?.();
  }

  return {
    enqueue(item) {
      if (item.urgent ? q.preempt(item) : q.enqueue(item)) { render(); shown(item); } else render();
    },
    /** Replace the bubble with `item.tag` in place (no new sound); false when there is none. */
    replace(item) {
      const old = q.all.find((x) => x.tag === item.tag);
      const where = q.replace(item.tag, item);
      if (!where) return false;
      old?.onReplaced?.();
      render();
      return true;
    },
    /** Takes the bubble with `tag` away without a button (its onClose runs, it is not "read"). */
    close(tag) {
      const item = q.all.find((x) => x.tag === tag);
      if (!item) return false;
      const where = q.remove(tag);
      item.onClose?.();
      render();
      if (where === "current" && q.current) shown(q.current);
      return true;
    },
    dismiss,
    pressAck() { if (q.current && wantsAck(q.current)) dismiss(); },
    pressButton,
    pressCard,
    /** Visitor's time is up: text / sticker bubbles stay on my pet as 「TA 留下的话」 (unread). → how many wait. */
    leaveAllForHost() {
      q.leaveAll((it) => { if (wantsAck(it)) { it.header = VISITS.pinnedHeader; it.atHome = true; } });
      render();
      return q.count;
    },
    clearAll() { world.timers.cancel(autoTimer); const all = q.clear(); render(); all.forEach((x) => x.onClose?.()); },
    find: (pred) => q.all.find(pred) || null,
    get current() { return q.current; },
    get showing() { return !!q.current; },
    get onScreen() { return !!q.current && !world.suspended; },
    get count() { return q.count; },
    render,
    layout,
  };
}
