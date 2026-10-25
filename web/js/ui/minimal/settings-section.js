// 设置 → 极简模式. In the full pet: one switch to go minimal. In 极简模式: the switch back plus its own options
// (提示音 · 显示表情小图 · 通知里不显示消息内容 · 低调标题).

import { h } from "../dom.js";
import { toggle } from "../tools-tab.js";
import { minimalPrefs, switchMode } from "./mode.js";

const check = (label, on, onChange, hint) => [
  h("label.set-row.check-row", h("span.set-label", label), toggle(on, label, onChange)),
  hint ? h("div.set-note", hint) : null,
];

/** minimal = running in 极简模式; onChange() after an option changed (re-render title, list, settings). */
export function modeSection({ minimal, onChange = () => {} }) {
  const p = minimalPrefs.get();
  const set = (patch) => { minimalPrefs.set(patch); onChange(); };
  return h("section.set-section", h("h3.set-title", "极简模式"),
    check("极简模式（适合上班）", minimal, (v) => switchMode(v),
      minimal ? "关掉就回到完整的宠物（动画、串门、置顶小窗）。只影响这台电脑。"
        : "没有宠物和动画，只留一个安静的小面板：传话、TA 的提醒、喝水 / 站立 / 眼药水 / 番茄钟。TA 那边照常收到。只影响这台电脑。"),
    minimal ? [
      check("提醒时轻轻响一声", p.chime, (v) => set({ chime: v }), "只在你自己的提醒（喝水、站立、眼药水、番茄钟）时；TA 的消息不出声。"),
      check("显示表情小图", p.thumbs, (v) => set({ thumbs: v }), "关着时表情只显示名字，也不下载表情图片。"),
      check("通知里不显示消息内容", p.hideContent, (v) => set({ hideContent: v }), "系统通知只写「TA 发来一条消息」。"),
      check("低调标题", p.discreet, (v) => set({ discreet: v }), "标签页标题和图标变成「提醒」和一个小铃铛，面板和通知里不出现角色名。"),
    ] : null);
}
