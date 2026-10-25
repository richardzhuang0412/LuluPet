// 小工具 tab (ToolsTabView): 🍅 番茄钟 · 💧 喝水提醒 · 🧍 站立提醒 · 👁️💧 眼药水. Each card = header (emoji + name, ⓘ, switch),
// a stepper, a live line. Re-rendered every 30 s while the tab is on screen, and whenever a controller changes.
// Pomodoro durations live here too (the web has no separate 小工具 settings page; spec §2.7).

import { h, setChildren, toast } from "./dom.js";
import { toolsCopy } from "./reminders.js";
import { resizeTimes, commitTimes } from "./eyedrop-times.js";

const DOT = { done: "✓", showing: "⏰", upcoming: "○", missed: "–", unconfirmed: "–", past: "·" };
const DOT_TITLE = { done: "滴了", showing: "正在提醒", upcoming: "还没到", missed: "错过了", unconfirmed: "没确认", past: "今天已过（设好之前就过了，今天不提醒）" };

/** A small switch (checkbox role=switch). */
export function toggle(checked, label, onChange) {
  const input = h("input.switch", { type: "checkbox", role: "switch", "aria-label": label, checked });
  input.addEventListener("change", () => onChange(input.checked));
  return input;
}

/** − value + stepper. */
export function stepper(value, { min, max, step = 1, label, format = (v) => String(v), disabled = false }, onChange) {
  const out = h("span.step-value", format(value));
  const btn = (d, sign) => h("button.step-btn", { type: "button", "aria-label": `${label}${sign}`, disabled: disabled || (d < 0 ? value <= min : value >= max),
    onclick: () => onChange(Math.min(max, Math.max(min, value + d))) }, d < 0 ? "−" : "+");
  return h("span.stepper", { role: "group", "aria-label": label }, btn(-step, "减少"), out, btn(step, "增加"));
}

/** ⓘ with the long explanation (hover / tap). */
export function info(text) {
  const tip = h("span.info-tip", { role: "tooltip" }, text);
  const b = h("button.info", { type: "button", "aria-label": "这是什么？", "aria-expanded": "false" }, "?", tip);
  b.addEventListener("click", (e) => { e.stopPropagation(); const on = !b.classList.contains("open"); b.classList.toggle("open", on); b.setAttribute("aria-expanded", String(on)); });
  b.addEventListener("blur", () => b.classList.remove("open"));
  return b;
}

const card = (cls, ...children) => h("section.tool-card" + cls, children);
const head = (title, ...right) => h("div.tool-head", h("span.tool-title", title), ...right);

