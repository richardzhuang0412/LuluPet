// 传话 (ComposeWindow compose tab): a text box (500 UTF-16 units, Enter sends), the 快捷栏 (8 favourites, each with its
// name under it, like the Mac quick bar), small ❤️ 爱心 · 💧 喝水 · 🧍 动动 buttons (+ 🏃 去找TA · 👀 偷看 in the tab) and
// 「全部表情 ›」 for the grouped grid. Friend mode hides intimate stickers. 装上 / 拿下 the quick bar with right-click
// (long-press on phones) or in 设置 → 表情. The same element moves into the PiP window / the 传话 popup (`.compact`).

import { h, setChildren, toast } from "./dom.js";
import { stickerList, thumbEl, defaultFavorites } from "./assets.js";
import { stickerRules, clampText } from "./deps.js";
import { store } from "./store.js";

const MAX = 500;

/** Shared quick-bar state (also used by 设置 → 表情). */
export function quickBar() {
  const counts = () => store.get("stickerSendCounts", {}) || {};
  const recent = () => store.get("stickerRecent", {}) || {};
  function stored() {
    let bar = store.get("stickerQuickBar");
    if (!Array.isArray(bar)) {
      bar = stickerRules.seedQuickBar(defaultFavorites(), counts(), recent(), stickerList().map((s) => s.id));
      store.set("stickerQuickBar", bar);
    }
    return bar;
  }
  return {
    counts, recent, stored,
    shown: (visible) => stickerRules.shownBar(stored(), visible, counts(), recent()),
    toggle(s, visible) {
      const bar = stored();
      if (bar.includes(s.id)) {
        store.set("stickerQuickBar", stickerRules.removed(s.id, bar));
        return `「${s.label}」从快捷栏拿下了`;
      }
      const { list, replaced } = stickerRules.equipped(s.id, bar, visible);
      store.set("stickerQuickBar", list);
      const old = replaced && stickerList().find((x) => x.id === replaced);
      return old ? `快捷栏满了，「${old.label}」换成了「${s.label}」` : `「${s.label}」放进快捷栏了`;
    },
  };
}

