// 极简模式 小工具: the same controllers as the 小工具 tab (番茄钟 / 喝水 / 站立 / 眼药水) in a compact list.
// The full cards (pomodoro lengths, eye-drop times…) open in a sheet from 「更多设置」.

import { h, setChildren, toast } from "../dom.js";
import { toggle, stepper } from "../tools-tab.js";
import { clock, toolBits } from "./logic.js";

export function createMiniTools({ pomodoro, reminders, eyedrops, onSettingsChange, openMore }) {
  const list = h("div.mi-tool-list");
  const el = h("div.mi-tools-body", list,
    h("div.mi-tools-foot", h("button.mi-link", { type: "button", onclick: () => openMore() }, "更多设置（番茄时长、眼药水时间）")));

  const row = (cls, ...children) => h("div.mi-tool" + cls, children);
  const name = (text) => h("span.mi-tool-name", text);

  function pomoRow() {
    const p = pomodoro.state();
    const idle = p.phase === "idle";
    const btn = (label, fn, primary = false) => h(primary ? "button.mi-btn.primary.small" : "button.mi-btn.small", { type: "button", onclick: () => { fn(); render(); } }, label);
    return row(".pomo",
      h("div.mi-tool-line", name("🍅 番茄钟"),
        idle ? h("span.mi-tool-meta", pomodoro.durations()) : h("span.mi-clock", { "aria-label": pomodoro.stateLine() }, clock(pomodoro.remaining()))),
      h("div.mi-tool-line",
        h("span.mi-tool-sub", idle ? "没在专注" : pomodoro.stateLine()),
        h("span.mi-tool-btns",
          idle ? btn("开始专注", pomodoro.start, true) : [
            btn(pomodoro.isPaused() ? "继续" : "暂停", pomodoro.pauseResume, true),
            p.phase !== "focus" ? btn("跳过休息", pomodoro.skipBreak) : null,
            btn("结束", pomodoro.stop)])));
  }

  function remindRow(kind) {
    const s = reminders.settings();
    const on = s[kind + "Enabled"];
    const minutes = Math.round(s[kind + "Interval"] / 60);
    const label = kind === "water" ? "💧 喝水提醒" : "🧍 站立提醒";
    const save = (next) => { reminders.update(next); onSettingsChange(); render(); };
    return row("." + kind,
      h("div.mi-tool-line", name(label), toggle(on, label, (v) => save({ ...s, [kind + "Enabled"]: v }))),
      on ? h("div.mi-tool-line",
        h("span.mi-tool-sub", liveLine(kind)),
        stepper(minutes, { min: 5, max: 180, step: 5, label: `${label}间隔（分钟）`, format: (v) => `每 ${v} 分` },
          (v) => save({ ...s, [kind + "Interval"]: v * 60 }))) : null);
  }

  function liveLine(kind) {
    const st = reminders.status(kind);
    const tail = kind === "water" ? ` · 今天 ${reminders.cups()} 杯` : "";
    if (!st) return "";
    if (st.phase === "showing") return "正在提醒" + tail;
    if (st.phase === "away") return "离开电脑，回来再计时" + tail;
    if (st.phase === "snoozed") return `${Math.max(1, Math.ceil(st.left / 60))} 分钟后再提醒` + tail;
    return `还差 ${Math.max(1, Math.ceil((st.left ?? 0) / 60))} 分钟` + tail;
  }

  /** The slot 「滴了」 marks: the one being reminded, else the latest past one not checked in yet. */
  function dueSlot() {
    const showing = eyedrops.showing();
    if (showing) return showing;
    const past = eyedrops.progress().slots.filter((d) => d.state === "showing" || d.state === "missed" || d.state === "unconfirmed");
    const last = past[past.length - 1];
    return last && !eyedrops.beforeSetup(last.time) ? eyedrops.todaySlot(last.time) : null;
  }

  function eyeRow() {
    const s = eyedrops.settings();
    const p = eyedrops.progress();
    const label = "👁️ 眼药水";
    const mark = { done: "✓", showing: "!", upcoming: "", missed: "–", unconfirmed: "–" };
    const slot = s.enabled ? dueSlot() : null;
    return row(".eye",
      h("div.mi-tool-line", name(label), s.enabled ? h("span.mi-tool-meta", `今天 ${p.done}/${p.total}`) : null,
        toggle(s.enabled, "眼药水提醒", (v) => {
          const times = s.times.length ? s.times : eyedrops.suggested(eyedrops.defaultCount);
          const ok = eyedrops.validate(times);
          if (!ok.ok) { toast(ok.error); return; }
          eyedrops.apply({ enabled: v, times: ok.times });
          render();
        })),
      s.enabled ? h("div.mi-tool-line",
        h("span.mi-dots", { role: "list", "aria-label": "今天的眼药水" }, p.slots.map((d) =>
          h("span.mi-dot-slot", { role: "listitem", dataset: { state: d.state }, title: `${d.time}${d.state === "done" ? " 滴了" : d.state === "upcoming" ? " 还没到" : d.state === "showing" ? " 该滴了" : " 没打卡"}` },
            h("span.mi-dot-mark", { "aria-hidden": "true" }, mark[d.state] ?? ""), d.time))),
        h("button.mi-btn.small" + (eyedrops.showing() ? ".primary" : ""), { type: "button", disabled: !slot, title: slot ? "记一次「滴了」" : "现在没有要打卡的",
          onclick: () => { if (slot) { eyedrops.markDone(slot); render(); } } }, "滴了")) : null);
  }

  function render() {
    const focusLabel = el.contains(document.activeElement) ? document.activeElement.getAttribute("aria-label") : null;
    setChildren(list, pomoRow(), remindRow("water"), remindRow("stand"), eyeRow());
    if (focusLabel) list.querySelector(`[aria-label="${CSS.escape(focusLabel)}"]`)?.focus();
  }

  /** The one-line strip (narrow window): what's on, at a glance. */
  function bits() {
    const s = reminders.settings();
    const st = (k) => ({ on: s[k + "Enabled"], ...(reminders.status(k) || {}) });
    const ps = pomodoro.state();
    const e = eyedrops.settings();
    const p = e.enabled ? eyedrops.progress() : null;
    return toolBits({
      water: st("water"), stand: st("stand"),
      eye: e.enabled ? { on: true, done: p.done, total: p.total, showing: !!eyedrops.showing() } : null,
      pomo: { phase: ps.phase, left: pomodoro.remaining(), paused: pomodoro.isPaused() },
    });
  }

  return { el, render, bits };
}
