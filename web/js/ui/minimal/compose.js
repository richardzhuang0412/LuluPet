// 极简模式 传话: a text box (Enter sends, Shift+Enter = new line, 500 units), a row of quick actions (❤️ 爱心 ·
// 💧 叫 TA 喝水 · 🧍 叫 TA 动动 · 表情) and the sticker list as NAMES only (快捷栏 first, then the groups). A sticker still
// goes out as the real sticker message, so TA sees the real one on the Mac. Right-click a name: 放进 / 拿下快捷栏.

import { h, setChildren, toast } from "../dom.js";
import { stickerList } from "../assets.js";
import { stickerRules, clampText } from "../deps.js";
import { quickBar } from "../compose.js";
import { store } from "../store.js";
import { icon } from "./icons.js";

const MAX = 500;

/** send({kind, …}); act("heart" | "water" | "stand"). */
export function createMiniCompose({ send, act }) {
  let intimate = true;
  let pickerOpen = false;
  const bar = quickBar();
  const visibleIds = () => stickerRules.visibleIds(stickerList(), intimate);

  const note = h("div.mi-note", { role: "status", hidden: true });
  const text = h("textarea.mi-text", { rows: "1", placeholder: "说点什么… Enter 发送", "aria-label": "想对TA说的话", maxlength: "2000" });
  const sendBtn = h("button.mi-send", { type: "button", "aria-label": "发送", title: "发送（Enter）", disabled: true, onclick: () => sendText() }, icon("send", 17));
  const picker = h("div.mi-picker", { hidden: true, role: "dialog", "aria-label": "表情" });
  const stickerBtn = h("button.mi-chip", { type: "button", "aria-expanded": "false", "aria-haspopup": "dialog", onclick: () => togglePicker() }, "表情");
  const chip = (label, title, kind) => h("button.mi-chip", { type: "button", title, onclick: () => act(kind) }, label);
  const actions = h("div.mi-actions",
    chip("❤️ 爱心", "给 TA 发一颗爱心", "heart"),
    chip("💧 叫 TA 喝水", "叫 TA 喝水（TA 可以回 马上 / 等会儿）", "water"),
    chip("🧍 叫 TA 动动", "叫 TA 起来动一动", "stand"),
    stickerBtn);
  const el = h("section.mi-compose", { "aria-label": "传话" }, picker, note,
    h("div.mi-input", text, sendBtn), actions);

  const len = () => text.value.length;
  function update() {
    sendBtn.disabled = text.value.trim() === "" || len() > MAX;
    text.classList.toggle("over", len() > MAX);
    text.style.height = "auto";
    text.style.height = Math.min(96, text.scrollHeight) + "px";
  }
  text.addEventListener("input", update);
  text.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); sendText(); }
    if (e.key === "Escape" && pickerOpen) togglePicker(false);
  });

  function sendText() {
    const t = text.value.trim();
    if (!t) return;
    if (len() > MAX) { showNote(`太长啦：最多 ${MAX} 个字`); return; }
    send({ kind: "text", text: clampText(t) });
    text.value = "";
    update();
  }

  function sendSticker(s) {
    const c = bar.counts();
    c[s.id] = (c[s.id] || 0) + 1;
    store.set("stickerSendCounts", c);
    store.set("stickerRecent", stickerRules.recorded(s.id, Date.now(), bar.recent()));
    send({ kind: "sticker", stickerId: s.id, label: s.label });
    togglePicker(false);
    text.focus({ preventScroll: true });
  }

  function nameChip(s, on) {
    const b = h("button.mi-name", { type: "button", class: on ? "on-bar" : null, title: on ? "发送（右键：从快捷栏拿下）" : "发送（右键：放进快捷栏）",
      onclick: () => sendSticker(s) }, s.label);
    b.addEventListener("contextmenu", (e) => { e.preventDefault(); toast(bar.toggle(s, visibleIds())); renderPicker(); });
    return b;
  }

  function renderPicker() {
    const visible = new Set(visibleIds());
    const byId = new Map(stickerList().map((x) => [x.id, x]));
    const onBar = bar.shown([...visible]).map((id) => byId.get(id)).filter(Boolean);
    const onSet = new Set(onBar.map((s) => s.id));
    const groups = stickerRules.grouped(stickerList().filter((s) => visible.has(s.id) && !onSet.has(s.id)));
    setChildren(picker,
      h("div.mi-picker-group", h("div.mi-picker-title", "快捷栏"), h("div.mi-names", onBar.map((s) => nameChip(s, true)))),
      groups.map(({ title, stickers }) => h("div.mi-picker-group", h("div.mi-picker-title", title), h("div.mi-names", stickers.map((s) => nameChip(s, false))))),
      h("div.mi-picker-hint", "TA 收到的是真表情 · 右键名字：放进 / 拿下快捷栏"));
  }

  function togglePicker(force) {
    pickerOpen = typeof force === "boolean" ? force : !pickerOpen;
    picker.hidden = !pickerOpen;
    stickerBtn.setAttribute("aria-expanded", String(pickerOpen));
    stickerBtn.classList.toggle("on", pickerOpen);
    if (pickerOpen) { renderPicker(); picker.scrollTop = 0; }
  }
  document.addEventListener("pointerdown", (e) => { if (pickerOpen && !picker.contains(e.target) && e.target !== stickerBtn) togglePicker(false); }, true);

  let noteTimer = null;
  /** A short line under the list (TA offline / 勿扰 / not paired); fades after a few seconds. */
  function showNote(line, ms = 4000) {
    note.textContent = line;
    note.hidden = false;
    clearTimeout(noteTimer);
    noteTimer = setTimeout(() => { note.hidden = true; }, ms);
  }

  return {
    el,
    focus: () => text.focus({ preventScroll: true }),
    showNote,
    setPolicy(v) { intimate = v; if (pickerOpen) renderPicker(); },
    setPartner(name) { text.placeholder = `对${name}说点什么… Enter 发送`; },
  };
}