/** send({kind, …}); act("heart" | "visit" | "peek" | "water" | "stand"). */
export function createCompose({ send, act, onExpand }) {
  let allowIntimate = true;
  let expanded = false;
  const bar = quickBar();
  const visibleIds = () => stickerRules.visibleIds(stickerList(), allowIntimate);

  const coarse = matchMedia("(pointer: coarse)").matches;
  const hint = h("div.compose-hint", { hidden: true, role: "status" });
  const quick = h("div.quickbar", { role: "list", "aria-label": "快捷栏" });
  const moreBtn = h("button.link.more", { type: "button", "aria-expanded": "false", onclick: () => toggleMore() }, "全部表情 ›");
  const all = h("div.all-stickers", { hidden: true });
  const text = h("textarea.compose-text", { rows: "2", placeholder: "想对TA说点什么…", "aria-label": "想对TA说点什么", maxlength: "2000" });
  const counter = h("span.counter", "0/500");
  const sendBtn = h("button.btn.primary.send", { type: "button", disabled: true, onclick: () => sendText() }, "发送");
  const actBtn = (label, title, kind, cls = "") => h("button.mini-act" + cls, { type: "button", title, "aria-label": title, onclick: () => act(kind) }, label);

  // Like the Mac compose window: text first, the 8 favourites with their names, a row of small actions, the full grid on demand.
  // `.compact` (PiP / the small 传话 popup) hides the hints and the 去找TA / 偷看 extras.
  const el = h("section.compose", { "aria-label": "传话" },
    hint,
    h("div.text-box", text, h("div.text-foot",
      coarse ? null : h("span.enter-hint", "Enter 发送 · Shift+Enter 换行"), counter, sendBtn)),
    quick,
    h("div.mini-row",
      actBtn("❤️ 爱心", "给TA发一颗爱心", "heart", ".heart"),
      actBtn("💧 喝水", "让 TA 的宠物跑过去叫 TA 喝水", "water"),
      actBtn("🧍 动动", "让 TA 的宠物跑过去叫 TA 起来动动", "stand"),
      actBtn("🏃 去找TA", "跑去TA的桌面串门（TA不在线时会跑回来）", "visit", ".extra"),
      actBtn("👀 偷看", "马上看看 TA 这会儿在干嘛（TA 不会知道哦）", "peek", ".extra"),
      moreBtn),
    h("div.bar-hint", coarse ? "长按表情：放进 / 拿下快捷栏" : "右键表情：放进 / 拿下快捷栏"),
    all);

  const length = () => text.value.length;   // UTF-16 units, like the Firebase rule
  function updateCounter() {
    const n = length();
    counter.textContent = `${n}/${MAX}`;
    counter.classList.toggle("over", n > MAX);
    sendBtn.disabled = text.value.trim() === "" || n > MAX;
  }
  text.addEventListener("input", updateCounter);
  text.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing && e.keyCode !== 229) {   // not while the IME is composing
      e.preventDefault();
      sendText();
    }
  });

  function sendText() {
    const t = text.value.trim();
    if (!t || length() > MAX) return;
    send({ kind: "text", text: clampText(t) });
    text.value = "";
    updateCounter();
  }

  function sendSticker(s) {
    const c = bar.counts();
    c[s.id] = (c[s.id] || 0) + 1;
    store.set("stickerSendCounts", c);
    store.set("stickerRecent", stickerRules.recorded(s.id, Date.now(), bar.recent()));
    send({ kind: "sticker", stickerId: s.id, label: s.label });
  }

  function stickerButton(s, onBar) {
    const b = h("button.sticker", { type: "button", title: `发送「${s.label}」` + (onBar ? "（右键：从快捷栏拿下）" : "（右键：放进 / 拿下快捷栏）"),
      "aria-label": `发送「${s.label}」`, role: onBar ? "listitem" : null, onclick: () => sendSticker(s) },
    thumbEl(s, onBar ? 32 : 40, document), h("span.sticker-label", s.label));
    b.addEventListener("contextmenu", (e) => { e.preventDefault(); toast(bar.toggle(s, visibleIds())); render(); });
    return b;
  }

  function toggleMore(force) {
    const next = typeof force === "boolean" ? force : !expanded;
    if (next === expanded) return;
    expanded = next;
    all.hidden = !expanded;
    moreBtn.textContent = expanded ? "收起 ‹" : "全部表情 ›";
    moreBtn.setAttribute("aria-expanded", String(expanded));
    if (expanded) renderAll();
    onExpand?.(expanded);
  }

  function renderAll() {
    const visible = new Set(visibleIds());
    const on = new Set(bar.stored());
    const list = stickerList().filter((s) => visible.has(s.id));
    setChildren(all, stickerRules.grouped(list).map(({ title, stickers }) =>
      h("div.sticker-group", h("div.group-title", title),
        h("div.sticker-grid", stickers.map((s) => {
          const b = stickerButton(s, false);
          if (on.has(s.id)) b.classList.add("on-bar");
          return b;
        })))));
  }

  function render() {
    const byId = new Map(stickerList().map((s) => [s.id, s]));
    setChildren(quick, bar.shown(visibleIds()).map((id) => byId.get(id)).filter(Boolean).map((s) => stickerButton(s, true)));
    if (expanded) renderAll();
  }

  return {
    el,
    focus: () => text.focus({ preventScroll: true }),
    render,
    /** compact = PiP / the small 传话 window: no hints, no 去找TA / 偷看 (they're in 🍊), the grid folded. */
    setCompact(on) { el.classList.toggle("compact", !!on); if (on) toggleMore(false); },
    showAll: (on) => toggleMore(on),
    isExpanded: () => expanded,
    setPolicy(intimate) {
      if (intimate === allowIntimate) return;
      allowIntimate = intimate;
      render();
    },
    /** name: 噜噜 / 噜妹; note: 「TA 开了勿扰，消息会先放在 TA 那儿」 or null. */
    setPartner(name, note) {
      text.placeholder = `想对${name}说点什么…`;
      hint.hidden = !note;
      hint.textContent = note || "";
    },
    /** A sticker my seat sent from elsewhere (the channel's `own` event); counted once per message key. */
    countSent(id, key) {
      const seen = store.get("stickerCountedKeys", []) || [];
      if (key && seen.includes(key)) return;
      const c = bar.counts();
      c[id] = (c[id] || 0) + 1;
      store.set("stickerSendCounts", c);
      if (key) store.set("stickerCountedKeys", [...seen, key].slice(-200));
    },
  };
}