export function createToolsTab({ pomodoro, reminders, eyedrops, onSettingsChange }) {
  const el = h("div.tools");
  let visible = false;
  let editingTimes = false;
  let draftTimes = null;     // 「改时间」 inputs, unsaved until the whole set is valid
  let timesError = null;

  function pomodoroCard() {
    const p = pomodoro.state();
    const pill = (label, filled, fn) => h(filled ? "button.pill-btn.filled" : "button.pill-btn", { type: "button", onclick: () => { fn(); render(); } }, label);
    const buttons = p.phase === "idle" ? [pill("开始专注", true, pomodoro.start)]
      : [pill(pomodoro.isPaused() ? "继续" : "暂停", true, pomodoro.pauseResume),
        p.phase !== "focus" ? pill("跳过休息", false, pomodoro.skipBreak) : null,
        pill("结束", false, pomodoro.stop)];
    const s = reminders.settings();
    const minutes = (key, label, max) => h("div.tool-row",
      h("span.tool-label", label),
      stepper(Math.round(s.pomodoro[key] / 60), { min: 1, max, label, format: (v) => `${v} 分钟` },
        (v) => save({ ...s, pomodoro: { ...s.pomodoro, [key]: v * 60 } })));
    return card(".pomodoro",
      head("🍅 番茄钟", info(toolsCopy.pomodoroHint)),
      h("div.tool-state", { class: p.phase !== "idle" ? "on" : null }, pomodoro.stateLine()),
      h("div.pill-row", buttons),
      h("details.tool-more",
        h("summary", pomodoro.durations() + " · 调时长"),
        minutes("focus", "专注", 120),
        minutes("shortBreak", "短休息", 60),
        minutes("longBreak", "长休息", 120),
        h("div.tool-row", h("span.tool-label", "几轮一次长休息"),
          stepper(s.pomodoro.roundsPerLong, { min: 1, max: 8, label: "几轮一次长休息", format: (v) => `${v} 轮` },
            (v) => save({ ...s, pomodoro: { ...s.pomodoro, roundsPerLong: v } }))),
        h("div.tool-note", "新的时长从下一个阶段开始算")));
  }

  function reminderCard(kind) {
    const s = reminders.settings();
    const on = s[kind + "Enabled"];
    const minutes = Math.round(s[kind + "Interval"] / 60);
    const C = toolsCopy;
    return card("." + kind,
      head(`${C.emoji(kind)} ${C.name(kind)}`, info(C.explanation(kind, s[kind + "Interval"])),
        toggle(on, C.name(kind), (v) => save({ ...s, [kind + "Enabled"]: v }))),
      h("div.tool-row", { class: on ? null : "off" },
        h("span.tool-label", `每用电脑 ${minutes} 分钟`),
        stepper(minutes, { min: 5, max: 180, step: 5, label: "间隔", disabled: !on, format: (v) => `${v}` },
          (v) => save({ ...s, [kind + "Interval"]: v * 60 }))),
      on ? h("div.tool-live", reminders.cycleLine(kind)) : null,
      kind === "water" ? h("div.tool-live", `今天喝了 ${reminders.cups()} 杯 💧`) : null);
  }

  function eyedropsCard() {
    const s = eyedrops.settings();
    const p = eyedrops.progress();
    const apply = (next) => {
      // Never set up (or set up on a Mac with no times yet): switching on fills the suggested times (spec §2.1).
      const v = eyedrops.validate(next.times ?? (s.times.length ? s.times : eyedrops.suggested(eyedrops.defaultCount)));
      if (!v.ok) { toast(v.error); render(); return; }
      eyedrops.apply({ ...next, times: v.times });
      render();
    };
    const dots = h("div.eye-dots", { role: "list", "aria-label": "今天的眼药水" }, p.slots.map((d) => {
      const slot = eyedrops.todaySlot(d.time);
      const e = eyedrops.entry(d.time);
      const state = d.state === "missed" && eyedrops.beforeSetup(d.time) ? "past" : d.state;
      const where = state === "done" && d.device ? (d.device.startsWith("web-") ? "网页" : "Mac") : state === "past" ? "今天已过" : "";
      return h("button.eye-dot", { type: "button", role: "listitem", dataset: { state },
        title: `${d.time} ${DOT_TITLE[state] ?? ""}${where && state === "done" ? `（${where}）` : ""} · 点一下${state === "done" ? "撤销" : "补记「滴了」"}`,
        onclick: () => {
          if (d.state === "done") { if (!eyedrops.undo(slot)) toast(e ? "只能撤销这个网页标的" : "已经撤销了"); }
          else eyedrops.markDone(slot);
          render();
        } },
      h("span.eye-mark", DOT[state] ?? "○"), h("span.eye-time", d.time), where ? h("span.eye-where", where) : null);
    }));
    const n = s.times.length;
    // 「改时间」 edits a draft; the whole set is checked (and saved when valid) once focus leaves the time inputs or
    // on 「改好了」, so moving every time later one by one doesn't trip 「相邻两次至少隔 30 分钟」 midway.
    if (editingTimes && !draftTimes) draftTimes = [...s.times];
    const commit = () => {
      const r = commitTimes(draftTimes, eyedrops.settings().times);
      const changed = r.error !== timesError;
      timesError = r.error;
      if (r.save) apply({ times: r.save });
      else if (changed) render();
      return !r.error;
    };
    let times = null;
    if (editingTimes) {
      const err = h("div.tool-note.eye-times-error", { role: "alert", hidden: !timesError }, timesError ?? "");
      const group = h("div.eye-times", draftTimes.map((t, i) => {
        const input = h("input.time-input", { type: "time", value: t, step: "60", "aria-label": `第 ${i + 1} 次的时间` });
        input.addEventListener("change", () => {
          draftTimes[i] = input.value;
          if (timesError && eyedrops.validate(draftTimes).ok) { timesError = null; err.hidden = true; }
        });
        return input;
      }));
      group.addEventListener("focusout", (e) => {
        // 「改好了」 commits on its own click (re-rendering here would swallow that click)
        if (e.relatedTarget && (group.contains(e.relatedTarget) || e.relatedTarget.dataset?.timesDone)) return;
        commit();
      });
      times = [group, err];
    }
    return card(".eyedrops",
      head("👁️💧 眼药水", info("到点宠物冒气泡提醒你滴眼药水；点「滴了」打卡，「等会儿」15 分钟后再提醒，同一次最多提醒 3 遍。设置和打卡跟家里的 Mac 同步。勿扰、专注时也照常提醒。"),
        toggle(s.enabled, "眼药水提醒", (v) => apply({ enabled: v }))),
      s.enabled ? [
        h("div.eye-progress", h("strong", `👁️ 今天 ${p.done}/${p.total}`), h("span.muted.small", eyedrops.syncLine())),
        dots,
        h("div.tool-row",
          h("span.tool-label", `一天 ${n} 次`),
          stepper(n, { min: 1, max: 8, label: "一天几次" }, (v) => {
            const next = resizeTimes(s.times, v);
            if (next.length < v) { toast("再加就太挤啦：两次之间至少隔 30 分钟"); return; }
            draftTimes = null; timesError = null;
            apply({ times: next });
          }),
          h("button.link", { type: "button", "aria-expanded": String(editingTimes), dataset: { timesDone: editingTimes ? "1" : "" },
            onclick: () => {
              if (editingTimes && !commit()) return;        // invalid: stay editing, the error shows, the last valid set stays saved
              editingTimes = !editingTimes; draftTimes = null; timesError = null;
              render();
            } }, editingTimes ? "改好了" : "改时间")),
        times,
        h("label.tool-row.check-row", toggle(s.notify, "同时发系统通知", (v) => apply({ notify: v })), h("span", "同时发系统通知")),
      ] : h("div.tool-note", "打开后选一天几次，时间会自动填好，也可以单独改。"));
  }

  function save(next) { reminders.update(next); onSettingsChange?.(); render(); }

  function render() {
    if (!visible) return;
    const active = el.ownerDocument.activeElement;   // the panel may live in its own popup window
    const focusEl = active && el.contains(active) ? active.getAttribute("aria-label") : null;
    const openDetails = el.querySelector("details.tool-more")?.open;
    setChildren(el, pomodoroCard(), eyedropsCard(), reminderCard("water"), reminderCard("stand"));
    if (openDetails) el.querySelector("details.tool-more").open = true;
    if (focusEl) el.querySelector(`[aria-label="${CSS.escape(focusEl)}"]`)?.focus();
  }

  setInterval(render, 30_000);

  return {
    el,
    show() { visible = true; eyedrops.refresh(); render(); },
    hide() { visible = false; },
    render,
  };
}
